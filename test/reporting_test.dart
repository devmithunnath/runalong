import 'dart:convert';
import 'dart:io';

import 'package:runalong/src/model.dart';
import 'package:runalong/src/reporting.dart';
import 'package:test/test.dart';

JsonMap manifest({
  double? hz = 60,
  String mode = 'profile',
  String status = 'complete',
  JsonMap gates = const {},
}) => {
  'schemaVersion': 1,
  'id': 'fixture',
  'startedAt': '2026-10-09T12:00:00Z',
  'finishedAt': '2026-10-09T12:00:02Z',
  'automation': {'status': 'passed', 'exitCode': 0},
  'capture': {
    'status': status,
    'segments': 1,
    'gaps': <dynamic>[],
    'warnings': <dynamic>[],
    'invalidEvents': 0,
    'droppedEvents': 0,
  },
  'environment': {
    'id': 'phone-a',
    'workload': 'scroll',
    'physical': true,
    'buildMode': mode,
    'refreshRateHz': hz,
    'refreshRateSource': hz == null ? null : 'override',
    'model': 'fixture',
    'osVersion': '1',
  },
  'gates': gates,
};

FrameSample sample(
  int number, {
  int build = 1000,
  int raster = 2000,
  int? time,
  String segment = '1',
  String isolate = 'main',
}) => FrameSample(
  segment: segment,
  isolate: isolate,
  number: number,
  startTimeMicros: time ?? number * 16667,
  buildMicros: build,
  rasterMicros: raster,
  elapsedMicros: build + raster,
  vsyncOverheadMicros: 0,
  receivedAt: '2026-10-09T12:00:00Z',
);

void main() {
  group('measurements', () {
    test('nearest rank, independent phases and immutable manifest', () {
      final original = manifest();
      final report = buildReport(
        original,
        List.generate(100, (i) => sample(i, build: (i + 1) * 1000)),
        [],
      );
      expect(report['metrics']['buildMs'], {
        'p50': 50.0,
        'p90': 90.0,
        'p95': 95.0,
        'p99': 99.0,
        'max': 100.0,
      });
      expect(report['metrics']['rasterMs']['p95'], 2.0);
      expect(original.containsKey('metrics'), isFalse);
    });

    for (final hz in [60.0, 90.0, 120.0]) {
      test('$hz Hz budgets count either phase once, never their sum', () {
        final budget = 1000000 / hz;
        final report = buildReport(manifest(hz: hz), [
          sample(
            0,
            build: (budget * .7).floor(),
            raster: (budget * .7).floor(),
          ),
          sample(1, build: budget.ceil() + 1),
          sample(2, raster: budget.ceil() + 1),
          sample(3, build: budget.ceil() + 1, raster: budget.ceil() + 1),
        ], []);
        expect(report['metrics']['overBudgetCount'], 3);
        expect(report['metrics']['overBudgetPercent'], 75.0);
        expect(report['metrics']['budgetMs'], closeTo(1000 / hz, .001));
      });
    }

    test('unknown budgets stay unavailable and never count idle as jank', () {
      final frames = [sample(0), sample(1, time: 10000000)];
      final unknown = buildReport(manifest(hz: null), frames, []);
      expect(unknown['metrics']['budgetMs'], isNull);
      expect(unknown['metrics']['overBudgetCount'], isNull);
      final known = buildReport(manifest(), frames, []);
      expect(known['metrics']['overBudgetCount'], 0);
      expect(known['metrics']['cadence']['medianIntervalMs'], 10000.0);
      expect(known['metrics']['cadence']['medianCadenceHz'], .1);
    });

    test(
      'deduplicates and orders within isolate segments without joining clocks',
      () {
        final report = buildReport(manifest(), [
          sample(2),
          sample(1),
          sample(2),
          sample(1, segment: '2'),
          sample(1, isolate: 'worker'),
        ], []);
        expect(report['metrics']['frameCount'], 4);
        expect(report['metrics']['cadence']['intervalCount'], 1);
        final frames = report['frames'] as List;
        expect(frames.first['number'], 1);
        expect(frames[1]['number'], 2);
      },
    );

    test('no frames produces null percentiles rather than zero success', () {
      final report = buildReport(
        manifest(gates: {'enabled': true, 'buildP95Ms': 5}),
        [],
        [],
      );
      expect(report['metrics']['buildMs']['p95'], isNull);
      expect(report['budget']['status'], 'inconclusive');
    });
  });

  group('gates', () {
    test('failed or unfinished automation cannot pass an absolute budget', () {
      for (final state in [
        'failed',
        'timed_out',
        'cancelled',
        'not_started',
        'running',
      ]) {
        final source = manifest(gates: {'enabled': true, 'buildP95Ms': 10});
        source['automation'] = {
          'status': state,
          'exitCode': state == 'failed' ? 7 : null,
        };
        expect(
          buildReport(source, [sample(0)], [])['budget']['status'],
          'inconclusive',
        );
      }
    });

    test('explicit attach-only capture can pass an absolute budget', () {
      final source = manifest(gates: {'enabled': true, 'buildP95Ms': 10});
      source['automation'] = {'status': 'not_applicable', 'exitCode': null};
      expect(buildReport(source, [sample(0)], [])['budget']['status'], 'pass');
    });
    test('disabled gates never fail diagnostic runs', () {
      final report = buildReport(manifest(mode: 'debug'), [
        sample(0, build: 1000000),
      ], []);
      expect(report['budget']['status'], 'disabled');
    });

    test(
      'absolute gates accept verified complete profile and report failures',
      () {
        final config = manifest(gates: {'enabled': true, 'buildP95Ms': 5});
        expect(
          buildReport(config, [sample(0)], [])['budget']['status'],
          'pass',
        );
        expect(
          buildReport(config, [sample(0, build: 6000)], [])['budget']['status'],
          'fail',
        );
      },
    );

    for (final mode in ['debug', 'unknown']) {
      test('$mode cannot pass a gate', () {
        final report = buildReport(
          manifest(mode: mode, gates: {'enabled': true, 'buildP95Ms': 5}),
          [sample(0)],
          [],
        );
        expect(report['budget']['status'], 'inconclusive');
      });
    }

    test(
      'partial capture and missing refresh rate cannot pass percentage gate',
      () {
        for (final config in [
          manifest(status: 'partial'),
          manifest(hz: null),
        ]) {
          config['gates'] = {'enabled': true, 'overBudgetPercent': 5};
          expect(
            buildReport(config, [sample(0)], [])['budget']['status'],
            'inconclusive',
          );
        }
      },
    );
  });

  group('comparison', () {
    JsonMap measured({int build = 1000}) =>
        buildReport(manifest(), [sample(0, build: build)], []);

    test(
      'aborted automation cannot become a passing standalone comparison',
      () {
        for (final state in [
          'failed',
          'timed_out',
          'cancelled',
          'not_started',
          'running',
        ]) {
          final candidate = measured();
          candidate['automation'] = {'status': state, 'exitCode': 7};
          expect(
            compareReports(
              measured(),
              candidate,
              regressionPercent: 10,
            )['status'],
            'inconclusive',
          );
          expect(
            compareReports(
              candidate,
              measured(),
              regressionPercent: 10,
            )['status'],
            'inconclusive',
          );
        }
      },
    );

    test(
      'matching attach-only workloads compare, mixing run types does not',
      () {
        final before = measured();
        final after = measured();
        before['automation'] = {'status': 'not_applicable', 'exitCode': null};
        after['automation'] = {'status': 'not_applicable', 'exitCode': null};
        expect(
          compareReports(before, after, regressionPercent: 10)['status'],
          'pass',
        );
        expect(
          compareReports(before, measured(), regressionPercent: 10)['status'],
          'inconclusive',
        );
      },
    );

    test('known OS mismatch is incompatible', () {
      final before = measured();
      final after = measured();
      before['environment']['os'] = 'android';
      after['environment']['os'] = 'ios';
      expect(compareReports(before, after)['status'], 'inconclusive');
    });

    test('unknown schema cannot be compared as a supported report', () {
      final future = measured()..['schemaVersion'] = 2;
      final comparison = compareReports(measured(), future);
      expect(comparison['status'], 'inconclusive');
      expect(comparison['compatible'], false);
      expect(
        comparison['reasons'],
        contains(contains('Unsupported candidate schema')),
      );
    });

    test('reports differences without an implicit threshold', () {
      final comparison = compareReports(measured(), measured(build: 2000));
      expect(comparison['status'], 'compared');
      expect(comparison['metrics']['buildMs']['changePercent'], 100);
      expect(comparison['regressionPercent'], isNull);
    });

    test('explicit regression threshold gates the independent phase p95s', () {
      expect(
        compareReports(
          measured(),
          measured(build: 2000),
          regressionPercent: 10,
        )['status'],
        'fail',
      );
      expect(
        compareReports(
          measured(),
          measured(build: 1050),
          regressionPercent: 10,
        )['status'],
        'pass',
      );
    });

    test(
      'missing identities, simulators, refresh mismatch and gaps are inconclusive',
      () {
        for (final change in <void Function(JsonMap)>[
          (r) => (r['environment'] as JsonMap).remove('id'),
          (r) => r['environment']['workload'] = 'different',
          (r) => r['environment']['physical'] = false,
          (r) => r['environment']['refreshRateHz'] = 120,
          (r) => r['environment']['refreshRateSource'] = null,
          (r) => r['capture']['status'] = 'partial',
        ]) {
          final candidate = measured();
          change(candidate);
          expect(
            compareReports(measured(), candidate)['status'],
            'inconclusive',
          );
        }
      },
    );

    test('baseline with zero time is explicit, never infinity', () {
      expect(
        compareReports(measured(build: 0), measured())['status'],
        'inconclusive',
      );
      expect(
        compareReports(measured(build: 0), measured(build: 0))['status'],
        'compared',
      );
    });

    test(
      'merge preserves eligibility and requires explicit regression threshold',
      () {
        final report = buildReport(
          manifest(gates: {'enabled': true, 'baseline': 'before'}),
          [sample(0)],
          [],
        );
        applyComparison(report, compareReports(measured(), report));
        expect(report['budget']['status'], 'inconclusive');
        final eligible = buildReport(
          manifest(gates: {'enabled': true, 'baseline': 'before'}),
          [sample(0)],
          [],
        );
        applyComparison(
          eligible,
          compareReports(measured(), eligible, regressionPercent: 5),
        );
        expect(eligible['budget']['status'], 'pass');
        final debug = buildReport(
          manifest(
            mode: 'debug',
            gates: {'enabled': true, 'baseline': 'before'},
          ),
          [sample(0)],
          [],
        );
        applyComparison(debug, {'status': 'pass', 'reasons': <String>[]});
        expect(debug['budget']['status'], 'inconclusive');
      },
    );
  });

  group('artifacts', () {
    late Directory directory;
    setUp(
      () async => directory = await Directory.systemTemp.createTemp(
        'runalong-report-test-',
      ),
    );
    tearDown(() async => directory.delete(recursive: true));

    Future<void> writeSource(JsonMap source, List<JsonMap> events) async {
      await File(
        '${directory.path}/manifest.json',
      ).writeAsString(jsonEncode(source));
      await File(
        '${directory.path}/events.jsonl',
      ).writeAsString('${events.map(jsonEncode).join('\n')}\n');
    }

    test(
      'CI summary explains partial capture gaps with bounded escaped text',
      () async {
        final source = manifest(status: 'partial');
        source['capture']['gaps'] = [
          {
            'reason':
                'Automation started before attachment; initial frames may be missing.',
          },
          {'reason': 'VM connection closed; reconnecting.'},
          {'reason': '<untrusted>\n${'x' * 1000}'},
        ];
        await writeReports(directory, buildReport(source, [sample(0)], []));
        final summary = await File(
          '${directory.path}/summary.md',
        ).readAsString();
        expect(
          summary,
          contains('Capture gap: Automation started before attachment'),
        );
        expect(
          summary,
          contains('Capture gap: VM connection closed; reconnecting.'),
        );
        expect(summary, contains('Capture gap: &lt;untrusted&gt; '));
        expect(summary, isNot(contains('x' * 401)));
        expect(summary, contains('…'));
      },
    );

    test('unfinalized manifest recovers frames as partial capture', () async {
      final source = manifest(status: 'unavailable');
      source['finishedAt'] = null;
      await writeSource(source, [sample(0).toJson()]);
      final report = await regenerateReport(directory);
      expect(report['metrics']['frameCount'], 1);
      expect(report['capture']['status'], 'partial');
      expect(
        report['capture']['warnings'],
        contains(contains('not finalized')),
      );
      expect(report['finishedAt'], null);
    });

    test(
      'unsupported manifest schema fails clearly without overwriting artifacts',
      () async {
        final source = manifest()..['schemaVersion'] = 2;
        await writeSource(source, [sample(0).toJson()]);
        await expectLater(
          regenerateReport(directory),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unsupported manifest schema'),
            ),
          ),
        );
        expect(await File('${directory.path}/report.json').exists(), false);
      },
    );

    test(
      'canonical serialization ignores insertion order throughout the document',
      () async {
        final original = buildReport(manifest(), [sample(0)], []);
        original['exitCode'] = 0;
        await writeReports(directory, original);
        final first = await Future.wait([
          for (final name in ['report.json', 'report.html', 'summary.md'])
            File('${directory.path}/$name').readAsString(),
        ]);
        final reordered = <String, dynamic>{
          'exitCode': 0,
          ...original,
          'environment': <String, dynamic>{
            for (final key
                in (original['environment'] as JsonMap).keys.toList().reversed)
              key: original['environment'][key],
          },
        };
        await writeReports(directory, reordered);
        final second = await Future.wait([
          for (final name in ['report.json', 'report.html', 'summary.md'])
            File('${directory.path}/$name').readAsString(),
        ]);
        expect(second, first);
      },
    );

    test(
      'offline regeneration matches original metrics and leaves source untouched',
      () async {
        final source = manifest();
        final frames = [sample(2), sample(1)];
        await writeSource(source, frames.map((f) => f.toJson()).toList());
        final originalManifest = await File(
          '${directory.path}/manifest.json',
        ).readAsString();
        final regenerated = await regenerateReport(directory);
        expect(regenerated, buildReport(source, frames, []));
        final json = await File('${directory.path}/report.json').readAsString();
        await regenerateReport(directory);
        expect(
          await File('${directory.path}/report.json').readAsString(),
          json,
        );
        expect(
          await File('${directory.path}/manifest.json').readAsString(),
          originalManifest,
        );
        expect(await File('${directory.path}/report.html').exists(), isTrue);
        expect(await File('${directory.path}/summary.md').exists(), isTrue);
      },
    );

    test('recovers truncated final line and marks capture partial', () async {
      await writeSource(manifest(), [sample(0).toJson()]);
      await File(
        '${directory.path}/events.jsonl',
      ).writeAsString('{"kind":', mode: FileMode.append);
      final report = await regenerateReport(directory);
      expect(report['metrics']['frameCount'], 1);
      expect(report['capture']['status'], 'partial');
      expect(report['capture']['invalidEvents'], 1);
    });

    test('strips route payloads and safely embeds malicious labels', () async {
      final report = buildReport(
        manifest(),
        [sample(0)],
        [
          {
            'kind': 'navigation',
            'receivedAt': '2026-10-09',
            'routeName':
                '/details</script><script>alert(1)</script>?secret=abc',
            'arguments': {'password': 'do-not-export'},
          },
        ],
      );
      await writeReports(directory, report);
      final html = await File('${directory.path}/report.html').readAsString();
      expect(html, isNot(contains('</script><script>alert(1)')));
      expect(html, isNot(contains('do-not-export')));
      expect(html, isNot(contains('secret=abc')));
      expect(report['navigation'][0]['attribution'], 'approximate');
      expect(html, contains(r'\u003c/script\u003e'));
      expect(html, isNot(contains('https://')));
    });

    test(
      'regeneration uses saved comparison rather than mutable external baseline',
      () async {
        final source = manifest(
          gates: {
            'enabled': true,
            'baseline': '/nonexistent.json',
            'regressionPercent': 10,
          },
        );
        source['comparison'] = {
          'status': 'pass',
          'reasons': <String>[],
          'metrics': <String, dynamic>{},
        };
        await writeSource(source, [sample(0).toJson()]);
        final report = await regenerateReport(directory);
        expect(report['budget']['status'], 'pass');
      },
    );
  });
}
