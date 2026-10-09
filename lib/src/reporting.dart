import 'dart:convert';
import 'dart:io';

import 'model.dart';
import 'report_template.dart';

const _maximumReportFrames = 200000;

/// Rebuildable, deterministic summaries. No measurements are inferred from logs.
JsonMap buildReport(
  JsonMap manifest,
  Iterable<FrameSample> frames,
  List<JsonMap> navigation,
) {
  final report = jsonDecode(jsonEncode(manifest)) as JsonMap;
  final capture = report['capture'] as JsonMap? ?? <String, dynamic>{};
  report['capture'] = capture;
  final unique = <String, FrameSample>{};
  var overflow = false;
  for (final frame in frames) {
    if (unique.length >= _maximumReportFrames &&
        !unique.containsKey(frame.identity)) {
      overflow = true;
      continue;
    }
    unique.putIfAbsent(frame.identity, () => frame);
  }
  final ordered = unique.values.toList()
    ..sort((a, b) {
      var result = a.segment.compareTo(b.segment);
      if (result == 0) result = a.isolate.compareTo(b.isolate);
      if (result == 0) result = a.startTimeMicros.compareTo(b.startTimeMicros);
      return result == 0 ? a.number.compareTo(b.number) : result;
    });
  if (overflow) {
    capture['status'] = 'partial';
    capture['warnings'] = [
      ...?capture['warnings'] as List?,
      'Report capped at $_maximumReportFrames unique frames.',
    ];
  }
  final environment = report['environment'] as JsonMap? ?? {};
  final hz = _positiveNumber(environment['refreshRateHz']);
  final budgetMs = hz == null ? null : 1000 / hz;
  final build = ordered.map((f) => f.buildMicros / 1000).toList();
  final raster = ordered.map((f) => f.rasterMicros / 1000).toList();
  final overBudget = budgetMs == null
      ? null
      : ordered
            .where(
              (f) =>
                  f.buildMicros / 1000 > budgetMs ||
                  f.rasterMicros / 1000 > budgetMs,
            )
            .length;
  final intervals = <double>[];
  for (var i = 1; i < ordered.length; i++) {
    final current = ordered[i];
    final previous = ordered[i - 1];
    final delta = current.vsyncStartMicros - previous.vsyncStartMicros;
    if (current.segment == previous.segment &&
        current.isolate == previous.isolate &&
        delta > 0) {
      intervals.add(delta / 1000);
    }
  }
  final cadence = _percentiles(intervals);
  final captureStart = DateTime.tryParse('${capture['startedAt']}');
  final captureEnd = DateTime.tryParse('${capture['finishedAt']}');
  final duration = captureStart != null && captureEnd != null
      ? captureEnd.difference(captureStart).inMicroseconds / 1000
      : null;
  final metrics = <String, dynamic>{
    'frameCount': ordered.length,
    'captureDurationMs': duration != null && duration >= 0 ? duration : null,
    'buildMs': _percentiles(build),
    'rasterMs': _percentiles(raster),
    'budgetMs': budgetMs,
    'overBudgetCount': overBudget,
    'overBudgetPercent': overBudget == null || ordered.isEmpty
        ? null
        : overBudget * 100 / ordered.length,
    'cadence': {
      'intervalCount': intervals.length,
      'medianIntervalMs': cadence['p50'],
      'p95IntervalMs': cadence['p95'],
      'medianCadenceHz': cadence['p50'] == null
          ? null
          : 1000 / (cadence['p50'] as num),
      'description':
          'Observed vsync intervals include idle time. '
          'Cadence is not display presentation FPS; idle time is not jank.',
    },
  };
  report['schemaVersion'] = manifest['schemaVersion'] ?? 1;
  report['metrics'] = metrics;
  report['budget'] = _evaluateBudget(report, metrics);
  report['frames'] = ordered.map((f) => f.toJson()).toList();
  // Deliberately exclude route arguments and unknown extension-event data.
  report['navigation'] = navigation
      .map(
        (event) => <String, dynamic>{
          'kind': 'navigation',
          if (event['receivedAt'] is String) 'receivedAt': event['receivedAt'],
          if (event['routeName'] is String)
            'routeName': sanitizeRouteName(event['routeName'] as String),
          'attribution': 'approximate',
        },
      )
      .toList();
  return report;
}

/// Removes URL query/fragment payloads. App-defined path segments may still
/// contain identifiers, so route naming is part of the user's privacy review.
String sanitizeRouteName(String route) => route.split(RegExp(r'[?#]')).first;

double? _positiveNumber(dynamic value) =>
    value is num && value.isFinite && value > 0 ? value.toDouble() : null;

JsonMap _percentiles(List<double> values) {
  values.sort();
  double? percentile(double fraction) =>
      values.isEmpty ? null : values[(values.length * fraction).ceil() - 1];
  return {
    'p50': percentile(.5),
    'p90': percentile(.9),
    'p95': percentile(.95),
    'p99': percentile(.99),
    'max': values.isEmpty ? null : values.last,
  };
}

JsonMap _evaluateBudget(JsonMap report, JsonMap metrics) {
  final gates = report['gates'] as JsonMap? ?? {};
  if (gates['enabled'] != true) {
    return {'status': 'disabled', 'reasons': <String>[]};
  }
  final reasons = <String>[];
  final automation = (report['automation'] as JsonMap?)?['status'];
  if (automation != 'passed' && automation != 'not_applicable') {
    reasons.add(
      'Performance gates require successful automation or an explicit attach-only capture.',
    );
  }
  if ((report['environment'] as JsonMap?)?['buildMode'] != 'profile') {
    reasons.add('Performance gates require a verified profile build.');
  }
  if ((report['capture'] as JsonMap?)?['status'] != 'complete') {
    reasons.add('Performance gates require a complete capture.');
  }
  if (metrics['frameCount'] == 0) reasons.add('No frames were captured.');
  if (gates['overBudgetPercent'] != null && metrics['budgetMs'] == null) {
    reasons.add('A refresh-rate budget is required for over-budget limits.');
  }
  final checks = <JsonMap>[];
  void check(String name, dynamic actual, dynamic limit) {
    if (limit == null) return;
    if (limit is! num || !limit.isFinite || limit < 0) {
      reasons.add('Invalid $name limit.');
      return;
    }
    checks.add({
      'metric': name,
      'actual': actual,
      'limit': limit,
      'status': actual is num
          ? (actual <= limit ? 'pass' : 'fail')
          : 'inconclusive',
    });
  }

  check(
    'buildP95Ms',
    (metrics['buildMs'] as JsonMap)['p95'],
    gates['buildP95Ms'],
  );
  check(
    'rasterP95Ms',
    (metrics['rasterMs'] as JsonMap)['p95'],
    gates['rasterP95Ms'],
  );
  check(
    'overBudgetPercent',
    metrics['overBudgetPercent'],
    gates['overBudgetPercent'],
  );
  if (checks.isEmpty && gates['baseline'] == null) {
    reasons.add('Gates are enabled but no limits or baseline are configured.');
  }
  if (gates['baseline'] != null) {
    reasons.add('Baseline comparison has not been evaluated.');
  }
  if (reasons.isNotEmpty) {
    return {'status': 'inconclusive', 'reasons': reasons, 'checks': checks};
  }
  final failed = checks.where((check) => check['status'] == 'fail').toList();
  return {
    'status': failed.isEmpty ? 'pass' : 'fail',
    'reasons': failed
        .map((check) => '${check['metric']} exceeds its configured limit.')
        .toList(),
    'checks': checks,
  };
}

/// Comparison is deliberately strict: unknown or mismatched environments cannot
/// produce a passing gate, even if the numerical differences look favorable.
JsonMap compareReports(
  JsonMap baseline,
  JsonMap candidate, {
  double? regressionPercent,
}) {
  final unsupported = [
    if (baseline['schemaVersion'] != 1)
      'Unsupported baseline schema version: ${baseline['schemaVersion']}. Expected 1.',
    if (candidate['schemaVersion'] != 1)
      'Unsupported candidate schema version: ${candidate['schemaVersion']}. Expected 1.',
  ];
  if (unsupported.isNotEmpty) {
    return {
      'schemaVersion': 1,
      'baselineId': baseline['id'],
      'candidateId': candidate['id'],
      'compatible': false,
      'status': 'inconclusive',
      'reasons': unsupported,
      'regressionPercent': regressionPercent,
      'metrics': <String, dynamic>{},
    };
  }
  final allowed = regressionPercent;
  final reasons = <String>[];
  final a = baseline['environment'] as JsonMap? ?? {};
  final b = candidate['environment'] as JsonMap? ?? {};
  if (allowed != null && (!allowed.isFinite || allowed < 0)) {
    reasons.add('Invalid regression threshold.');
  }
  for (final field in ['id', 'workload']) {
    if (a[field] is! String ||
        (a[field] as String).trim().isEmpty ||
        b[field] is! String ||
        (b[field] as String).trim().isEmpty) {
      reasons.add('Both runs need an explicit $field identity.');
    } else if (a[field] != b[field]) {
      reasons.add('Environment $field differs between runs.');
    }
  }
  for (final entry in [('baseline', baseline), ('candidate', candidate)]) {
    final env = entry.$2['environment'] as JsonMap? ?? {};
    final automation = (entry.$2['automation'] as JsonMap?)?['status'];
    if (automation != 'passed' && automation != 'not_applicable') {
      reasons.add('${entry.$1} automation did not complete successfully.');
    }
    if (env['buildMode'] != 'profile') {
      reasons.add('${entry.$1} is not a verified profile build.');
    }
    if (env['physical'] != true) {
      reasons.add('${entry.$1} is not identified as a physical device.');
    }
    if ((entry.$2['capture'] as JsonMap?)?['status'] != 'complete') {
      reasons.add('${entry.$1} capture is incomplete.');
    }
    if (((entry.$2['metrics'] as JsonMap?)?['frameCount'] as num? ?? 0) <= 0) {
      reasons.add('${entry.$1} has no frames.');
    }
  }
  final baselineAutomation = (baseline['automation'] as JsonMap?)?['status'];
  final candidateAutomation = (candidate['automation'] as JsonMap?)?['status'];
  if (baselineAutomation != candidateAutomation) {
    reasons.add('Automation and attach-only captures cannot be compared.');
  }
  final ahz = _positiveNumber(a['refreshRateHz']);
  final bhz = _positiveNumber(b['refreshRateHz']);
  if (ahz == null ||
      bhz == null ||
      (ahz - bhz).abs() > .01 ||
      a['refreshRateSource'] == null ||
      a['refreshRateSource'] != b['refreshRateSource']) {
    reasons.add('Refresh-rate budget definitions are unknown or different.');
  }
  for (final field in ['model', 'osVersion']) {
    if (a[field] != b[field]) {
      reasons.add('Device $field differs between runs.');
    }
  }
  if (a['os'] is String && b['os'] is String && a['os'] != b['os']) {
    reasons.add('Operating system differs between runs.');
  }
  final differences = <String, dynamic>{};
  final am = baseline['metrics'] as JsonMap? ?? {};
  final bm = candidate['metrics'] as JsonMap? ?? {};
  for (final phase in ['buildMs', 'rasterMs']) {
    final before = (am[phase] as JsonMap?)?['p95'];
    final after = (bm[phase] as JsonMap?)?['p95'];
    double? change;
    if (before is num && after is num && before.isFinite && after.isFinite) {
      if (before > 0) change = (after - before) * 100 / before;
      if (before == 0 && after == 0) change = 0;
    }
    if (change == null) reasons.add('Cannot calculate $phase p95 regression.');
    differences[phase] = {
      'baselineP95': before,
      'candidateP95': after,
      'changePercent': change,
      'status': change == null
          ? 'inconclusive'
          : allowed == null
          ? 'compared'
          : change > allowed
          ? 'fail'
          : 'pass',
    };
  }
  final compatible = reasons.isEmpty;
  final failed = differences.values.any(
    (dynamic value) => value['status'] == 'fail',
  );
  return {
    'schemaVersion': 1,
    'baselineId': baseline['id'],
    'candidateId': candidate['id'],
    'compatible': compatible,
    'status': !compatible
        ? 'inconclusive'
        : allowed == null
        ? 'compared'
        : failed
        ? 'fail'
        : 'pass',
    'reasons': reasons,
    'regressionPercent': allowed,
    'metrics': differences,
  };
}

/// Derived files can be regenerated; the capture manifest and event log remain
/// untouched, so a report-generation failure does not lose the measurements.
Future<void> writeReports(Directory directory, JsonMap report) async {
  await directory.create(recursive: true);
  final canonical = _canonicalJson(report) as JsonMap;
  await _atomicWrite(
    File('${directory.path}/report.json'),
    '${const JsonEncoder.withIndent('  ').convert(canonical)}\n',
  );
  await _atomicWrite(
    File('${directory.path}/summary.md'),
    _markdown(canonical),
  );
  await _atomicWrite(File('${directory.path}/report.html'), _html(canonical));
}

// Finalization adds fields in a different order than loading the manifest.
// Canonical maps make every derived artifact byte-stable across regeneration.
dynamic _canonicalJson(dynamic value) {
  if (value is JsonMap) {
    final keys = value.keys.toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalJson).toList();
  return value;
}

Future<void> _atomicWrite(File file, String content) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(content, flush: true);
  await temporary.rename(file.path);
}

/// Stream the append-only log and recover valid records after an interruption.
Future<JsonMap> regenerateReport(Directory directory) async {
  final manifest =
      jsonDecode(await File('${directory.path}/manifest.json').readAsString())
          as JsonMap;
  if (manifest['schemaVersion'] != 1) {
    throw FormatException(
      'Unsupported manifest schema version: ${manifest['schemaVersion']}. Expected 1.',
    );
  }
  final frames = <FrameSample>[];
  final navigation = <JsonMap>[];
  var invalid = 0;
  var discarded = 0;
  final events = File('${directory.path}/events.jsonl');
  if (await events.exists()) {
    await for (final line
        in events
            .openRead()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final event = jsonDecode(line) as JsonMap;
        if (event['kind'] == 'frame') {
          final frame = FrameSample.fromJson(event);
          if (frames.length < _maximumReportFrames) {
            frames.add(frame);
          } else {
            discarded++;
          }
        } else if (event['kind'] == 'navigation') {
          navigation.add(event);
        }
      } on FormatException {
        invalid++;
      } on TypeError {
        invalid++;
      }
    }
  } else {
    invalid++;
  }
  final interrupted = manifest['finishedAt'] == null;
  if (invalid > 0 || discarded > 0 || interrupted) {
    final capture = manifest['capture'] as JsonMap? ?? <String, dynamic>{};
    manifest['capture'] = capture;
    capture['status'] = frames.isEmpty ? 'unavailable' : 'partial';
    capture['invalidEvents'] =
        (capture['invalidEvents'] as num? ?? 0) + invalid;
    capture['droppedEvents'] =
        (capture['droppedEvents'] as num? ?? 0) + discarded;
    capture['warnings'] = [
      ...?capture['warnings'] as List?,
      if (interrupted)
        'Run manifest was not finalized; recovered capture coverage is incomplete.',
      if (invalid > 0)
        'Recovered log contains $invalid unreadable or missing records.',
      if (discarded > 0) 'Report limit omitted $discarded records.',
    ];
  }
  final report = buildReport(manifest, frames, navigation);
  final baselinePath = (report['gates'] as JsonMap?)?['baseline'];
  if (baselinePath is String) {
    // Regeneration must not change a run's outcome because a mutable external
    // baseline changed. Keep the comparison persisted in the manifest, if any.
    final comparison = manifest['comparison'];
    if (comparison is JsonMap) applyComparison(report, comparison);
  }
  await writeReports(directory, report);
  return report;
}

/// Merge a comparison while preserving failures and capture eligibility checks.
void applyComparison(JsonMap report, JsonMap comparison) {
  report['comparison'] = comparison;
  final budget = report['budget'] as JsonMap;
  if (budget['status'] == 'disabled') return;
  final checks = budget['checks'] as List? ?? [];
  final failureReasons = checks
      .where((dynamic item) => item['status'] == 'fail')
      .map((dynamic item) => '${item['metric']} exceeds its configured limit.')
      .toList();
  final reasons = (budget['reasons'] as List? ?? [])
      .where(
        (reason) =>
            reason != 'Baseline comparison has not been evaluated.' &&
            !failureReasons.contains(reason),
      )
      .toList();
  final hasFailure =
      checks.any((dynamic item) => item['status'] == 'fail') ||
      comparison['status'] == 'fail';
  if (comparison['status'] == 'inconclusive') {
    reasons.addAll(
      comparison['reasons'] as List? ??
          ['Baseline comparison is inconclusive.'],
    );
  }
  if (comparison['status'] == 'compared') {
    reasons.add('Baseline gating requires an explicit regression threshold.');
  }
  budget['status'] = reasons.isNotEmpty
      ? 'inconclusive'
      : hasFailure
      ? 'fail'
      : 'pass';
  budget['reasons'] = [
    ...reasons,
    ...failureReasons,
    if (comparison['status'] == 'fail')
      'Rendering p95 regression exceeds the configured baseline threshold.',
  ];
}

String _number(dynamic value) =>
    value is num ? value.toStringAsFixed(2) : 'unavailable';
String _md(dynamic value) => '$value'
    .replaceAll(RegExp(r'[\r\n|]'), ' ')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _markdown(JsonMap report) {
  final metrics = report['metrics'] as JsonMap;
  final capture = report['capture'] as JsonMap? ?? {};
  final budget = report['budget'] as JsonMap;
  final gaps = capture['gaps'] as List? ?? [];
  final gapLines = <String>[
    for (final gap in gaps.take(20)) '- Capture gap: ${_md(_gapReason(gap))}',
    if (gaps.length > 20)
      '- ${gaps.length - 20} additional capture gaps are listed in report.html.',
  ].join('\n');
  return '''## Runalong performance report

Run: `${_md(report['id'])}`

| Result | Status |
| --- | --- |
| Automation | ${_md((report['automation'] as JsonMap?)?['status'] ?? 'not run')} |
| Capture | ${_md(capture['status'] ?? 'unavailable')} |
| Budget | ${_md(budget['status'])} |

${metrics['frameCount']} frames · Frame budget: ${_number(metrics['budgetMs'])} ms

| Rendering phase | p50 | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Build (ms) | ${_number(metrics['buildMs']['p50'])} | ${_number(metrics['buildMs']['p95'])} | ${_number(metrics['buildMs']['p99'])} | ${_number(metrics['buildMs']['max'])} |
| Raster (ms) | ${_number(metrics['rasterMs']['p50'])} | ${_number(metrics['rasterMs']['p95'])} | ${_number(metrics['rasterMs']['p99'])} | ${_number(metrics['rasterMs']['max'])} |

Over-budget frames: ${metrics['overBudgetCount'] ?? 'unavailable'} (${_number(metrics['overBudgetPercent'])}%). Build and raster are evaluated separately.

${(budget['reasons'] as List? ?? []).map((reason) => '- ${_md(reason)}').join('\n')}
${(capture['warnings'] as List? ?? []).map((reason) => '- ${_md(reason)}').join('\n')}
$gapLines

Route attribution is approximate. Frame cadence is not display presentation FPS. Open `report.html` for the interactive timeline and coverage details.
''';
}

String _gapReason(dynamic gap) {
  final reason = gap is Map ? gap['reason'] : gap;
  final text = reason is String ? reason : 'Capture interval unavailable.';
  final runes = text.runes.take(401).toList();
  return runes.length > 400
      ? '${String.fromCharCodes(runes.take(400))}…'
      : text;
}

String _html(JsonMap report) {
  final data = jsonEncode(report)
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('&', r'\u0026')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
  return reportHtmlTemplate.replaceFirst('RUNALONG_JSON_PAYLOAD', data);
}
