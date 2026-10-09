import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'collector.dart';
import 'config.dart';
import 'mcp_server.dart';
import 'model.dart';
import 'reporting.dart';
import 'run_service.dart';

const version = '0.1.0';

/// CLI boundary. The recorder and reporting layers never call exit().
Future<int> runCli(List<String> arguments) async {
  final parser = _parser();
  try {
    final parsed = parser.parse(arguments);
    if (parsed.flag('version')) {
      stdout.writeln('Runalong $version');
      return 0;
    }
    final command = parsed.command;
    if (parsed.flag('help') || command == null) {
      stdout.writeln(
        'Runalong — performance evidence for existing Flutter UI tests.\n',
      );
      stdout.writeln('Usage: runalong <command> [options]\n');
      stdout.writeln('Short command: ral <command> [options]\n');
      stdout.writeln(
        '  doctor    Check connection and setup\n  init      Write an optional project configuration\n  run       Record alongside your existing test command\n  attach    Record an independently running app\n  report    Rebuild an offline report\n  compare   Compare two recorded runs\n  mcp       Serve local coding agents over stdio\n',
      );
      stdout.writeln(parser.usage);
      return 0;
    }
    if (command.flag('help')) {
      stdout.writeln(
        'Usage: runalong ${command.name} ${_usageSuffix(command.name!)}\n',
      );
      stdout.writeln(parser.commands[command.name]!.usage);
      return 0;
    }
    final project = p.absolute(
      command.option('project') ?? Directory.current.path,
    );
    switch (command.name) {
      case 'init':
        final file = File(p.join(project, 'runalong.yaml'));
        if (await file.exists()) {
          throw const FormatException(
            'runalong.yaml already exists; it was not overwritten.',
          );
        }
        await file.parent.create(recursive: true);
        await file.writeAsString(configurationTemplate);
        stdout.writeln(
          'Created ${file.path}\nEdit the example profile, then run runalong doctor.',
        );
        return 0;
      case 'mcp':
        await serveMcp(projectDirectory: project);
        return 0;
      case 'doctor':
        return _doctor(command, project);
      case 'run':
      case 'attach':
        final options = await _options(command, project);
        final token = CancellationToken();
        final signals = <StreamSubscription<ProcessSignal>>[];
        for (final signal in [
          ProcessSignal.sigint,
          if (!Platform.isWindows) ProcessSignal.sigterm,
        ]) {
          signals.add(signal.watch().listen((_) => token.cancel()));
        }
        try {
          final result = await RunService().run(
            options,
            cancellation: token,
            onStdout: command.flag('json') ? stderr.write : stdout.write,
            onStderr: stderr.write,
          );
          if (command.flag('json')) {
            final compact = {
              ...result.toJson(),
              'report': {
                for (final entry in result.report.entries)
                  if (entry.key != 'frames' && entry.key != 'navigation')
                    entry.key: entry.value,
              },
            };
            stdout.writeln(jsonEncode(compact));
          } else {
            final capture = result.report['capture'] as Map?;
            final automation = result.report['automation'] as Map?;
            final budget = result.report['budget'] as Map?;
            stdout.writeln(
              '\nRunalong: automation ${automation?['status'] ?? 'unknown'} · capture ${capture?['status'] ?? 'unknown'} · budget ${budget?['status'] ?? 'unavailable'}',
            );
            stdout.writeln(
              'Report: ${p.join(result.directory, 'report.html')}',
            );
            for (final warning in capture?['warnings'] as List? ?? []) {
              stderr.writeln('  $warning');
            }
          }
          return result.exitCode;
        } finally {
          for (final signal in signals) {
            await signal.cancel();
          }
        }
      case 'report':
        if (command.rest.length != 1) {
          throw const FormatException('report requires one run directory.');
        }
        final directory = Directory(p.absolute(command.rest.single));
        final report = await regenerateReport(directory);
        if (command.flag('json')) {
          stdout.writeln(
            jsonEncode({
              for (final entry in report.entries)
                if (entry.key != 'frames') entry.key: entry.value,
            }),
          );
        } else {
          stdout.writeln('Report: ${p.join(directory.path, 'report.html')}');
        }
        return 0;
      case 'compare':
        if (command.rest.length != 2) {
          throw const FormatException(
            'compare requires baseline and candidate run directories.',
          );
        }
        final baseline = await _readReport(command.rest[0]);
        final candidate = await _readReport(command.rest[1]);
        final threshold = positiveNumber(
          command.option('regression-percent'),
          'regression-percent',
          zeroAllowed: true,
        );
        final comparison = compareReports(
          baseline,
          candidate,
          regressionPercent: threshold,
        );
        stdout.writeln(
          command.flag('json')
              ? jsonEncode(comparison)
              : const JsonEncoder.withIndent('  ').convert(comparison),
        );
        return switch (comparison['status']) {
          'fail' => RunalongExit.budget,
          'inconclusive' => RunalongExit.inconclusive,
          _ => 0,
        };
    }
    return RunalongExit.usage;
  } on ArgParserException catch (error) {
    stderr.writeln('Runalong: ${error.message}\nUse runalong --help.');
    return RunalongExit.usage;
  } on FormatException catch (error) {
    stderr.writeln('Runalong: ${error.message}');
    return RunalongExit.usage;
  } on FileSystemException {
    stderr.writeln(
      'Runalong: cannot read or write the requested file. Check paths and permissions.',
    );
    return RunalongExit.report;
  } catch (_) {
    stderr.writeln(
      'Runalong: operation failed. Check configuration with runalong doctor.',
    );
    return RunalongExit.report;
  }
}

String _usageSuffix(String command) => switch (command) {
  'run' => '[options] -- <executable> <arguments...>',
  'attach' => '--vm-service-uri <url> [--duration <seconds>]',
  'report' => '<run-directory>',
  'compare' => '<baseline> <candidate>',
  _ => '[options]',
};

ArgParser _parser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag('version', negatable: false, help: 'Show version.');
  for (final name in [
    'doctor',
    'init',
    'run',
    'attach',
    'report',
    'compare',
    'mcp',
  ]) {
    final command = ArgParser(allowTrailingOptions: name != 'run')
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show command usage.',
      )
      ..addOption(
        'project',
        help: 'Project directory (defaults to current directory).',
      );
    if (name != 'init' && name != 'mcp') {
      command.addFlag(
        'json',
        negatable: false,
        help: 'Machine-readable output; runner logs go to stderr.',
      );
    }
    if (['doctor', 'run', 'attach'].contains(name)) {
      command
        ..addOption(
          'vm-service-uri',
          help: 'Authenticated VM/DDS URL. Never saved in reports.',
        )
        ..addOption(
          'vm-service-uri-file',
          help: 'File containing the VM WebSocket URL.',
        )
        ..addOption(
          'device-id',
          help: 'Explicit Flutter device ID for metadata.',
        )
        ..addOption(
          'connect-timeout',
          help: 'Connection deadline in seconds (default 30).',
        );
    }
    if (name == 'run' || name == 'attach') {
      command
        ..addOption(
          'profile',
          help: 'Named profile from runalong.yaml (run only).',
        )
        ..addOption(
          'output',
          help: 'Artifact parent directory; a unique child is created.',
        )
        ..addOption(
          'environment',
          help: 'Stable environment alias for baseline comparisons.',
        )
        ..addOption('workload', help: 'Stable journey identifier.')
        ..addOption(
          'refresh-rate',
          help: 'Explicit display refresh rate in Hz.',
        )
        ..addOption('timeout', help: 'Overall deadline in seconds.')
        ..addOption(
          'duration',
          help: 'Recording duration for attach, in seconds.',
        )
        ..addOption(
          'max-frames',
          help: 'Sample retention limit (default 200000).',
        )
        ..addFlag(
          'gate',
          negatable: false,
          help: 'Enforce explicitly configured performance budgets.',
        )
        ..addOption(
          'baseline',
          help: 'Saved baseline directory; never updated automatically.',
        )
        ..addOption('max-build-p95-ms', help: 'Maximum p95 build time.')
        ..addOption('max-raster-p95-ms', help: 'Maximum p95 raster time.')
        ..addOption(
          'max-over-budget-percent',
          help: 'Maximum percentage of frames exceeding the budget.',
        )
        ..addOption(
          'regression-percent',
          help: 'Allowed p95 regression against the baseline.',
        );
    }
    if (name == 'compare') {
      command.addOption(
        'regression-percent',
        help: 'Optional explicit regression threshold.',
      );
    }
    parser.addCommand(name, command);
  }
  return parser;
}

Future<RunOptions> _options(ArgResults args, String project) async {
  RunOptions? profile;
  if (args.option('profile') case final String name) {
    if (args.name != 'run') {
      throw const FormatException('Named profiles are supported by run only.');
    }
    profile = (await loadProfiles(project))[name];
    if (profile == null) throw FormatException('Unknown profile: $name');
    if (args.rest.isNotEmpty) {
      throw const FormatException('Choose a profile or a command.');
    }
  }
  final command = profile?.command ?? args.rest;
  if (args.name == 'run' && command.isEmpty) {
    throw const FormatException(
      'run requires -- <command> or --profile <name>.',
    );
  }
  if (args.name == 'attach' && command.isNotEmpty) {
    throw const FormatException(
      'attach does not accept an automation command.',
    );
  }
  if (args.name == 'run' && args.option('duration') != null) {
    throw const FormatException(
      '--duration applies to attach; use --timeout for run.',
    );
  }
  final uri = args.option('vm-service-uri');
  final file = args.option('vm-service-uri-file');
  if (uri != null && file != null) {
    throw const FormatException('Choose a VM URL or URI file.');
  }
  final environment = <String, dynamic>{...?profile?.environment};
  if (args.option('environment') case final String value) {
    environment['id'] = value;
  }
  if (args.option('workload') case final String value) {
    environment['workload'] = value;
  }
  final gates = <String, dynamic>{...?profile?.gates};
  if (args.flag('gate')) gates['enabled'] = true;
  final mappings = {
    'max-build-p95-ms': 'buildP95Ms',
    'max-raster-p95-ms': 'rasterP95Ms',
    'max-over-budget-percent': 'overBudgetPercent',
    'regression-percent': 'regressionPercent',
  };
  for (final entry in mappings.entries) {
    if (args.option(entry.key) case final String value) {
      gates[entry.value] = positiveNumber(value, entry.key, zeroAllowed: true);
    }
  }
  if (args.option('baseline') case final String value) {
    gates['baseline'] = p.absolute(value);
  }
  validateGates(gates);
  final maxRaw = args.option('max-frames');
  final maxFrames = maxRaw == null
      ? profile?.maxFrames ?? 200000
      : int.tryParse(maxRaw);
  if (maxFrames == null || maxFrames <= 0 || maxFrames > 1000000) {
    throw const FormatException(
      '--max-frames must be an integer between 1 and 1000000.',
    );
  }
  return RunOptions(
    command: args.name == 'attach' ? [] : command,
    workingDirectory: profile?.workingDirectory ?? project,
    outputDirectory: args.option('output') == null
        ? null
        : p.absolute(args.option('output')!),
    vmServiceUri: uri == null
        ? (file == null ? profile?.vmServiceUri : null)
        : serviceWebSocketUri(uri),
    vmServiceUriFile: file == null
        ? (uri == null ? profile?.vmServiceUriFile : null)
        : p.absolute(file),
    deviceId: args.option('device-id') ?? profile?.deviceId,
    connectTimeout:
        seconds(args.option('connect-timeout'), 'connect-timeout') ??
        profile?.connectTimeout ??
        const Duration(seconds: 30),
    timeout: seconds(args.option('timeout'), 'timeout') ?? profile?.timeout,
    duration: seconds(args.option('duration'), 'duration') ?? profile?.duration,
    refreshRateHz:
        positiveNumber(args.option('refresh-rate'), 'refresh-rate') ??
        profile?.refreshRateHz,
    maxFrames: maxFrames,
    environment: environment,
    gates: gates,
  );
}

Future<JsonMap> _readReport(String directory) async {
  final value = jsonDecode(
    await File(p.join(directory, 'report.json')).readAsString(),
  );
  if (value is! JsonMap || value['schemaVersion'] != 1) {
    throw const FormatException('Unsupported report schema.');
  }
  return value;
}

Future<int> _doctor(ArgResults args, String project) async {
  final checks = <JsonMap>[];
  checks.add({
    'name': 'Dart',
    'status': 'ok',
    'detail': Platform.version.split('\n').first,
  });
  try {
    final result = await runHostCommand('flutter', ['--version', '--machine']);
    final data = jsonDecode(result.stdout as String);
    checks.add({
      'name': 'Flutter',
      'status': result.exitCode == 0 ? 'ok' : 'unavailable',
      'detail': data is Map ? data['frameworkVersion'] : 'Unavailable',
    });
  } catch (_) {
    checks.add({
      'name': 'Flutter',
      'status': 'unavailable',
      'detail':
          'Flutter CLI not found or could not start; explicit VM attachment remains available.',
    });
  }
  try {
    final profiles = await loadProfiles(project);
    checks.add({
      'name': 'Configuration',
      'status': 'ok',
      'detail': '${profiles.length} saved profiles',
    });
  } on FormatException catch (error) {
    checks.add({
      'name': 'Configuration',
      'status': 'error',
      'detail': error.message,
    });
  }
  final deviceId = args.option('device-id');
  if (deviceId != null) {
    try {
      final result = await runHostCommand('flutter', ['devices', '--machine']);
      checks.add(
        selectedDeviceCheck(
          result.exitCode == 0 ? jsonDecode(result.stdout as String) : null,
          deviceId,
        ),
      );
    } catch (_) {
      checks.add(selectedDeviceCheck(null, deviceId));
    }
  } else {
    checks.add({
      'name': 'Selected device',
      'status': 'not_checked',
      'detail':
          'Pass --device-id with an exact Flutter device ID to check availability.',
    });
  }
  final raw = args.option('vm-service-uri');
  final uriFile = args.option('vm-service-uri-file');
  if (raw != null && uriFile != null) {
    throw const FormatException('Choose one connection source.');
  }
  if (raw != null || uriFile != null) {
    final environment = <String, dynamic>{};
    final capture = <String, dynamic>{
      'gaps': <dynamic>[],
      'warnings': <dynamic>[],
      'segments': <dynamic>[],
      'invalidEvents': 0,
      'droppedEvents': 0,
    };
    final collector = VmCollector(
      options: RunOptions(workingDirectory: project),
      capture: capture,
      environment: environment,
      onRecord: (_) {},
    );
    try {
      final uri = serviceWebSocketUri(
        raw ?? await File(uriFile!).readAsString(),
      );
      await collector.connect(
        uri,
        timeout:
            seconds(args.option('connect-timeout'), 'connect-timeout') ??
            const Duration(seconds: 10),
      );
      checks.add({
        'name': 'VM Service',
        'status': 'ok',
        'detail':
            'Connected. Start a capture with a rendering workload to verify build mode.',
      });
    } catch (_) {
      checks.add({
        'name': 'VM Service',
        'status': 'error',
        'detail':
            'Could not connect. Check the authenticated URL, port forwarding, and running profile build.',
      });
    } finally {
      await collector.close();
    }
  } else {
    checks.add({
      'name': 'VM Service',
      'status': 'not_checked',
      'detail':
          'Pass --vm-service-uri or --vm-service-uri-file to test connectivity.',
    });
  }
  if (args.flag('json')) {
    stdout.writeln(jsonEncode({'checks': checks}));
  } else {
    for (final check in checks) {
      stdout.writeln(
        '${check['name']}: ${check['status']} — ${check['detail']}',
      );
    }
  }
  return checks.any(
        (c) =>
            c['status'] == 'error' ||
            (c['name'] == 'Selected device' && c['status'] == 'unavailable'),
      )
      ? RunalongExit.capture
      : 0;
}

/// Interprets an explicit device selection without choosing another device.
/// Kept separate from the bounded Flutter probe so host-independent tests can
/// verify missing, duplicate, unsupported, and malformed discovery results.
JsonMap selectedDeviceCheck(Object? listing, String deviceId) {
  if (listing is! List ||
      listing.any((device) => device is! Map || device['id'] is! String)) {
    return {
      'name': 'Selected device',
      'status': 'unavailable',
      'detail':
          'Flutter device discovery is unavailable. Check flutter devices '
          '--machine and the SDK installation.',
    };
  }
  final matches = listing
      .whereType<Map>()
      .where((device) => device['id'] == deviceId)
      .toList();
  if (matches.length != 1) {
    return {
      'name': 'Selected device',
      'status': 'error',
      'detail': matches.isEmpty
          ? 'The selected device is not connected. Use the exact ID from flutter devices.'
          : 'Device discovery returned duplicate IDs. An unambiguous device is required.',
    };
  }
  final device = matches.single;
  if (device['isSupported'] == false) {
    return {
      'name': 'Selected device',
      'status': 'error',
      'detail':
          'The selected device is connected but is not supported by the installed Flutter SDK.',
    };
  }
  return {
    'name': 'Selected device',
    'status': 'ok',
    'detail':
        '${device['name'] ?? deviceId} is available. '
        'This verifies device discovery, not the app VM connection.',
    'device': {
      'id': deviceId,
      if (device['targetPlatform'] is String)
        'platform': device['targetPlatform'],
      if (device['emulator'] is bool) 'physical': !(device['emulator'] as bool),
    },
  };
}
