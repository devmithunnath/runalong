import 'dart:convert';

import 'package:runalong/src/model.dart';
import 'package:runalong/src/report_insights.dart';
import 'package:test/test.dart';

JsonMap _frame(
  int number, {
  int? time,
  int build = 1000,
  int raster = 1000,
  String segment = '1',
  String isolate = 'main',
  int receiptMs = 1000,
}) => FrameSample(
  segment: segment,
  isolate: isolate,
  number: number,
  startTimeMicros: time ?? number * 16667,
  buildMicros: build,
  rasterMicros: raster,
  elapsedMicros: build + raster,
  vsyncOverheadMicros: 0,
  receivedAt: _receipt(receiptMs),
).toJson();

String _receipt(int ms) => DateTime.utc(
  2026,
  10,
  9,
  12,
).add(Duration(milliseconds: ms)).toIso8601String();

JsonMap _report(
  List<JsonMap> frames, {
  double? budget = 16.6666667,
  String mode = 'profile',
  String status = 'complete',
  List<JsonMap> navigation = const [],
}) => {
  'frames': frames,
  'navigation': navigation,
  'metrics': {'budgetMs': budget},
  'environment': {'buildMode': mode},
  'capture': <String, dynamic>{'status': status},
  'automation': <String, dynamic>{'status': 'passed'},
  'budget': {'status': 'disabled'},
};

List<JsonMap> _findings(JsonMap insights) =>
    (insights['findings'] as List).cast<JsonMap>();

void main() {
  test('concrete observations check build and raster independently', () {
    final insights = buildInsights(
      _report([
        _frame(0, build: 12000, raster: 12000),
        _frame(1, build: 50000),
        _frame(2, raster: 30000),
      ]),
    );
    expect(insights['headline'], 'Investigate both UI build and raster work.');
    expect(insights['summary'], contains('2 of 3 captured frames'));
    expect(
      insights['summary'],
      contains('1 during UI build and 1 during raster'),
    );
    final findings = _findings(insights);
    expect(findings.map((finding) => finding['phase']), ['build', 'raster']);
    expect(findings.first['evidence'], containsPair('firstFrame', 1));
    expect(findings.first['evidence']['startMs'], 16.667);
    expect(findings.first['evidence']['endMs'], 16.667);
    expect(findings.first['evidence']['worstBuildMs'], 50.0);
    expect(findings.first['observation'], contains('3.00× budget'));
    expect(findings.first['title'], 'A UI build spike at 0.02 s');
    expect(findings.first['interpretation'], contains('do not identify'));
    expect(findings.first['nextStep'], contains('Flutter DevTools'));
    expect(insights['summary'], isNot(contains('stayed within budget')));
  });

  for (final phase in ['build', 'raster']) {
    test(
      '$phase-only finding points to work while preserving measured facts',
      () {
        final insights = buildInsights(
          _report([
            _frame(0),
            _frame(
              1,
              time: 18700000,
              build: phase == 'build' ? 93870 : 1000,
              raster: phase == 'raster' ? 93870 : 1000,
            ),
          ]),
        );
        final work = phase == 'build' ? 'UI build' : 'raster';
        final other = phase == 'build' ? 'Raster' : 'UI build';
        expect(insights['headline'], 'Start by investigating $work work.');
        expect(insights['summary'], contains('1 of 2 captured frames'));
        expect(insights['summary'], contains('worst $phase of 93.87 ms'));
        expect(
          insights['summary'],
          contains('$other work stayed within budget'),
        );
        expect(_findings(insights).single['title'], 'A $work spike at 18.70 s');
        expect(
          (insights['limitations'] as List).join(' '),
          contains('first captured frame in each segment and isolate'),
        );
      },
    );
  }

  test('unknown budget does not classify frames or claim a pass', () {
    final insights = buildInsights(
      _report([_frame(0, build: 90000, raster: 30000)], budget: null),
    );
    expect(insights['headline'], 'Set a frame budget to assess this capture.');
    expect(insights['summary'], contains('budget is unknown'));
    expect(insights['summary'], contains('90.00 ms'));
    expect(insights['summary'], contains('No performance pass is established'));
    expect(_findings(insights), isEmpty);
  });

  test('idle gaps do not count as slow frames and split phase groups', () {
    final fast = buildInsights(_report([_frame(0), _frame(1, time: 10000000)]));
    expect(_findings(fast), isEmpty);
    expect(
      fast['headline'],
      'Captured UI work stayed within the frame budget.',
    );
    expect(fast['summary'], contains('does not establish'));
    final slow = buildInsights(
      _report([
        _frame(0, build: 25000),
        _frame(1, time: 10000000, build: 25000),
      ]),
    );
    final findings = _findings(slow);
    expect(findings, hasLength(2));
    expect(findings[0]['evidence']['slowFrameCount'], 1);
    expect(findings[1]['evidence']['startMs'], 10000.0);
    expect(findings[1]['title'], 'A UI build spike at 10.00 s');
    expect(jsonEncode(slow), isNot(contains('0.1 FPS')));
  });

  test(
    'phase groups bridge only two healthy frames and at most one second',
    () {
      final insights = buildInsights(
        _report([
          _frame(0, build: 25000),
          _frame(1),
          _frame(2),
          _frame(3, build: 25000),
          _frame(4),
          _frame(5),
          _frame(6),
          _frame(7, build: 25000),
        ]),
      );
      final findings = _findings(insights);
      expect(findings, hasLength(2));
      expect(findings.first['evidence']['frameCount'], 4);
      expect(findings.first['evidence']['slowFrameCount'], 2);
      expect(findings.first['title'], 'Repeated slow UI work around 0.00 s');
      expect(findings.first['evidence']['lastFrame'], 3);

      final bounded = buildInsights(
        _report(
          List.generate(8, (i) => _frame(i, time: i * 200000, build: 25000)),
        ),
      );
      expect(_findings(bounded), hasLength(2));
      for (final finding in _findings(bounded)) {
        final evidence = finding['evidence'] as JsonMap;
        expect(
          evidence['endMs'] - evidence['startMs'],
          lessThanOrEqualTo(1000),
        );
      }
    },
  );

  test('segments and isolates never share a group or engine time origin', () {
    final insights = buildInsights(
      _report([
        _frame(1, time: 100000, build: 30000),
        _frame(2, time: 110000, segment: '2', build: 30000),
        _frame(3, time: 120000, isolate: 'worker', build: 30000),
      ]),
    );
    final findings = _findings(insights);
    expect(findings, hasLength(3));
    for (final finding in findings) {
      expect(finding['evidence']['frameCount'], 1);
      expect(finding['evidence']['startMs'], 0.0);
    }
  });

  test('debug and incomplete captures remain explicitly diagnostic', () {
    final report = _report(
      [_frame(0, build: 50000)],
      mode: 'debug',
      status: 'partial',
    );
    report['capture']['gaps'] = [
      {'reason': 'disconnected'},
    ];
    report['capture']['droppedEvents'] = 2;
    report['automation']['status'] = 'failed';
    final insights = buildInsights(report);
    final limitations = (insights['limitations'] as List).join(' ');
    expect(
      insights['summary'],
      startsWith('Treat this as a diagnostic capture'),
    );
    expect(limitations, contains('Debug build'));
    expect(limitations, contains('Capture is incomplete'));
    expect(limitations, contains('Capture gaps'));
    expect(limitations, contains('dropped or invalid'));
    expect(limitations, contains('Automation did not complete'));
    expect(_findings(insights).single['nextStep'], contains('profile capture'));
  });

  test('no frame evidence gives an actionable inconclusive result', () {
    final insights = buildInsights(_report([]));
    expect(insights['headline'], 'No frame evidence was captured.');
    expect(insights['summary'], contains('Verify attachment'));
    expect(_findings(insights), isEmpty);
  });

  test(
    'hints use preceding receipt, remain approximate, and preserve text',
    () {
      const route = '<img src=x onerror=alert(1)> **literal**';
      final report = _report(
        [_frame(0, build: 30000, receiptMs: 500)],
        navigation: [
          {'receivedAt': _receipt(100), 'routeName': route, 'isolate': 'main'},
          {
            'receivedAt': _receipt(800),
            'routeName': 'future',
            'isolate': 'main',
          },
        ],
      );
      final original = jsonEncode(report);
      final finding = _findings(buildInsights(report)).single;
      expect(finding['routeHint'], route);
      expect(finding['attribution'], contains('delivery may be batched'));
      expect(finding['attribution'], contains('does not establish cause'));
      expect(finding['title'], isNot(contains(route)));
      expect(jsonEncode(report), original);
    },
  );

  test('unnamed navigation clears stale route hints', () {
    final insights = buildInsights(
      _report(
        [_frame(0, build: 30000)],
        navigation: [
          {'receivedAt': _receipt(100), 'routeName': '/old'},
          {'receivedAt': _receipt(900)},
        ],
      ),
    );
    final finding = _findings(insights).single;
    expect(finding.containsKey('routeHint'), isFalse);
    expect(finding['attribution'], contains('Screen name unavailable'));
  });

  test('route changes within a phase group prevent screen attribution', () {
    final insights = buildInsights(
      _report(
        [
          _frame(0, build: 30000, receiptMs: 100),
          _frame(1, build: 30000, receiptMs: 200),
        ],
        navigation: [
          {'receivedAt': _receipt(50), 'routeName': '/first'},
          {'receivedAt': _receipt(150), 'routeName': '/second'},
        ],
      ),
    );
    expect(_findings(insights).single.containsKey('routeHint'), isFalse);
  });

  test('unscoped hints cannot assign a route among multiple isolates', () {
    final frames = [
      _frame(0, build: 30000),
      _frame(0, build: 30000, isolate: 'worker'),
    ];
    final unscoped = buildInsights(
      _report(
        frames,
        navigation: [
          {'receivedAt': _receipt(100), 'routeName': '/ambiguous'},
        ],
      ),
    );
    expect(
      _findings(unscoped).every((f) => !f.containsKey('routeHint')),
      isTrue,
    );
    final scoped = buildInsights(
      _report(
        frames,
        navigation: [
          {
            'receivedAt': _receipt(100),
            'routeName': '/main',
            'isolate': 'main',
          },
          {
            'receivedAt': _receipt(100),
            'routeName': '/worker',
            'isolate': 'worker',
          },
        ],
      ),
    );
    expect(_findings(scoped).map((f) => f['routeHint']), ['/main', '/worker']);
  });

  test('route context is not carried into a restarted segment', () {
    final insights = buildInsights(
      _report(
        [
          _frame(0, build: 30000, receiptMs: 100),
          _frame(0, build: 30000, segment: '2', receiptMs: 500),
        ],
        navigation: [
          {'receivedAt': _receipt(200), 'routeName': '/old', 'isolate': 'main'},
        ],
      ),
    );
    expect(
      _findings(insights).every((f) => !f.containsKey('routeHint')),
      isTrue,
    );
  });

  test(
    'strongest five are deterministic across frame and tied-route order',
    () {
      final frames = List.generate(
        8,
        (i) => _frame(i, time: i * 1000000, build: (i + 2) * 10000),
      );
      final navigation = [
        {'receivedAt': _receipt(100), 'routeName': '/a'},
        {'receivedAt': _receipt(100), 'routeName': '/b'},
      ];
      final forward = buildInsights(_report(frames, navigation: navigation));
      final reverse = buildInsights(
        _report(
          frames.reversed.toList(),
          navigation: navigation.reversed.toList(),
        ),
      );
      expect(jsonEncode(forward), jsonEncode(reverse));
      expect(_findings(forward), hasLength(5));
      expect(_findings(forward).map((f) => f['evidence']['firstFrame']), [
        7,
        6,
        5,
        4,
        3,
      ]);
      expect(forward['summary'], contains('5 moments below, selected from 8'));
    },
  );
}
