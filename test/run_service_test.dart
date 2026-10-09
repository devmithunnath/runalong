import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runalong/src/model.dart';
import 'package:runalong/src/reporting.dart';
import 'package:runalong/src/run_service.dart';
import 'package:test/test.dart';

import 'support/fake_vm.dart';

void main() {
  test('preattached automation preserves literal Unicode arguments and '
      'records a complete profile capture', () async {
    final harness = await _Harness.create();
    final arguments = [
      'space in arg',
      r'$(literal)',
      '`literal`',
      'മലയാളം',
      'a;b',
    ];
    final run = harness.start(arguments: arguments);
    await harness.childReady;
    await harness.recordFrame(number: 1, build: 22000, raster: 3000);
    await harness.recordFrame(number: 2, build: 1000, raster: 2000);
    await harness.release();
    final result = await run;

    expect(result.exitCode, 0);
    expect(result.report['automation']['status'], 'passed');
    expect(result.report['capture']['status'], 'complete');
    expect(result.report['environment']['buildMode'], 'profile');
    expect(result.report['metrics']['frameCount'], 2);
    expect(result.report['metrics']['overBudgetCount'], 1);
    expect(harness.stdout.toString(), contains(jsonEncode(arguments)));
    expect(jsonEncode(result.report), isNot(contains('fake-secret')));
    for (final name in [
      'report.json',
      'report.html',
      'summary.md',
      'events.jsonl',
    ]) {
      expect(await File('${result.directory}/$name').exists(), isTrue);
    }
  });

  for (final captureFrames in [true, false]) {
    test('preserves failing automation exit code with '
        '${captureFrames ? 'valid' : 'missing'} measurements', () async {
      final harness = await _Harness.create();
      final run = harness.start(exitCode: 7);
      await harness.childReady;
      if (captureFrames) await harness.recordFrame();
      await harness.release();
      final result = await run;

      expect(result.exitCode, 7);
      expect(result.report['exitCode'], 7);
      expect(result.report['automation']['exitCode'], 7);
      expect(result.report['automation']['status'], 'failed');
      expect(
        result.report['capture']['status'],
        captureFrames ? 'complete' : 'unavailable',
      );
      expect(await File('${result.directory}/report.html').exists(), isTrue);
    });
  }

  test(
    'a passing automation with no frames is not a performance pass',
    () async {
      final harness = await _Harness.create();
      final run = harness.start();
      await harness.childReady;
      await harness.release();
      final result = await run;

      expect(result.exitCode, RunalongExit.capture);
      expect(result.report['automation']['status'], 'passed');
      expect(result.report['capture']['status'], 'unavailable');
      expect(result.report['metrics']['frameCount'], 0);
    },
  );

  test(
    'cancellation terminates its child and preserves captured evidence',
    () async {
      final harness = await _Harness.create();
      final run = harness.start();
      await harness.childReady;
      await harness.recordFrame();
      harness.cancellation.cancel();
      final result = await run.timeout(const Duration(seconds: 8));

      expect(result.exitCode, RunalongExit.cancelled);
      expect(result.report['automation']['status'], 'cancelled');
      expect(result.report['capture']['status'], 'partial');
      expect(result.report['metrics']['frameCount'], 1);
      expect(await File('${result.directory}/report.json').exists(), isTrue);
    },
  );

  test(
    'deadline expiry has a distinct exit code and finalizes a report',
    () async {
      final harness = await _Harness.create();
      final result = await harness.start(
        timeout: const Duration(milliseconds: 700),
      );

      expect(result.exitCode, RunalongExit.timeout);
      expect(result.report['exitCode'], RunalongExit.timeout);
      expect(
        result.report['capture']['gaps'].toString(),
        contains('Run timed out.'),
      );
      expect(await File('${result.directory}/report.json').exists(), isTrue);
    },
  );

  test(
    'discovering the endpoint from launcher output marks startup coverage partial',
    () async {
      final harness = await _Harness.create();
      final run = harness.start(preAttach: false, mode: 'discover');
      await harness.childReady;
      await harness.fake.ready.timeout(const Duration(seconds: 5));
      await harness.recordFrame();
      await harness.release();
      final result = await run;

      expect(result.exitCode, 0);
      expect(result.report['metrics']['frameCount'], 1);
      expect(result.report['capture']['status'], 'partial');
      expect(
        result.report['capture']['gaps'].toString(),
        contains('initial frames may be missing'),
      );
      expect(jsonEncode(result.report), isNot(contains('fake-secret')));
    },
  );

  test(
    'an initially empty URI file lets the runner launch and publish its VM',
    () async {
      final harness = await _Harness.create();
      final uriFile = File('${harness.directory.path}/service-uri');
      await uriFile.writeAsString('');
      final run = harness.start(
        mode: 'publish-file',
        uriFile: uriFile.path,
        preAttach: false,
      );
      await harness.childReady;
      await harness.fake.ready.timeout(const Duration(seconds: 5));
      await harness.recordFrame();
      await harness.release();
      final result = await run;

      expect(result.exitCode, 0);
      expect(result.report['automation']['status'], 'passed');
      expect(result.report['capture']['status'], 'partial');
      expect(result.report['metrics']['frameCount'], 1);
    },
  );

  test(
    'ambiguous launcher endpoints stop capture without replacing the app or killing automation',
    () async {
      final harness = await _Harness.create();
      final other = await FakeVm.start();
      addTearDown(other.close);
      final run = harness.start(
        mode: 'ambiguous',
        preAttach: false,
        secondUri: other.uri,
      );
      await harness.childReady;
      await harness.fake.ready.timeout(const Duration(seconds: 5));
      await harness.recordFrame();
      await File(
        '${harness.directory.path}/release.second',
      ).writeAsString('switch');
      await harness.secondEndpoint;
      await harness.release();
      final result = await run;

      expect(result.exitCode, RunalongExit.capture);
      expect(result.report['automation']['status'], 'passed');
      expect(result.report['capture']['status'], 'partial');
      expect(result.report['capture']['connectionError'], isTrue);
      expect(result.report['metrics']['frameCount'], 1);
      expect(other.sockets, isEmpty);
      expect(
        result.report['capture']['warnings'].toString(),
        contains('Automatic capture stopped'),
      );
    },
  );

  test('an explicit endpoint ignores unrelated launcher URLs', () async {
    final harness = await _Harness.create();
    final other = await FakeVm.start();
    addTearDown(other.close);
    final run = harness.start(mode: 'ambiguous', secondUri: other.uri);
    await harness.childReady;
    await harness.recordFrame();
    await File(
      '${harness.directory.path}/release.second',
    ).writeAsString('switch');
    await harness.secondEndpoint;
    await harness.recordFrame(number: 2);
    await harness.release();
    final result = await run;

    expect(result.exitCode, 0);
    expect(result.report['capture']['status'], 'complete');
    expect(result.report['capture']['connectionError'], isNot(true));
    expect(result.report['metrics']['frameCount'], 2);
    expect(other.sockets, isEmpty);
  });

  test(
    'repeating the same discovered endpoint does not invalidate capture',
    () async {
      final harness = await _Harness.create();
      final run = harness.start(mode: 'repeat', preAttach: false);
      await harness.childReady;
      await harness.fake.ready.timeout(const Duration(seconds: 5));
      await harness.recordFrame();
      await harness.release();
      final result = await run;

      expect(result.exitCode, 0);
      expect(result.report['capture']['connectionError'], isNot(true));
      expect(result.report['metrics']['frameCount'], 1);
      expect(result.report['capture']['gaps'], hasLength(1));
    },
  );

  test(
    'the connection timeout excludes time spent launching the app',
    () async {
      final harness = await _Harness.create();
      final run = harness.start(
        mode: 'delayed-discover',
        preAttach: false,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await harness.childReady;
      await harness.fake.ready.timeout(const Duration(seconds: 5));
      await harness.recordFrame();
      await harness.release();
      final result = await run;

      expect(result.exitCode, 0);
      expect(result.report['capture']['status'], 'partial');
      expect(result.report['metrics']['frameCount'], 1);
    },
  );

  test(
    'cancellation cleans up a descendant that ignores SIGTERM',
    () async {
      final harness = await _Harness.create();
      final run = harness.start(mode: 'descendant');
      await harness.childReady;
      final match = RegExp(
        r'DESCENDANT_PID:(\d+)',
      ).firstMatch(harness.stdout.toString());
      expect(match, isNotNull);
      final pid = int.parse(match!.group(1)!);
      addTearDown(() async {
        if (await _processRunning(pid)) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      });
      expect(await _processRunning(pid), isTrue);
      harness.cancellation.cancel();
      final result = await run.timeout(const Duration(seconds: 10));
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (await _processRunning(pid) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(result.exitCode, RunalongExit.cancelled);
      expect(
        await _processRunning(pid),
        isFalse,
        reason:
            'A TERM-resistant automation descendant must not outlive its run.',
      );
    },
    skip: Platform.isWindows
        ? 'POSIX-specific signal and process-state checks.'
        : false,
  );

  test(
    'a VM disconnect preserves earlier frames and exposes the coverage gap',
    () async {
      final harness = await _Harness.create();
      final reconnecting = Completer<void>();
      final run = harness.start(
        onProgress: (progress) {
          if (progress.state == 'reconnecting' && !reconnecting.isCompleted) {
            reconnecting.complete();
          }
        },
      );
      await harness.childReady;
      await harness.recordFrame();
      for (final socket in harness.fake.sockets.toList()) {
        await socket.close();
      }
      await reconnecting.future.timeout(const Duration(seconds: 5));
      await harness.release();
      final result = await run;

      expect(result.report['metrics']['frameCount'], 1);
      expect(result.report['capture']['status'], 'partial');
      expect(
        result.report['capture']['gaps'].toString(),
        contains('connection closed'),
      );
      expect(result.report['automation']['status'], 'passed');
    },
  );

  test(
    'large simultaneous stdout and stderr are drained without deadlock',
    () async {
      final harness = await _Harness.create();
      final run = harness.start(mode: 'large');
      await harness.childReady;
      await harness.recordFrame();
      await harness.release();
      final result = await run.timeout(const Duration(seconds: 8));

      expect(result.exitCode, 0);
      expect(harness.stdout.length, greaterThanOrEqualTo(2 * 1024 * 1024));
      expect(harness.stderr.length, greaterThanOrEqualTo(2 * 1024 * 1024));
      expect(result.report['metrics']['frameCount'], 1);
    },
  );

  test(
    'offline regeneration reproduces the exact finalized JSON and HTML',
    () async {
      final harness = await _Harness.create();
      final run = harness.start();
      await harness.childReady;
      await harness.recordFrame(number: 3, build: 16000);
      await harness.recordFrame(number: 1, build: 1000);
      harness.fake.event('Flutter.Navigation', {
        'route': {
          'settings': {
            'name': '/products?token=private',
            'arguments': {'private': 'data'},
          },
        },
      });
      await harness.waitForRecord('"kind":"navigation"');
      await harness.release();
      final result = await run;
      final directory = Directory(result.directory);
      final beforeJson = await File(
        '${directory.path}/report.json',
      ).readAsString();
      final beforeHtml = await File(
        '${directory.path}/report.html',
      ).readAsString();
      final regenerated = await regenerateReport(directory);

      expect(regenerated, result.report);
      expect(
        await File('${directory.path}/report.json').readAsString(),
        beforeJson,
      );
      expect(
        await File('${directory.path}/report.html').readAsString(),
        beforeHtml,
      );
      expect(beforeJson, isNot(contains('private')));
    },
  );
}

/// Coordinates a real child process with a protocol-only VM fixture. Tests
/// release the child after an event is persisted, rather than assuming a delay
/// is long enough for compilation, socket delivery, or filesystem flushing.
final class _Harness {
  _Harness(this.directory, this.fake);

  final Directory directory;
  final FakeVm fake;
  final cancellation = CancellationToken();
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final _childReady = Completer<void>();
  final _secondEndpoint = Completer<void>();
  Future<void> get childReady =>
      _childReady.future.timeout(const Duration(seconds: 10));
  Future<void> get secondEndpoint =>
      _secondEndpoint.future.timeout(const Duration(seconds: 5));
  String get runDirectory => '${directory.path}/.runalong/runs/service-test';

  static Future<_Harness> create() async {
    final directory = await Directory.systemTemp.createTemp('runalong-run-');
    addTearDown(() => directory.delete(recursive: true));
    final fake = await FakeVm.start();
    addTearDown(fake.close);
    final harness = _Harness(directory, fake);
    await File('${directory.path}/child.dart').writeAsString(_childSource);
    return harness;
  }

  Future<RunResult> start({
    List<String> arguments = const [],
    int exitCode = 0,
    bool preAttach = true,
    String mode = 'normal',
    Duration timeout = const Duration(seconds: 15),
    Duration connectTimeout = const Duration(seconds: 3),
    String? uriFile,
    Uri? secondUri,
    void Function(RunProgress)? onProgress,
  }) {
    final result = RunService().run(
      RunOptions(
        command: [
          Platform.resolvedExecutable,
          '${directory.path}/child.dart',
          mode,
          '${directory.path}/release',
          '$exitCode',
          if ([
            'discover',
            'delayed-discover',
            'ambiguous',
            'repeat',
          ].contains(mode))
            fake.uri.toString(),
          if (mode == 'ambiguous') secondUri!.toString(),
          if (mode == 'publish-file') ...[uriFile!, fake.uri.toString()],
          ...arguments,
        ],
        workingDirectory: directory.path,
        vmServiceUri: preAttach ? fake.uri : null,
        vmServiceUriFile: uriFile,
        connectTimeout: connectTimeout,
        timeout: timeout,
        flushDuration: const Duration(milliseconds: 100),
      ),
      cancellation: cancellation,
      runId: 'service-test',
      onProgress: onProgress,
      onStdout: (text) {
        stdout.write(text);
        if (!_childReady.isCompleted &&
            stdout.toString().contains('CHILD_READY')) {
          _childReady.complete();
        }
        if (!_secondEndpoint.isCompleted &&
            stdout.toString().contains('SECOND_ENDPOINT')) {
          _secondEndpoint.complete();
        }
      },
      onStderr: stderr.write,
    );
    addTearDown(() async {
      cancellation.cancel();
      await result.timeout(const Duration(seconds: 10));
    });
    return result;
  }

  Future<void> release() =>
      File('${directory.path}/release').writeAsString('done');

  Future<void> recordFrame({
    int number = 1,
    int build = 2000,
    int raster = 3000,
  }) async {
    fake.frame(
      number: number,
      start: number * 100000,
      build: build,
      raster: raster,
    );
    await waitForRecord('"number":$number,');
  }

  Future<void> waitForRecord(String fragment) async {
    final file = File('$runDirectory/events.jsonl');
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists() &&
          (await file.readAsString()).contains(fragment)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Expected persisted event containing $fragment');
  }
}

Future<bool> _processRunning(int pid) async {
  final result = await Process.run('ps', ['-p', '$pid', '-o', 'stat=']);
  final state = (result.stdout as String).trim();
  return result.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
}

const _childSource = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final mode = arguments[0];
  if (mode == 'resist') {
    ProcessSignal.sigterm.watch().listen((_) {});
    stdout.writeln('RESISTANT_READY');
    await Future<void>.delayed(const Duration(minutes: 2));
    return;
  }
  if (mode == 'descendant') {
    final child = await Process.start(Platform.resolvedExecutable,
      [Platform.script.toFilePath(), 'resist']);
    await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
    stdout.writeln('DESCENDANT_PID:${child.pid}');
  }
  if (mode == 'delayed-discover') {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (['discover', 'delayed-discover', 'ambiguous', 'repeat'].contains(mode)) {
    stdout.writeln('The Dart VM service is listening on ${arguments[3]}');
  }
  if (mode == 'repeat') {
    stdout.writeln('The Dart VM service is listening on ${arguments[3]}');
  }
  if (mode == 'publish-file') {
    await File(arguments[3]).writeAsString(arguments[4]);
  }
  final skip = (mode == 'publish-file' || mode == 'ambiguous') ? 5 :
      ['discover', 'delayed-discover', 'repeat'].contains(mode) ? 4 : 3;
  stdout.writeln(jsonEncode(arguments.skip(skip).toList()));
  if (mode == 'large') {
    final bytes = List<int>.filled(2 * 1024 * 1024, 120);
    stdout.add(bytes);
    stderr.add(bytes);
    await Future.wait([stdout.flush(), stderr.flush()]);
    stdout.writeln();
  }
  stdout.writeln('CHILD_READY');
  await stdout.flush();
  if (mode == 'ambiguous') {
    while (!await File('${arguments[1]}.second').exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    stdout.writeln('The Dart VM service is listening on ${arguments[4]}');
    stdout.writeln('SECOND_ENDPOINT');
    await stdout.flush();
  }
  while (!await File(arguments[1]).exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  exit(int.parse(arguments[2]));
}
''';
