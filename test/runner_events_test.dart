import 'dart:convert';
import 'dart:io';

import 'package:runalong/src/model.dart';
import 'package:runalong/src/runner_events.dart';
import 'package:test/test.dart';

void main() {
  test(
    'loader and teardown pseudo tests do not expose host paths as journeys',
    () {
      final events = <JsonMap>[];
      final parser = RunnerEvents(hostMicros: () => 1000, onRecord: events.add);
      for (final name in [
        'loading /private/app/test.dart',
        '(tearDownAll)',
        '(setUpAll)',
      ]) {
        parser.dartLine(
          jsonEncode({
            'type': 'testStart',
            'time': 0,
            'test': {'id': 1, 'name': name, 'groupIDs': <int>[]},
          }),
        );
        parser.dartLine(
          jsonEncode({
            'type': 'testDone',
            'time': 1,
            'testID': 1,
            'hidden': true,
          }),
        );
      }
      expect(events, isEmpty);
    },
  );

  test('Dart reporter keeps test boundaries, not logs or credentials', () {
    final events = <JsonMap>[];
    final parser = RunnerEvents(
      hostMicros: () => 5000000,
      onRecord: events.add,
    );
    void line(JsonMap value) => parser.dartLine(jsonEncode(value));
    line({'type': 'start', 'time': 0});
    line({
      'type': 'suite',
      'time': 1,
      'suite': {
        'id': 0,
        'path': '/private/app/integration_test/login_test.dart',
      },
    });
    line({
      'type': 'testStart',
      'time': 100,
      'test': {'id': 7, 'suiteID': 0, 'name': 'Login മലയാളം', 'hidden': false},
    });
    line({'type': 'print', 'time': 110, 'message': 'password=private-value'});
    line({'type': 'testDone', 'time': 350, 'testID': 7, 'result': 'failure'});
    expect(events, hasLength(2));
    expect(events.first['hostMicros'], 5100000);
    expect(events.last['hostMicros'], 5350000);
    expect(events.first['stableId'], 'login_test.dart::Login മലയാളം');
    expect(events.last['status'], 'failed');
    expect(events.first['uncertaintyMicros'], isNull);
    expect(jsonEncode(events), isNot(contains('private')));
  });

  test(
    'external input requires a clock anchor and ignores duplicate boundaries',
    () {
      final events = <JsonMap>[];
      final parser = RunnerEvents(
        hostMicros: () => 100000,
        onRecord: events.add,
      );
      final record = {
        'version': 1,
        'event': 'step_start',
        'id': 'a',
        'stableId': 'login.submit',
        'label': 'Submit',
        'timeMicros': 200,
      };
      parser.externalLine(jsonEncode(record));
      expect(events, isEmpty);
      expect(parser.invalidRecords, 1);
      parser.externalLine(
        jsonEncode({'version': 1, 'event': 'sync', 'timeMicros': 100}),
      );
      parser.externalLine(jsonEncode(record));
      parser.externalLine(jsonEncode(record));
      expect(events, hasLength(1));
      expect(events.single['hostMicros'], 100100);
      expect(events.single['attribution'], 'receipt-aligned');
    },
  );

  test('incremental JSONL survives partial UTF8 writes', () async {
    final directory = await Directory.systemTemp.createTemp('runalong-events-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/events.jsonl');
    final events = <JsonMap>[];
    final parser = RunnerEvents(hostMicros: () => 1000, onRecord: events.add);
    final bytes = utf8.encode(
      '${jsonEncode({'version': 1, 'event': 'sync', 'timeMicros': 0})}\n${jsonEncode({'version': 1, 'event': 'step_start', 'id': 'a', 'stableId': 'screen', 'label': 'മലയാളം', 'timeMicros': 200})}\n',
    );
    final split = bytes.indexOf(0xe0) + 1;
    await file.writeAsBytes(bytes.sublist(0, split));
    await parser.readFile(file.path);
    await file.writeAsBytes(bytes.sublist(split), mode: FileMode.append);
    await parser.readFile(file.path, finish: true);
    expect(events.single['label'], 'മലയാളം');
    expect(parser.invalidRecords, 0);
  });
}
