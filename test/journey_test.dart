import 'dart:convert';
import 'dart:io';

import 'package:runalong/src/journey.dart';
import 'package:runalong/src/model.dart';
import 'package:runalong/src/reporting.dart';
import 'package:test/test.dart';

JsonMap _manifest({String mode = 'measure'}) => {
  'schemaVersion': 2,
  'id': 'journey',
  'captureMode': mode,
  'startedAt': '2026-10-09T12:00:00Z',
  'finishedAt': '2026-10-09T12:00:10Z',
  'automation': {'status': 'passed'},
  'environment': {
    'id': 'phone',
    'workload': 'checkout',
    'buildMode': 'profile',
    'physical': true,
    'refreshRateHz': 60,
    'refreshRateSource': 'runtime',
  },
  'capture': {
    'status': 'complete',
    'mode': mode,
    'segments': [
      {'id': '1-1', 'connection': 1},
      {'id': '2-1', 'connection': 2},
    ],
    'telemetry': {
      'connections': [
        {
          'captureMode': mode,
          'memoryIntervalMs': 500,
          'settings': {
            'effectiveTimelineStreams': ['Dart', 'Embedder'],
            'profilePeriod': 1000,
          },
          'capabilities': {'clock': true, 'timeline': true},
        },
      ],
    },
  },
  'gates': {'enabled': true, 'buildP95Ms': 50},
};
FrameSample _frame(int id, {String segment = '1-1', int build = 20000}) =>
    FrameSample(
      segment: segment,
      isolate: 'main',
      number: id,
      startTimeMicros: 999000000 + id * 100,
      buildMicros: build,
      rasterMicros: 1000,
      elapsedMicros: build + 1000,
      vsyncOverheadMicros: 0,
      receivedAt: '2026-10-09T12:00:09Z',
    );
JsonMap _clock({
  int connection = 1,
  int host = 1000000,
  int vm = 5000000,
  int uncertainty = 100,
}) => {
  'kind': 'clock',
  'connection': connection,
  'hostMicros': host,
  'vmMicros': vm,
  'uncertaintyMicros': uncertainty,
};
JsonMap _context(
  String event,
  int vm, {
  String id = 'screen-1',
  String stable = 'cart',
  String label = 'Cart',
  String segment = '1-1',
  String? parent,
}) => {
  'kind': 'context',
  'segment': segment,
  'isolate': 'main',
  'version': 1,
  'event': event,
  'id': id,
  'stableId': stable,
  'label': label,
  'vmMicros': vm,
  'hostMicros': 99999999,
  'status': 'success',
  'parentId': ?parent,
};
JsonMap _timeline(int frame, int start, int end, {String segment = '1-1'}) => {
  'kind': 'frame_timeline',
  'segment': segment,
  'isolate': 'main',
  'frameNumber': frame,
  'vmStartMicros': start,
  'vmEndMicros': end,
};
List<JsonMap> _events() => [
  _clock(),
  _context('screen_start', 5100000),
  _context('screen_end', 5900000),
  _timeline(1, 5200000, 5221000),
  _timeline(2, 5400000, 5421000),
];
JsonMap _report({List<JsonMap>? events, String mode = 'measure'}) =>
    buildReport(
      _manifest(mode: mode),
      [_frame(1), _frame(2)],
      [],
      extraEvents: events ?? _events(),
    );

void main() {
  test('overlapping repeated identities remain explicitly unmatched', () {
    final report = _report(
      events: [
        ..._events(),
        _context(
          'operation_start',
          5200000,
          id: 'a',
          stable: 'load',
          parent: 'screen-1',
        ),
        _context(
          'operation_start',
          5300000,
          id: 'b',
          stable: 'load',
          parent: 'screen-1',
        ),
        _context(
          'operation_end',
          5600000,
          id: 'b',
          stable: 'load',
          parent: 'screen-1',
        ),
        _context(
          'operation_end',
          5700000,
          id: 'a',
          stable: 'load',
          parent: 'screen-1',
        ),
      ],
    );
    final items = (report['journey']['items'] as List).where(
      (i) => i['type'] == 'operation',
    );
    expect(items.every((i) => i['comparable'] == false), isTrue);
    final comparison = compareJourneys(report, report, compatible: true);
    expect(comparison['unmatchedCount'], 4);
    expect(
      (comparison['items'] as List)
          .where((i) => i['type'] == 'operation')
          .every((i) => i['status'] == 'inconclusive'),
      isTrue,
    );
  });

  test(
    'runtime file narrows local declaration candidates without upgrading provenance',
    () {
      final manifest = _manifest()
        ..['sourceIndex'] = {
          'revisionStatus': 'unverified',
          'entries': [
            {
              'name': 'Login.build',
              'uri': 'package:app/login.dart',
              'path': 'lib/login.dart',
              'line': 10,
            },
            {
              'name': 'Home.build',
              'uri': 'package:app/home.dart',
              'path': 'lib/home.dart',
              'line': 20,
            },
          ],
        };
      final report = buildReport(
        manifest,
        [_frame(1)],
        [],
        extraEvents: [
          ..._events(),
          {
            'kind': 'cpu',
            'segment': '1-1',
            'isolate': 'main',
            'vmStartMicros': 5200000,
            'vmEndMicros': 5300000,
            'functions': [
              {
                'name': 'build',
                'uri': 'package:app/login.dart',
                'provenance': 'runtime',
              },
            ],
            'samples': [
              {
                'vmMicros': 5250000,
                'stack': [0],
              },
            ],
          },
        ],
      );
      final fn = report['journey']['cpu'].single['functions'].single;
      expect(fn['sourceCandidates'], hasLength(1));
      expect(fn['sourceCandidates'].single['name'], 'Login.build');
      expect(fn['sourceCandidates'].single['provenance'], 'local_candidate');
    },
  );

  test(
    'raster work crossing screen end is boundary evidence, not attributed',
    () {
      final report = _report(
        events: [
          _clock(),
          _context('screen_start', 5100000),
          _context('screen_end', 5900000),
          {..._timeline(1, 5800000, 5850000), 'scope': 'build'},
          {..._timeline(1, 5880000, 5950000), 'scope': 'raster'},
          {..._timeline(2, 5400000, 5421000), 'scope': 'build'},
        ],
      );
      final journey = report['journey'];
      expect(journey['unalignedFrameCount'], 1);
      expect(journey['frames'].single['endMicros'], 1950000);
      expect(journey['items'].single['metrics']['frameCount'], 0);
      expect(journey['items'].single['metrics']['boundaryFrameCount'], 1);
    },
  );
  test(
    'GC receipts remain approximate and resource comparisons do not gate',
    () {
      final events = [
        ..._events(),
        <String, dynamic>{'kind': 'gc', 'connection': 1, 'hostMicros': 1300000},
      ];
      final report = _report(events: events);
      expect(report['journey']['items'].single['metrics']['gcCount'], 0);
      expect(
        report['journey']['items'].single['metrics']['approximateGcCount'],
        1,
      );
      final comparison = compareReports(report, report, regressionPercent: 5);
      expect(
        comparison['journey']['items']
            .single['reportingOnly']['durationMs']['delta'],
        0,
      );
      expect(
        comparison['journey']['items']
            .single['reportingOnly']['durationMs']['gate'],
        false,
      );
    },
  );

  test(
    'exact timeline IDs join incompatible engine and VM clocks, not receipts',
    () {
      final report = _report();
      final journey = report['journey'] as JsonMap;
      final item = (journey['items'] as List).single as JsonMap;
      expect(item['startMicros'], 1100000);
      expect(item['endMicros'], 1900000);
      expect(item['metrics']['frameCount'], 2);
      expect(item['metrics']['buildMs']['p95'], 20);
      expect(report['insights']['headline'], 'Start with Cart.');
      expect(
        report['insights']['findings'][0]['evidence']['journeyItemId'],
        item['id'],
      );
      expect(journey['frames'][0]['startTimeMicros'], greaterThan(999000000));
      expect(journey['frames'][0]['startMicros'], 1200000);
    },
  );
  test(
    'unmapped frames remain raw and are not guessed from delivery order',
    () {
      final events = _events()
          .where((e) => e['kind'] != 'frame_timeline')
          .toList();
      final report = _report(events: events);
      expect(report['metrics']['frameCount'], 2);
      expect(report['journey']['unalignedFrameCount'], 2);
      expect(report['journey']['items'][0]['metrics']['frameCount'], 0);
    },
  );
  test('restarts use separate clock anchors and repeated frame numbers', () {
    final report = buildReport(
      _manifest(),
      [_frame(1), _frame(1, segment: '2-1')],
      [],
      extraEvents: [
        ..._events(),
        _clock(connection: 2, host: 9000000, vm: 100000),
        _context('screen_start', 100000, segment: '2-1'),
        _context('screen_end', 500000, segment: '2-1'),
        _timeline(1, 200000, 221000, segment: '2-1'),
      ],
    );
    final items = (report['journey']['items'] as List).cast<JsonMap>();
    expect(items.length, 2);
    expect(items[0]['metrics']['frameCount'], 1);
    expect(items[1]['metrics']['frameCount'], 1);
    expect(items[1]['startMicros'], 9000000);
    expect(items[0]['comparisonKey'], endsWith('#1'));
    expect(items[1]['comparisonKey'], endsWith('#2'));
  });
  test('clock uncertainty excludes boundary frames and reports overlap', () {
    final report = _report(
      events: [..._events(), _timeline(2, 5100050, 5121050)],
    );
    final metrics = report['journey']['items'][0]['metrics'];
    expect(metrics['frameCount'], 1);
    expect(metrics['boundaryFrameCount'], 1);
  });
  test(
    'receipt-only runner boundaries are approximate, never exact actions',
    () {
      final report = _report(
        events: [
          ..._events(),
          {
            'kind': 'runner',
            'event': 'test_start',
            'id': 't',
            'stableId': 'test.dart::checkout',
            'label': 'Checkout',
            'hostMicros': 1000000,
            'uncertaintyMicros': null,
          },
          {
            'kind': 'runner',
            'event': 'test_end',
            'id': 't',
            'stableId': 'test.dart::checkout',
            'label': 'Checkout',
            'hostMicros': 2000000,
            'uncertaintyMicros': null,
            'status': 'passed',
          },
        ],
      );
      final items = (report['journey']['items'] as List).cast<JsonMap>();
      final runner = items.singleWhere((e) => e['type'] == 'test');
      expect(runner['coverage'], 'approximate');
      expect(runner['metrics']['status'], 'approximate');
      expect(runner['metrics']['frameCount'], 2);
      expect(runner['coverage'], isNot('bounded'));
      expect(
        items.singleWhere((e) => e['type'] == 'screen')['parentId'],
        runner['id'],
      );
    },
  );
  test(
    'one process snapshot counts shared isolate group heap once, RSS separately',
    () {
      final group = {
        'id': 'group1',
        'heapUsage': 100,
        'heapCapacity': 200,
        'externalUsage': 25,
      };
      final report = _report(
        events: [
          ..._events(),
          {
            'kind': 'memory',
            'connection': 1,
            'hostMicros': 1300000,
            'vmMicros': 5300000,
            'uncertaintyMicros': 100,
            'groups': [
              group,
              group,
              {
                'id': 'group2',
                'heapUsage': 20,
                'heapCapacity': 40,
                'externalUsage': 5,
              },
            ],
            'rssBytes': 1000,
          },
        ],
      );
      final metrics = report['journey']['items'][0]['metrics']['memory'];
      expect(metrics['peakHeapBytes'], 120);
      expect(metrics['peakExternalBytes'], 30);
      expect(metrics['peakRssBytes'], 1000);
      expect(metrics['heapDeltaBytes'], isNull);
      expect(report['journey']['memory'][0]['groupCount'], 2);
    },
  );
  test(
    'CPU windows are filtered together; repeated polls and recursive frames dedupe',
    () {
      final cpu = <String, dynamic>{
        'kind': 'cpu',
        'segment': '1-1',
        'isolate': 'main',
        'vmStartMicros': 5000000,
        'vmEndMicros': 6000000,
        'samplePeriodMicros': 1000,
        'functions': [
          {
            'name': 'Cart.build',
            'uri': 'package:shop/cart.dart',
            'line': 30,
            'provenance': 'runtime',
          },
          {'name': 'parse', 'provenance': 'runtime'},
        ],
        'samples': [
          {
            'vmMicros': 5300000,
            'stack': [0, 0, 1],
          },
          {
            'vmMicros': 5990000,
            'stack': [1],
          },
        ],
      };
      final report = _report(events: [..._events(), cpu, cpu]);
      final metrics = report['journey']['items'][0]['metrics']['cpu'];
      expect(metrics['sampleCount'], 1);
      expect(metrics['functions'], hasLength(2));
      expect(metrics['functions'][0]['samples'], 1);
      expect(metrics['functions'][0]['selfSamples'], 1);
      expect(metrics['functions'][1]['selfSamples'], 0);
      expect(metrics['functions'][0]['sampleSharePercent'], 100);
    },
  );
  test(
    'unfinished and uncalibrated contexts do not create bounded measurements',
    () {
      for (final remove in ['screen_end', 'clock']) {
        final report = _report(
          events: _events()
              .where((e) => e['event'] != remove && e['kind'] != remove)
              .toList(),
        );
        expect(report['journey']['items'][0]['coverage'], 'incomplete');
        expect(
          report['journey']['items'][0]['metrics']['status'],
          remove == 'screen_end' ? 'observed' : 'unavailable',
        );
      }
    },
  );
  test('local source matches remain candidates with revision provenance', () {
    final manifest = _manifest()
      ..['sourceIndex'] = {
        'revisionStatus': 'mismatch',
        'entries': [
          {
            'name': 'Cart',
            'uri': 'package:shop/cart.dart',
            'path': 'lib/cart.dart',
            'line': 12,
            'column': 1,
            'provenance': 'local_candidate',
          },
        ],
      };
    final report = buildReport(
      manifest,
      [_frame(1)],
      [],
      extraEvents: [
        ..._events(),
        {
          'kind': 'widget_rebuild',
          'segment': '1-1',
          'isolate': 'main',
          'frameNumber': 1,
          'widgets': [
            {
              'name': 'Cart',
              'count': 2,
              'source': {
                'uri': 'package:shop/cart.dart',
                'line': 17,
                'provenance': 'runtime_creation',
              },
            },
          ],
        },
      ],
    );
    final widget = report['journey']['widgetRebuilds'][0]['widgets'][0];
    expect(widget['source']['line'], 17);
    expect(widget['source']['provenance'], 'runtime_creation');
    expect(widget['sourceCandidates'][0]['line'], 12);
    expect(widget['sourceCandidates'][0]['provenance'], 'local_candidate');
    expect(widget['sourceCandidates'][0]['revisionStatus'], 'mismatch');
  });
  test('baseline matches hierarchy+stable identity+occurrence, not labels', () {
    final a = _report();
    final b = _report(
      events: _events()
          .map(
            (e) => e['kind'] == 'context'
                ? <String, dynamic>{...e, 'label': 'Basket'}
                : e,
          )
          .toList(),
    );
    final compare = compareReports(a, b, regressionPercent: 5);
    expect(compare['status'], 'pass');
    expect(compare['journey']['items'][0]['status'], 'pass');
    expect(compare['journey']['items'][0]['label'], 'Basket');
    final renamed = _report(
      events: _events()
          .map(
            (e) => e['kind'] == 'context'
                ? <String, dynamic>{...e, 'stableId': 'other'}
                : e,
          )
          .toList(),
    );
    expect(compareReports(a, renamed)['journey']['unmatchedCount'], 2);
  });
  test(
    'diagnose never passes rendering gates; matched diagnose reports compare descriptively',
    () {
      final measured = _report(), diagnosed = _report(mode: 'diagnose');
      expect(diagnosed['budget']['status'], 'inconclusive');
      expect(
        compareReports(measured, diagnosed, regressionPercent: 5)['status'],
        'inconclusive',
      );
      final comparison = compareReports(
        diagnosed,
        diagnosed,
        regressionPercent: 5,
      );
      expect(comparison['status'], 'compared');
      expect(comparison['renderingGateEligible'], false);
      expect(comparison['journey']['items'][0]['status'], 'compared');
      applyComparison(diagnosed, comparison);
      expect(diagnosed['budget']['status'], 'inconclusive');
    },
  );
  test(
    'effective telemetry settings must match; sample record counts may differ',
    () {
      final a = _report(), b = _report();
      b['capture']['telemetry']['connections'][0]['coverage'] = {
        'records': 9000,
      };
      expect(compareReports(a, b)['status'], 'compared');
      b['capture']['telemetry']['connections'][0]['settings']['profilePeriod'] =
          500;
      expect(compareReports(a, b)['status'], 'inconclusive');
    },
  );
  test(
    'schema 2 regeneration keeps report and raw evidence deterministic',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'runalong-journey-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final manifest = _manifest(),
          frames = [_frame(1), _frame(2)],
          events = _events();
      final report = buildReport(manifest, frames, [], extraEvents: events);
      await File(
        '${directory.path}/manifest.json',
      ).writeAsString(jsonEncode(manifest));
      final raw = [
        ...frames.map((f) => f.toJson()),
        ...events,
      ].map(jsonEncode).join('\n');
      await File('${directory.path}/events.jsonl').writeAsString(raw);
      await writeReports(directory, report);
      final before = await File('${directory.path}/report.json').readAsString();
      await regenerateReport(directory);
      expect(
        await File('${directory.path}/report.json').readAsString(),
        before,
      );
      expect(await File('${directory.path}/events.jsonl').readAsString(), raw);
      final html = await File('${directory.path}/report.html').readAsString();
      expect(html, contains('Shared recording clock'));
      expect(html, contains('role="tablist"'));
      expect(html, contains('runalongSelectJourney'));
      expect(html, isNot(contains('RUNALONG_JOURNEY_')));
    },
  );
  test(
    'custom selection filters every telemetry stream by the same interval',
    () {
      final report = _report();
      final summary = summarizeJourneyInterval(report['journey'] as JsonMap, {
        'startMicros': 1190000,
        'endMicros': 1300000,
        'uncertaintyMicros': 0,
      }, budgetMs: 16.67);
      expect(summary['frameCount'], 1);
      expect(summary['overBudgetCount'], 1);
    },
  );
}
