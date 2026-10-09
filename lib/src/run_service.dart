import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'collector.dart';
import 'config.dart';
import 'model.dart';
import 'process_launcher.dart';
import 'reporting.dart';
import 'runner_events.dart';
import 'source_resolver.dart';

/// Extracts only documented launcher messages; ordinary URLs in app logs are ignored.
Uri? endpointFromLine(String line) {
  final endpoints = endpointsFromLine(line);
  return endpoints.length == 1 ? endpoints.single : null;
}

/// Preserve all endpoints in a machine-output batch so identity checks cannot
/// accidentally pick the first app in a multi-app launch.
List<Uri> endpointsFromLine(String line) {
  if (line.contains('app.debugPort')) {
    try {
      final decoded = jsonDecode(line);
      final messages = decoded is List ? decoded : [decoded];
      final endpoints = <Uri>{};
      for (final message in messages) {
        if (message is Map && message['event'] == 'app.debugPort') {
          final params = message['params'];
          if (params is Map && params['wsUri'] is String) {
            endpoints.add(serviceWebSocketUri(params['wsUri'] as String));
          }
        }
      }
      return endpoints.toList();
    } catch (_) {
      return [];
    }
  }
  if (!RegExp(
    r'(Dart VM service|Dart VM Service|VM Service is listening|Observatory is listening|VMServiceFlutterDriver: Connecting to Flutter application at|test \d+: VM Service uri is available at)',
    caseSensitive: false,
  ).hasMatch(line)) {
    return [];
  }
  final match = RegExp(r'''(?:https?|wss?)://[^\s<>"']+''').firstMatch(line);
  if (match == null) return [];
  try {
    return [
      serviceWebSocketUri(match.group(0)!.replaceFirst(RegExp(r'[),;]+$'), '')),
    ];
  } on FormatException {
    return [];
  }
}

String createRunId() =>
    '${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';

/// Runs automation and collection independently, sharing only their lifecycle.
final class RunService {
  Future<RunResult> run(
    RunOptions options, {
    CancellationToken? cancellation,
    void Function(String)? onStdout,
    void Function(String)? onStderr,
    void Function(RunProgress)? onProgress,
    String? runId,
  }) async {
    final cancel = cancellation ?? CancellationToken();
    final id = runId ?? createRunId();
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,100}$').hasMatch(id)) {
      throw const FormatException('Invalid run identifier.');
    }
    if (!await Directory(options.workingDirectory).exists()) {
      throw const FormatException('Working directory does not exist.');
    }
    if (options.vmServiceUri != null && options.vmServiceUriFile != null) {
      throw const FormatException('Choose one connection source.');
    }
    if (options.attachOnly &&
        options.vmServiceUri == null &&
        options.vmServiceUriFile == null) {
      throw const FormatException('attach requires a VM URL or URI file.');
    }
    if (options.maxFrames <= 0 || options.maxFrames > 1000000) {
      throw const FormatException('maxFrames must be between 1 and 1000000.');
    }
    positiveNumber(options.refreshRateHz, 'refreshRateHz');
    validateGates(Map<String, dynamic>.from(options.gates));
    if (!['measure', 'diagnose'].contains(options.captureMode) ||
        !['none', 'dart-json'].contains(options.runnerAdapter)) {
      throw const FormatException('Invalid capture mode or runner adapter.');
    }
    if (options.sourceRoot != null &&
        !await Directory(options.sourceRoot!).exists()) {
      throw const FormatException('Source root does not exist.');
    }
    if (options.journeyEventsFile != null) {
      final input = File(options.journeyEventsFile!);
      if (await input.exists() && await input.length() != 0) {
        throw const FormatException(
          'Use a fresh, empty journey-events file for each run.',
        );
      }
    }
    final commandLaunch = options.attachOnly
        ? null
        : prepareCommand(
            options.command.first,
            options.command.skip(1).toList(),
            workingDirectory: options.workingDirectory,
          );
    final base =
        options.outputDirectory ??
        p.join(options.workingDirectory, '.runalong', 'runs');
    final directory = Directory(p.absolute(p.join(base, id)));
    if (await directory.exists()) {
      throw const FormatException('Run directory already exists.');
    }
    await directory.create(recursive: true);
    final began = DateTime.now().toUtc();
    final hostClock = Stopwatch()..start();
    final capture = <String, dynamic>{
      'status': 'unavailable',
      'startedAt': null,
      'finishedAt': null,
      'gaps': <dynamic>[],
      'warnings': <dynamic>[],
      'segments': <dynamic>[],
      'invalidEvents': 0,
      'droppedEvents': 0,
      'frameCount': 0,
      'mode': options.captureMode,
    };
    final environment = <String, dynamic>{
      ...options.environment,
      'metadataSource': 'declared',
      'buildMode': 'unknown',
      'refreshRateHz': options.refreshRateHz,
      'refreshRateSource': options.refreshRateHz == null
          ? 'unknown'
          : 'override',
    };
    final automation = <String, dynamic>{
      'status': options.attachOnly ? 'not_applicable' : 'not_started',
      'exitCode': null,
    };
    final manifest = <String, dynamic>{
      'schemaVersion': 2,
      'id': id,
      'toolVersion': '0.1.0',
      'startedAt': began.toIso8601String(),
      'finishedAt': null,
      'automation': automation,
      'capture': capture,
      'environment': environment,
      'gates': {...options.gates},
      'captureMode': options.captureMode,
      'runnerAdapter': options.runnerAdapter,
    };
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    Future<void> saveManifest() => manifestFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest))
        .then((_) {});
    await saveManifest();
    final events = File(p.join(directory.path, 'events.jsonl')).openWrite();
    Object? writeFailure;
    final sinkDone = events.done.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        writeFailure = error;
      },
    );
    void record(JsonMap event) {
      if (writeFailure == null) events.writeln(jsonEncode(event));
    }

    final runnerEvents = RunnerEvents(
      hostMicros: () => hostClock.elapsedMicroseconds,
      onRecord: record,
    );
    Timer? journeyTimer;
    if (options.journeyEventsFile != null) {
      journeyTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        unawaited(runnerEvents.readFile(options.journeyEventsFile!));
      });
    }
    final collector = VmCollector(
      options: options,
      capture: capture,
      environment: environment,
      onRecord: record,
      hostMicros: () => hostClock.elapsedMicroseconds,
    );
    final stopped = Completer<void>();
    void stop() {
      if (!stopped.isCompleted) stopped.complete();
    }

    var state = 'starting';
    void progress(String next) {
      state = next;
      onProgress?.call(
        RunProgress(id, state, directory.path, collector.frameCount),
      );
    }

    final progressTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => progress(state),
    );
    Timer? timeoutTimer;
    var timedOut = false;
    var cancelled = false;
    Process? child;
    var childFinished = false;
    var attachedBeforeCommand = false;
    Future<void>? connectionTask;
    final outputTasks = <Future<void>>[];
    final outputSubscriptions = <StreamSubscription<String>>[];
    Uri? discovered;
    final endpointReady = Completer<void>();
    final ambiguousEndpoint = Completer<void>();
    final captureInterrupted = Future.any<void>([
      stopped.future,
      ambiguousEndpoint.future,
    ]);
    Future<void>? ambiguousClose;
    void discoveredEndpoint(Uri uri) {
      // Explicit connection sources establish identity. Launcher output must
      // neither override them nor invalidate an intentionally selected app.
      if (options.vmServiceUri != null ||
          options.vmServiceUriFile != null ||
          ambiguousEndpoint.isCompleted) {
        return;
      }
      if (discovered != null && discovered != uri) {
        ambiguousEndpoint.complete();
        capture['connectionError'] = true;
        (capture['warnings'] as List<dynamic>).add(
          'Multiple VM endpoints observed. Automatic capture stopped; supply '
          'an explicit VM URL or URI file to select the app.',
        );
        (capture['gaps'] as List<dynamic>).add({
          'at': DateTime.now().toUtc().toIso8601String(),
          'reason': 'Multiple VM endpoints observed.',
        });
        // close() marks the collector closed synchronously, so subsequent frame
        // events cannot be misattributed while the socket is being disposed.
        ambiguousClose = collector.close().catchError((Object _) {
          (capture['warnings'] as List<dynamic>).add(
            'The ambiguous VM connection could not be closed cleanly.',
          );
        });
        return;
      }
      discovered = uri;
      if (!endpointReady.isCompleted) endpointReady.complete();
    }

    void pipe(Stream<List<int>> stream, void Function(String)? output) {
      var pending = '';
      final done = Completer<void>();
      final subscription = stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (text) {
              output?.call(text);
              pending += text;
              final lines = pending.split('\n');
              pending = lines.removeLast();
              for (final line in lines) {
                if (options.runnerAdapter == 'dart-json') {
                  runnerEvents.dartLine(line);
                }
                for (final endpoint in endpointsFromLine(line)) {
                  discoveredEndpoint(endpoint);
                }
              }
              if (pending.length > 65536) {
                pending = pending.substring(pending.length - 65536);
              }
            },
            onDone: () {
              if (options.runnerAdapter == 'dart-json') {
                runnerEvents.dartLine(pending);
              }
              for (final endpoint in endpointsFromLine(pending)) {
                discoveredEndpoint(endpoint);
              }
              if (!done.isCompleted) done.complete();
            },
            onError: (Object error, StackTrace stack) {
              if (!done.isCompleted) done.complete();
            },
          );
      outputSubscriptions.add(subscription);
      outputTasks.add(done.future);
    }

    Future<Uri?> getEndpoint() async {
      if (options.vmServiceUri != null) return options.vmServiceUri;
      if (options.vmServiceUriFile case final String filePath) {
        final file = File(filePath);
        if (await file.exists()) {
          try {
            if (await file.length() > 8192) {
              throw const FormatException('URI file too large.');
            }
            final text = (await file.readAsString()).trim();
            if (text.isNotEmpty) return serviceWebSocketUri(text);
          } on FormatException {
            rethrow;
          } on FileSystemException {
            /* Atomic file replacement can race a read. */
          }
        }
        return null;
      }
      return ambiguousEndpoint.isCompleted ? null : discovered;
    }

    Future<bool> connectUntilReady() async {
      final deadline = DateTime.now().add(options.connectTimeout);
      while (!stopped.isCompleted &&
          !ambiguousEndpoint.isCompleted &&
          DateTime.now().isBefore(deadline)) {
        try {
          final endpoint = await getEndpoint();
          if (endpoint != null) {
            await collector.connect(
              endpoint,
              timeout: deadline.difference(DateTime.now()),
              interrupted: captureInterrupted,
            );
            if (stopped.isCompleted || ambiguousEndpoint.isCompleted) {
              return false;
            }
            progress('capturing');
            return true;
          }
        } on FormatException {
          (capture['warnings'] as List<dynamic>).add(
            'Invalid connection configuration. Check the VM URI or URI file.',
          );
          return false;
        } catch (_) {
          /* Retry startup races without exposing authenticated URLs. */
        }
        if (stopped.isCompleted ||
            ambiguousEndpoint.isCompleted ||
            !DateTime.now().isBefore(deadline)) {
          return false;
        }
        final remaining = deadline.difference(DateTime.now());
        await Future.any([
          captureInterrupted,
          Future<void>.delayed(
            remaining < const Duration(milliseconds: 150)
                ? remaining
                : const Duration(milliseconds: 150),
          ),
        ]);
      }
      return false;
    }

    Future<void> monitorConnection({required bool alreadyConnected}) async {
      var connected = alreadyConnected;
      // Build/install time belongs to the runner. The connection deadline starts
      // once an endpoint exists, so a slow build cannot exhaust it prematurely.
      while (!connected &&
          !stopped.isCompleted &&
          !ambiguousEndpoint.isCompleted &&
          await getEndpoint() == null) {
        await Future.any([
          captureInterrupted,
          Future<void>.delayed(const Duration(milliseconds: 100)),
        ]);
      }
      while (!stopped.isCompleted && !ambiguousEndpoint.isCompleted) {
        if (!connected) connected = await connectUntilReady();
        if (!connected ||
            stopped.isCompleted ||
            ambiguousEndpoint.isCompleted) {
          return;
        }
        await Future.any([collector.onDone, captureInterrupted]);
        if (stopped.isCompleted || ambiguousEndpoint.isCompleted) return;
        (capture['gaps'] as List<dynamic>).add({
          'at': DateTime.now().toUtc().toIso8601String(),
          'reason': 'VM connection closed; reconnecting.',
        });
        connected = false;
        progress('reconnecting');
      }
    }

    unawaited(
      cancel.whenCancelled.then((_) {
        cancelled = true;
        stop();
      }),
    );
    if (options.timeout case final Duration timeout) {
      timeoutTimer = Timer(timeout, () {
        timedOut = true;
        stop();
      });
    }
    progress('starting');
    try {
      await _deviceMetadata(options, environment, capture, stopped.future);
      final fileExists =
          options.vmServiceUriFile != null &&
          await File(options.vmServiceUriFile!).exists();
      final preAttach = options.attachOnly || options.vmServiceUri != null;
      if (preAttach) {
        attachedBeforeCommand = await connectUntilReady();
        if (!attachedBeforeCommand) {
          capture['connectionError'] = true;
          (capture['warnings'] as List<dynamic>).add(
            'Could not attach before automation. Check connectivity with runalong doctor.',
          );
          stop();
        }
      } else if (fileExists) {
        // A URI file may belong to a launcher which will replace an empty or
        // stale file. Probe opportunistically, without preventing that launch.
        try {
          final endpoint = await getEndpoint();
          if (endpoint != null) {
            await collector.connect(
              endpoint,
              timeout: options.connectTimeout < const Duration(seconds: 3)
                  ? options.connectTimeout
                  : const Duration(seconds: 3),
              interrupted: stopped.future,
            );
            attachedBeforeCommand = !stopped.isCompleted;
          }
        } catch (_) {
          /* The runner may publish a fresh endpoint after launch. */
        }
      }
      if (!stopped.isCompleted) {
        if (attachedBeforeCommand) {
          try {
            await Future.any([
              collector.telemetryReady,
              stopped.future,
            ]).timeout(options.connectTimeout);
          } catch (_) {
            (capture['warnings'] as List).add(
              'Optional telemetry setup did not finish before automation. Inspect capability coverage.',
            );
            capture['telemetrySetupIncomplete'] = true;
          }
        }
      }
      if (!stopped.isCompleted) {
        if (!options.attachOnly) {
          child = await commandLaunch!.start(
            workingDirectory: options.workingDirectory,
          );
          automation['status'] = 'running';
          automation['startedAt'] = DateTime.now().toUtc().toIso8601String();
          automation['startedHostMicros'] = hostClock.elapsedMicroseconds;
          if (!attachedBeforeCommand) {
            (capture['gaps'] as List<dynamic>).add({
              'at': automation['startedAt'],
              'reason':
                  'Automation started before attachment; initial frames may be missing.',
            });
          }
          pipe(child.stdout, onStdout);
          pipe(child.stderr, onStderr);
          unawaited(
            child.exitCode.then((code) {
              childFinished = true;
              automation['exitCode'] = code;
              automation['status'] = code == 0 ? 'passed' : 'failed';
              automation['finishedAt'] = DateTime.now()
                  .toUtc()
                  .toIso8601String();
              automation['finishedHostMicros'] = hostClock.elapsedMicroseconds;
              stop();
            }),
          );
        }
        connectionTask =
            monitorConnection(
              alreadyConnected: attachedBeforeCommand,
            ).catchError((Object error, StackTrace stack) {
              (capture['warnings'] as List<dynamic>).add(
                'Connection discovery failed. Check the VM endpoint configuration.',
              );
            });
        Timer? durationTimer;
        if (options.attachOnly && options.duration != null) {
          durationTimer = Timer(options.duration!, stop);
        }
        await stopped.future;
        durationTimer?.cancel();
      }
    } on ProcessException {
      automation['status'] = 'failed';
      automation['exitCode'] = 127;
      (capture['warnings'] as List<dynamic>).add(
        'Automation executable could not be started. Check command and working directory.',
      );
    } catch (_) {
      (capture['warnings'] as List<dynamic>).add(
        'Capture interrupted by a runtime or filesystem error.',
      );
    } finally {
      stop();
      timeoutTimer?.cancel();
      if (child != null && !childFinished) {
        await _terminateOwnedProcess(child);
        final code = await child.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => RunalongExit.cancelled,
        );
        automation['exitCode'] = code;
        automation['status'] = timedOut
            ? 'timed_out'
            : cancelled
            ? 'cancelled'
            : 'failed';
      }
      if (timedOut || cancelled) {
        (capture['gaps'] as List<dynamic>).add({
          'at': DateTime.now().toUtc().toIso8601String(),
          'reason': timedOut ? 'Run timed out.' : 'Run cancelled.',
        });
      }
      await Future.wait(
        outputTasks,
      ).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
      for (final subscription in outputSubscriptions) {
        await subscription.cancel();
      }
      if (!cancelled && !timedOut && capture['startedAt'] != null) {
        await Future<void>.delayed(options.flushDuration);
      }
      await ambiguousClose;
      await collector.close();
      journeyTimer?.cancel();
      if (options.journeyEventsFile != null) {
        await runnerEvents.readFile(options.journeyEventsFile!, finish: true);
      }
      capture['runnerEvents'] = runnerEvents.count;
      capture['invalidRunnerEvents'] = runnerEvents.invalidRecords;
      await connectionTask?.timeout(
        const Duration(seconds: 6),
        onTimeout: () {},
      );
      progressTimer.cancel();
      progress('finalizing');
      try {
        await events.close();
      } catch (error) {
        writeFailure = error;
      }
      await sinkDone;
      capture['finishedAt'] = DateTime.now().toUtc().toIso8601String();
      capture['status'] = collector.frameCount == 0
          ? 'unavailable'
          : capture['connectionError'] == true ||
                (capture['gaps'] as List).isNotEmpty ||
                capture['droppedEvents'] != 0 ||
                capture['invalidEvents'] != 0 ||
                writeFailure != null
          ? 'partial'
          : 'complete';
      if (collector.frameCount == 0) {
        (capture['warnings'] as List<dynamic>).add(
          'No Flutter frames captured. This is not a performance pass.',
        );
      }
      if (writeFailure != null) {
        (capture['warnings'] as List<dynamic>).add(
          'Event storage failed; recorded artifacts may be incomplete.',
        );
      }
      manifest['finishedAt'] = capture['finishedAt'];
      capture['finishedHostMicros'] = hostClock.elapsedMicroseconds;
      if (options.sourceRoot != null) {
        manifest['sourceIndex'] = await buildSourceIndex(
          options.sourceRoot!,
          expectedRevision: options.environment['appRevision'] as String?,
        );
      }
      try {
        await saveManifest();
      } catch (_) {
        // The already-created manifest and JSONL are left available for recovery.
        writeFailure ??= const FileSystemException(
          'Manifest finalization failed.',
        );
      }
    }
    try {
      final report = await regenerateReport(directory);
      if (options.gates['baseline'] case final String baselinePath) {
        try {
          final baseline =
              jsonDecode(
                    await File(
                      p.join(baselinePath, 'report.json'),
                    ).readAsString(),
                  )
                  as JsonMap;
          final comparison = compareReports(
            baseline,
            report,
            regressionPercent: (options.gates['regressionPercent'] as num?)
                ?.toDouble(),
          );
          applyComparison(report, comparison);
          manifest['comparison'] = comparison;
        } catch (_) {
          applyComparison(report, {
            'status': 'inconclusive',
            'compatible': false,
            'reasons': ['Baseline could not be loaded.'],
            'metrics': <String, dynamic>{},
          });
          manifest['comparison'] = report['comparison'];
        }
      }
      final int code;
      if (timedOut) {
        code = RunalongExit.timeout;
      } else if (cancelled) {
        code = RunalongExit.cancelled;
      } else if (automation['exitCode'] is int && automation['exitCode'] != 0) {
        code = automation['exitCode'] as int;
      } else if (writeFailure != null) {
        code = RunalongExit.report;
      } else if (capture['status'] == 'unavailable' ||
          capture['connectionError'] == true ||
          (!options.attachOnly && automation['status'] == 'not_started')) {
        code = RunalongExit.capture;
      } else if ((report['budget'] as Map?)?['status'] == 'fail') {
        code = RunalongExit.budget;
      } else if ((report['budget'] as Map?)?['status'] == 'inconclusive' &&
          options.gates['enabled'] == true) {
        code = RunalongExit.inconclusive;
      } else {
        code = RunalongExit.success;
      }
      manifest['exitCode'] = code;
      report['exitCode'] = code;
      await saveManifest();
      await writeReports(directory, report);
      progress(
        cancelled
            ? 'cancelled'
            : code == 0
            ? 'completed'
            : 'failed',
      );
      return RunResult(
        id: id,
        directory: directory.path,
        exitCode: code,
        report: report,
      );
    } catch (_) {
      manifest['reportError'] =
          'Report generation failed. Raw events and manifest are retained.';
      final code = automation['exitCode'] is int && automation['exitCode'] != 0
          ? automation['exitCode'] as int
          : RunalongExit.report;
      manifest['exitCode'] = code;
      try {
        await saveManifest();
      } catch (_) {
        /* Preserve the command outcome. */
      }
      progress('failed');
      return RunResult(
        id: id,
        directory: directory.path,
        exitCode: code,
        report: manifest,
      );
    }
  }
}

Future<void> _deviceMetadata(
  RunOptions options,
  JsonMap environment,
  JsonMap capture,
  Future<void> interrupted,
) async {
  if (options.deviceId == null) return;
  try {
    final result = await runHostCommand('flutter', [
      'devices',
      '--machine',
    ], interrupted: interrupted);
    final data = jsonDecode(result.stdout as String);
    if (result.exitCode == 0 && data is List) {
      final matches = data.whereType<Map>().where(
        (d) => d['id'] == options.deviceId,
      );
      if (matches.length == 1) {
        final device = matches.single;
        environment.addAll({
          'model': device['name'],
          'osVersion': device['sdk'],
          'physical': device['emulator'] is bool
              ? !(device['emulator'] as bool)
              : null,
          'deviceMetadataSource': 'flutter devices (explicit selection)',
        });
        return;
      }
    }
  } catch (_) {
    /* Declared environment metadata remains usable but labelled. */
  }
  (capture['warnings'] as List<dynamic>).add(
    'Selected device metadata unavailable. Supply environment identity for comparisons.',
  );
}

/// Bounded host probes share the same ownership and cleanup rules as test runs.
Future<ProcessResult> runHostCommand(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 15),
  Future<void>? interrupted,
}) async {
  final process = await prepareCommand(executable, arguments).start();
  await process.stdin.close();
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  var exited = false;
  final completion = process.exitCode.then((value) {
    exited = true;
    return value;
  });
  try {
    final code = await Future.any<int>([
      completion,
      if (interrupted != null)
        interrupted.then<int>(
          (_) => throw StateError('Host probe interrupted.'),
        ),
    ]).timeout(timeout);
    final streams = await Future.wait([output, errors]).timeout(timeout);
    return ProcessResult(process.pid, code, streams[0], streams[1]);
  } finally {
    if (!exited) await _terminateOwnedProcess(process);
    // Keep errors on drained pipes observed even when the command is interrupted.
    await Future.wait([
      output,
      errors,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => <String>[]);
  }
}

Future<void> _terminateOwnedProcess(Process process) async {
  if (Platform.isWindows) {
    try {
      await Process.run('taskkill', [
        '/PID',
        '${process.pid}',
        '/T',
        '/F',
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {
      process.kill();
    }
    return;
  }
  final children = <int, String>{};
  Future<Map<int, (int, String)>> snapshot() async {
    final result = await Process.run('ps', [
      '-axo',
      'pid=,ppid=,lstart=',
    ]).timeout(const Duration(seconds: 2));
    final entries = <int, (int, String)>{};
    for (final line in (result.stdout as String).split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 7) {
        final pid = int.tryParse(fields[0]);
        final parent = int.tryParse(fields[1]);
        if (pid != null && parent != null) {
          entries[pid] = (parent, fields.skip(2).join(' '));
        }
      }
    }
    return entries;
  }

  try {
    final processes = await snapshot();
    void descend(int parent) {
      for (final entry in processes.entries.where(
        (entry) => entry.value.$1 == parent,
      )) {
        if (!children.containsKey(entry.key)) {
          children[entry.key] = entry.value.$2;
          descend(entry.key);
        }
      }
    }

    descend(process.pid);
  } catch (_) {
    /* The owned direct child can still be stopped. */
  }
  for (final pid in children.keys.toList().reversed) {
    Process.killPid(pid, ProcessSignal.sigterm);
  }
  process.kill(ProcessSignal.sigterm);
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
  // A child may ignore TERM even after its parent exits. Check birth identity
  // before escalation so a recycled PID never authorizes killing another task.
  if (children.isNotEmpty) {
    try {
      final survivors = await snapshot();
      for (final entry in children.entries) {
        if (survivors[entry.key]?.$2 == entry.value) {
          Process.killPid(entry.key, ProcessSignal.sigkill);
        }
      }
    } catch (_) {
      /* Never broaden cleanup to unrelated host processes. */
    }
  }
}
