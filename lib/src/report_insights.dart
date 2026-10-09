import 'model.dart';

// These are grouping limits, not measurements of user activity or jank.
const _maximumGapMicros = 250000;
const _maximumWindowMicros = 1000000;
const _maximumFindings = 5;

/// Describes measured frame phases without inferring screen, widget, or cause.
/// All strings are plain text; renderers must escape them for their destination.
JsonMap buildInsights(JsonMap report) {
  final frames =
      (report['frames'] as List? ?? const [])
          .cast<JsonMap>()
          .map(FrameSample.fromJson)
          .toList()
        ..sort(_compareFrames);
  final environment = report['environment'] as JsonMap? ?? {};
  final capture = report['capture'] as JsonMap? ?? {};
  final automation = report['automation'] as JsonMap? ?? {};
  final rawBudget = (report['metrics'] as JsonMap?)?['budgetMs'];
  final budget = rawBudget is num && rawBudget.isFinite && rawBudget > 0
      ? rawBudget.toDouble()
      : null;
  final diagnostic =
      environment['buildMode'] != 'profile' ||
      capture['status'] != 'complete' ||
      !['passed', 'not_applicable'].contains(automation['status']);
  final limitations = <String>[
    if (environment['buildMode'] == 'debug')
      'Debug build: timings are diagnostic and are not representative of profile or release performance.'
    else if (environment['buildMode'] != 'profile')
      'A profile build was not verified; treat these timings as diagnostic.',
    if (capture['status'] != 'complete')
      'Capture is incomplete; uncaptured activity cannot be assessed.',
    if ((capture['gaps'] as List? ?? const []).isNotEmpty)
      'Capture gaps were recorded; some activity may be missing.',
    if ((capture['droppedEvents'] as num? ?? 0) > 0 ||
        (capture['invalidEvents'] as num? ?? 0) > 0)
      'Some frame events were dropped or invalid; findings cover retained samples only.',
    if (!['passed', 'not_applicable'].contains(automation['status']))
      'Automation did not complete successfully; the intended workload may be incomplete.',
    if (budget == null)
      'Refresh-rate budget is unknown; captured durations cannot establish a budget pass or failure.',
    'Frame timings do not identify the responsible screen, widget, action, or root cause, and do not measure display FPS.',
    'Times are frame-start offsets from the first captured frame in each segment and isolate; separate clocks are not joined.',
    if (budget != null && frames.isNotEmpty)
      'Groups span at most 1 second, allow at most 2 intervening under-budget frames, and split at gaps over 250 ms. Findings are ranked by total measured time above budget. Gaps and idle time are not counted as jank.',
  ];
  if (frames.isEmpty) {
    return {
      'version': 1,
      'headline': 'No frame evidence was captured.',
      'summary':
          'No rendering conclusion is available. Verify attachment to '
          'the Flutter process and repeat the workload while capture is active.',
      'limitations': limitations,
      'findings': <JsonMap>[],
    };
  }
  if (budget == null) {
    return {
      'version': 1,
      'headline': 'Set a frame budget to assess this capture.',
      'summary':
          '${frames.length} frames were captured, but the frame budget is unknown. '
          'Worst measured build: ${_ms(_worst(frames, 'build'))} ms; '
          'worst raster: ${_ms(_worst(frames, 'raster'))} ms. '
          'Set or verify the target display refresh rate and rebuild the report '
          'to locate budget exceedances. No performance pass is established.',
      'limitations': limitations,
      'findings': <JsonMap>[],
    };
  }

  final groups = <(String, String), List<FrameSample>>{};
  for (final frame in frames) {
    groups.putIfAbsent((frame.segment, frame.isolate), () => []).add(frame);
  }
  final windows = <_Window>[];
  for (final group in groups.values) {
    for (final phase in ['build', 'raster']) {
      windows.addAll(_windows(group, phase, budget));
    }
  }
  windows.sort((a, b) {
    var order = b.excessMs.compareTo(a.excessMs);
    if (order == 0) order = b.worstMs.compareTo(a.worstMs);
    if (order == 0) order = b.slowCount.compareTo(a.slowCount);
    if (order == 0) order = _compareFrames(a.frames.first, b.frames.first);
    return order == 0 ? a.phase.compareTo(b.phase) : order;
  });
  final navigation =
      (report['navigation'] as List? ?? const [])
          .cast<JsonMap>()
          .map(_Navigation.fromJson)
          .where((event) => event.receivedAt != null)
          .toList()
        ..sort((a, b) => a.receivedAt!.compareTo(b.receivedAt!));
  final isolateCount = frames.map((frame) => frame.isolate).toSet().length;
  final findings = <JsonMap>[];
  for (final window in windows.take(_maximumFindings)) {
    final first = window.frames.first;
    final last = window.frames.last;
    final group = groups[(first.segment, first.isolate)]!;
    final segmentCount = groups.keys
        .where((key) => key.$2 == first.isolate)
        .length;
    final route = _routeHint(
      window,
      group,
      navigation,
      isolateCount,
      segmentCount,
    );
    final startMs =
        (first.startTimeMicros - group.first.startTimeMicros) / 1000;
    final moment = '${(startMs / 1000).toStringAsFixed(2)} s';
    final title = window.slowCount > 1
        ? 'Repeated slow ${window.phase == 'build' ? 'UI' : 'raster'} work around $moment'
        : 'A ${window.phase == 'build' ? 'UI build' : 'raster'} spike at $moment';
    findings.add({
      'id': 'finding-${findings.length + 1}',
      'phase': window.phase,
      'title': title,
      'observation':
          '${window.slowCount} of ${window.frames.length} captured '
          '${window.frames.length == 1 ? 'frame' : 'frames'} in this group '
          'exceeded the ${_ms(budget)} ms ${window.phase} budget. '
          'Worst ${window.phase}: ${_ms(window.worstMs)} ms '
          '(${(window.worstMs / budget).toStringAsFixed(2)}× budget).',
      'interpretation': window.phase == 'build'
          ? 'Measured build work exceeded one refresh interval. This points '
                'to build-side work to investigate; timings alone do not identify '
                'the responsible widget or explain why it was expensive.'
          : 'Measured raster work exceeded one refresh interval. This points '
                'to raster-side work to investigate; timings alone do not '
                'identify the responsible paint operation or GPU cause.',
      'nextStep':
          '${diagnostic ? 'Repeat this workload in a complete profile '
                    'capture on the target device, then' : 'Reproduce the interaction '
                    'around this frame range, then'} '
          '${window.phase == 'build' ? 'inspect CPU, build, and layout work '
                    'in Flutter DevTools.' : 'inspect raster and paint work in Flutter '
                    'DevTools, including costly effects and image rendering.'}',
      'severity': 'warning',
      'evidence': {
        'segment': first.segment,
        'isolate': first.isolate,
        'firstFrame': first.number,
        'lastFrame': last.number,
        'startMs': startMs,
        'endMs': (last.startTimeMicros - group.first.startTimeMicros) / 1000,
        'frameCount': window.frames.length,
        'slowFrameCount': window.slowCount,
        'worstBuildMs': _worst(window.frames, 'build'),
        'worstRasterMs': _worst(window.frames, 'raster'),
        'budgetMs': budget,
      },
      'routeHint': ?route,
      'attribution': route == null
          ? 'Screen name unavailable: no unambiguous preceding named route '
                'receipt covers this group. Locate it by segment, isolate, and '
                'frame range; timings do not establish a screen or action.'
          : 'Approximate route hint from preceding navigation receipts. '
                'Frame delivery may be batched; receipt order is not exact '
                'engine timing, and proximity does not establish cause.',
    });
  }
  final buildCount = frames.where((f) => f.buildMicros / 1000 > budget).length;
  final rasterCount = frames
      .where((f) => f.rasterMicros / 1000 > budget)
      .length;
  final eitherCount = frames
      .where(
        (f) => f.buildMicros / 1000 > budget || f.rasterMicros / 1000 > budget,
      )
      .length;
  final String headline;
  final String measuredSummary;
  if (eitherCount == 0) {
    headline = 'Captured UI work stayed within the frame budget.';
    measuredSummary =
        'Build and raster work stayed within ${_ms(budget)} ms in all '
        '${frames.length} captured frames. This covers the retained samples '
        'only and does not establish a screen-level or end-to-end performance pass.';
  } else if (buildCount == 0 || rasterCount == 0) {
    final phase = buildCount > 0 ? 'build' : 'raster';
    final work = buildCount > 0 ? 'UI build' : 'raster';
    final otherWork = buildCount > 0 ? 'Raster' : 'UI build';
    headline = 'Start by investigating $work work.';
    measuredSummary =
        '$eitherCount of ${frames.length} captured frames exceeded the '
        '${_ms(budget)} ms $work budget, with a worst $phase of '
        '${_ms(_worst(frames, phase))} ms. $otherWork work stayed within '
        'budget in the captured samples.';
  } else {
    headline = 'Investigate both UI build and raster work.';
    measuredSummary =
        '$eitherCount of ${frames.length} captured frames exceeded '
        'the ${_ms(budget)} ms budget: $buildCount during UI build and '
        '$rasterCount during raster, checked separately. Worst build: '
        '${_ms(_worst(frames, 'build'))} ms; worst raster: '
        '${_ms(_worst(frames, 'raster'))} ms.';
  }
  return {
    'version': 1,
    'headline': headline,
    'summary':
        '${diagnostic ? 'Treat this as a diagnostic capture. ' : ''}'
        '$measuredSummary'
        '${windows.isEmpty ? '' : ' Start with the ${findings.length} moments '
                  'below, selected from ${windows.length} found and ordered '
                  'by measured time over budget.'}',
    'limitations': limitations,
    'findings': findings,
  };
}

int _compareFrames(FrameSample a, FrameSample b) {
  var result = a.segment.compareTo(b.segment);
  if (result == 0) result = a.isolate.compareTo(b.isolate);
  if (result == 0) result = a.startTimeMicros.compareTo(b.startTimeMicros);
  return result == 0 ? a.number.compareTo(b.number) : result;
}

double _duration(FrameSample frame, String phase) =>
    (phase == 'build' ? frame.buildMicros : frame.rasterMicros) / 1000;

double _worst(List<FrameSample> frames, String phase) => frames
    .map((frame) => _duration(frame, phase))
    .reduce((a, b) => a > b ? a : b);

String _ms(double value) => value.toStringAsFixed(2);

List<_Window> _windows(List<FrameSample> frames, String phase, double budget) {
  final result = <_Window>[];
  int? firstSlow;
  int? lastSlow;
  void finish() {
    if (firstSlow != null) {
      result.add(
        _Window(frames.sublist(firstSlow!, lastSlow! + 1), phase, budget),
      );
    }
    firstSlow = null;
    lastSlow = null;
  }

  for (var i = 0; i < frames.length; i++) {
    if (firstSlow != null &&
        (frames[i].startTimeMicros - frames[i - 1].startTimeMicros >
                _maximumGapMicros ||
            frames[i].startTimeMicros - frames[firstSlow!].startTimeMicros >
                _maximumWindowMicros ||
            i - lastSlow! > 3)) {
      finish();
    }
    if (_duration(frames[i], phase) > budget) {
      firstSlow ??= i;
      lastSlow = i;
    }
  }
  finish();
  return result;
}

final class _Window {
  _Window(this.frames, this.phase, this.budget);
  final List<FrameSample> frames;
  final String phase;
  final double budget;
  int get slowCount => frames.where((f) => _duration(f, phase) > budget).length;
  double get worstMs => _worst(frames, phase);
  double get excessMs => frames.fold(0, (sum, frame) {
    final excess = _duration(frame, phase) - budget;
    return sum + (excess > 0 ? excess : 0);
  });
}

final class _Navigation {
  _Navigation.fromJson(JsonMap value)
    : receivedAt = DateTime.tryParse('${value['receivedAt']}'),
      isolate = value['isolate'] as String?,
      route =
          value['routeName'] is String &&
              (value['routeName'] as String).trim().isNotEmpty
          ? value['routeName'] as String
          : null;
  final DateTime? receivedAt;
  final String? isolate;
  final String? route;
}

String? _routeHint(
  _Window window,
  List<FrameSample> group,
  List<_Navigation> navigation,
  int isolateCount,
  int segmentCount,
) {
  final receipts = window.frames
      .map((frame) => DateTime.tryParse(frame.receivedAt))
      .toList();
  if (receipts.any((time) => time == null)) return null;
  final times = receipts.cast<DateTime>()..sort();
  // A restarted segment must establish its own route context. Without a host
  // receipt boundary, retaining an earlier route would be speculative.
  final segmentStart = segmentCount > 1
      ? DateTime.tryParse(group.first.receivedAt)
      : null;
  final relevant = navigation
      .where(
        (event) =>
            (event.isolate == null ||
                event.isolate == window.frames.first.isolate) &&
            (segmentStart == null ||
                !event.receivedAt!.isBefore(segmentStart)) &&
            !event.receivedAt!.isAfter(times.last),
      )
      .toList();
  final preceding = relevant.where((e) => !e.receivedAt!.isAfter(times.first));
  if (preceding.isEmpty) return null;
  final latestTime = preceding.last.receivedAt!;
  // Unknown names, mixed routes, and ambiguous cross-isolate events invalidate
  // a hint. Checking all tied receipts also makes event order immaterial.
  final context = relevant.where((e) => !e.receivedAt!.isBefore(latestTime));
  final names = <String>{};
  for (final event in context) {
    if (event.route == null || (event.isolate == null && isolateCount > 1)) {
      return null;
    }
    names.add(event.route!);
  }
  return names.length == 1 ? names.single : null;
}
