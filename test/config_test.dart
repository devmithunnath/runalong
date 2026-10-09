import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:runalong/src/config.dart';
import 'package:runalong/src/run_service.dart';
import 'package:test/test.dart';

void main() {
  test(
    'journey profile paths resolve against config and modes are validated',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'runalong-journey-config-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/runalong.yaml');
      const content = '''version: 1
profiles:
  login:
    command: [flutter, test, integration_test/app_test.dart]
    source_root: app
    journey_events_file: events.jsonl
    runner_adapter: dart-json
    capture: {mode: diagnose}
''';
      await file.writeAsString(content);
      final profile = (await loadProfiles(dir.path))['login']!;
      expect(profile.captureMode, 'diagnose');
      expect(profile.runnerAdapter, 'dart-json');
      expect(profile.sourceRoot, p.join(dir.path, 'app'));
      expect(profile.journeyEventsFile, p.join(dir.path, 'events.jsonl'));
      for (final invalid in [
        content.replaceFirst('diagnose', 'fast'),
        content.replaceFirst('dart-json', 'guess'),
      ]) {
        await file.writeAsString(invalid);
        expect(() => loadProfiles(dir.path), throwsFormatException);
      }
    },
  );

  test('machine batches retain every app endpoint rather than choosing one', () {
    const batch =
        '[{"event":"app.debugPort","params":{"wsUri":"ws://localhost:55/a/ws"}},'
        '{"event":"app.debugPort","params":{"wsUri":"ws://localhost:56/b/ws"}}]';
    expect(endpointsFromLine(batch).map((uri) => uri.port), [55, 56]);
    expect(endpointFromLine(batch), isNull);
  });

  test(
    'discovery ignores arbitrary app URLs and normalizes authenticated endpoints',
    () {
      expect(endpointFromLine('request https://example.com/orders'), isNull);
      expect(
        endpointFromLine(
          'The Dart VM service is listening on http://127.0.0.1:1234/secret=/',
        )?.toString(),
        'ws://127.0.0.1:1234/secret=/ws',
      );
      expect(
        endpointFromLine(
          '[{"event":"app.debugPort","params":{"wsUri":"ws://localhost:55/token/ws"}}]',
        )?.port,
        55,
      );
      expect(
        () => serviceWebSocketUri('file:///tmp/service'),
        throwsFormatException,
      );
      expect(
        endpointFromLine(
          'VMServiceFlutterDriver: Connecting to Flutter application at http://127.0.0.1:5432/token=/',
        )?.toString(),
        'ws://127.0.0.1:5432/token=/ws',
      );
    },
  );
  test(
    'flutter test discovery uses the forwarded host endpoint, not the device URL',
    () {
      expect(
        endpointFromLine(
          '[+1871 ms] VM Service URL on device: http://127.0.0.1:33435/token=/',
        ),
        isNull,
      );
      expect(
        endpointFromLine(
          '[   +4 ms] test 0: VM Service uri is available at http://127.0.0.1:51950/token=/',
        )?.toString(),
        'ws://127.0.0.1:51950/token=/ws',
      );
      expect(
        endpointFromLine('[        ] test 0: VM Service uri is not available'),
        isNull,
      );
    },
  );
  test(
    'profile loading validates budgets and preserves literal arguments',
    () async {
      final dir = await Directory.systemTemp.createTemp('runalong-config-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/runalong.yaml');
      await file.writeAsString('''version: 1
profiles:
  smoke:
    command: [dart, 'space in arg', '\$(literal)']
    environment: {id: test-phone, workload: smoke, physical: true}
    gates: {enabled: true, buildP95Ms: 12}
''');
      final config = await loadProfiles(dir.path);
      expect(config['smoke']!.command.last, r'$(literal)');
      expect(config['smoke']!.gates['buildP95Ms'], 12);
      await file.writeAsString(
        'version: 1\nprofiles:\n  smoke:\n    command: [dart]\n    gates: {enabled: true, typo: 12}\n',
      );
      expect(() => loadProfiles(dir.path), throwsFormatException);
    },
  );
  test(
    'gates require explicit budgets; percentages and nonfinite values rejected',
    () {
      expect(() => validateGates({'enabled': true}), throwsFormatException);
      expect(
        () => validateGates({'overBudgetPercent': 101}),
        throwsFormatException,
      );
      expect(() => positiveNumber('NaN', 'x'), throwsFormatException);
      expect(() => positiveNumber('Infinity', 'x'), throwsFormatException);
      expect(
        () => validateGates({'regressionPercent': 10}),
        throwsFormatException,
      );
    },
  );
}
