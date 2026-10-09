import 'dart:io';

import 'package:runalong/src/config.dart';
import 'package:runalong/src/run_service.dart';
import 'package:test/test.dart';

void main() {
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
