import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'model.dart';

/// Joins independently recorded evidence only through explicit clock samples.
/// FrameTiming timestamps are never assumed to share the VM timeline clock.
JsonMap buildJourney(JsonMap report, List<JsonMap> events) {
  final index = report['sourceIndex'] as JsonMap?;
  final sourceNames = <String, List<JsonMap>>{};
  for (final entry
      in (index?['entries'] as List? ?? const []).whereType<JsonMap>()) {
    final name = entry['name'];
    if (name is String) {
      sourceNames.putIfAbsent(name, () => []).add(entry);
      sourceNames
          .putIfAbsent('${entry['uri']}|${name.split('.').last}', () => [])
          .add(entry);
    }
  }
  final candidateCache = <String, List<JsonMap>>{};
  JsonMap withSources(JsonMap event) {
    final name = '${event['name'] ?? ''}';
    final uri = event['uri'] ?? (event['source'] as JsonMap?)?['uri'];
    final candidates = candidateCache.putIfAbsent('$uri|$name', () {
      final parts = name.split('.');
      final keys = <String>{
        if (uri is String) '$uri|${parts.last}',
        name,
        if (parts.length > 1) parts.sublist(parts.length - 2).join('.'),
        parts.last,
      };
      final matched = <JsonMap>[];
      for (final key in keys) {
        for (final entry in sourceNames[key] ?? const <JsonMap>[]) {
          if (!matched.contains(entry) &&
              (uri == null || entry['uri'] == uri || entry['path'] == uri)) {
            matched.add(entry);
          }
        }
        if (matched.length >= 10) break;
      }
      return matched
          .take(10)
          .map(
            (e) => <String, dynamic>{
              ...e,
              'provenance': 'local_candidate',
              'revisionStatus': index?['revisionStatus'],
            },
          )
          .toList();
    });
    return {
      ...event,
      if (candidates.isNotEmpty) 'sourceCandidates': candidates,
    };
  }

  final clocks = <String, List<JsonMap>>{};
  for (final event in events.where((e) => e['kind'] == 'clock')) {
    if (_number(event['hostMicros']) == null ||
        _number(event['vmMicros']) == null ||
        _number(event['uncertaintyMicros']) == null) {
      continue;
    }
    clocks.putIfAbsent('${event['connection']}', () => []).add(event);
  }
  for (final values in clocks.values) {
    values.sort(
      (a, b) => (a['vmMicros'] as num).compareTo(b['vmMicros'] as num),
    );
  }
  final connections = <String, String>{};
  final capture = report['capture'] as JsonMap? ?? {};
  for (final segment
      in (capture['segments'] is List
          ? capture['segments'] as List
          : const [])) {
    if (segment is Map && segment['connection'] != null) {
      connections['${segment['id']}'] = '${segment['connection']}';
    }
  }
  String? connection(JsonMap event) {
    if (event['connection'] != null) return '${event['connection']}';
    return connections['${event['segment']}'];
  }

  JsonMap? mapped(JsonMap event, num? vm) {
    if (vm == null) return null;
    final anchors = clocks[connection(event)];
    if (anchors == null || anchors.isEmpty) return null;
    final nearest = anchors.reduce(
      (a, b) =>
          ((a['vmMicros'] as num) - vm).abs() <=
              ((b['vmMicros'] as num) - vm).abs()
          ? a
          : b,
    );
    return {
      'micros':
          vm + (nearest['hostMicros'] as num) - (nearest['vmMicros'] as num),
      'uncertaintyMicros': nearest['uncertaintyMicros'],
      'connection': connection(event),
    };
  }

  JsonMap? point(JsonMap event, [String field = 'vmMicros']) {
    if (event['kind'] == 'context' && field == 'vmMicros') {
      return mapped(event, _number(event[field]));
    }
    if (event['hostMicros'] is num && field == 'vmMicros') {
      return {
        'micros': event['hostMicros'],
        'uncertaintyMicros': event['uncertaintyMicros'],
        'connection': connection(event),
      };
    }
    return mapped(event, _number(event[field]));
  }

  JsonMap? span(JsonMap event) {
    final a = point(event, 'vmStartMicros');
    final b = point(event, 'vmEndMicros');
    if (a == null || b == null || (b['micros'] as num) < (a['micros'] as num)) {
      return null;
    }
    return {
      'startMicros': a['micros'],
      'endMicros': b['micros'],
      'uncertaintyMicros': _max(
        a['uncertaintyMicros'] as num,
        b['uncertaintyMicros'] as num,
      ),
      'connection': connection(event),
    };
  }

  final frameTimes = <String, JsonMap>{};
  final framePhases = <String, Map<String, JsonMap>>{};
  for (final event in events.where((e) => e['kind'] == 'frame_timeline')) {
    final time = span(event);
    if (time == null) continue;
    final key = _frameKey(event);
    if (event['scope'] == null) {
      frameTimes[key] = time; // Earlier schema-2 complete-envelope fixtures.
    } else {
      framePhases.putIfAbsent(key, () => {})['${event['scope']}'] = time;
    }
  }
  for (final entry in framePhases.entries) {
    final build = entry.value['build'], raster = entry.value['raster'];
    // Do not attribute raster work using only the UI thread's envelope.
    if (build == null || raster == null) continue;
    frameTimes[entry.key] = {
      ...build,
      'startMicros': _min(
        build['startMicros'] as num,
        raster['startMicros'] as num,
      ),
      'endMicros': _max(build['endMicros'] as num, raster['endMicros'] as num),
      'uncertaintyMicros': _max(
        build['uncertaintyMicros'] as num,
        raster['uncertaintyMicros'] as num,
      ),
    };
  }
  final alignedFrames = <JsonMap>[];
  final unalignedFrames = <JsonMap>[];
  for (final frame in (report['frames'] as List? ?? const []).cast<JsonMap>()) {
    final time = frameTimes[_frameKey(frame)];
    if (time == null) {
      unalignedFrames.add(frame);
    } else {
      alignedFrames.add({...frame, ...time});
    }
  }
  alignedFrames.sort(_byStart);
  final memory = <JsonMap>[],
      traces = <JsonMap>[],
      cpu = <JsonMap>[],
      gc = <JsonMap>[];
  final rebuilds = <JsonMap>[];
  for (final event in events) {
    if (event['kind'] == 'memory') {
      final time = point(event);
      if (time == null) continue;
      final groups = <String, JsonMap>{};
      for (final group in (event['groups'] as List? ?? const [])) {
        if (group is JsonMap && group['id'] != null) {
          groups.putIfAbsent('${group['id']}', () => group);
        }
      }
      num? total(String key) =>
          groups.isEmpty || groups.values.any((g) => _number(g[key]) == null)
          ? null
          : groups.values.fold<num>(0, (n, g) => n + (g[key] as num));
      memory.add({
        'micros': time['micros'],
        'uncertaintyMicros': time['uncertaintyMicros'],
        'connection': connection(event),
        'heapUsage': total('heapUsage'),
        'heapCapacity': total('heapCapacity'),
        'externalUsage': total('externalUsage'),
        'rssBytes': _number(event['rssBytes']),
        'groupCount': groups.length,
        'groups': groups.values.toList(),
      });
    } else if (event['kind'] == 'trace') {
      final time = span(event);
      if (time != null) traces.add({...withSources(event), ...time});
    } else if (event['kind'] == 'cpu') {
      final time = span(event);
      if (time == null) continue;
      final functions = (event['functions'] as List? ?? const [])
          .whereType<JsonMap>()
          .map(
            (f) => <String, dynamic>{
              ...withSources(f),
              'key': jsonEncode([f['name'], f['uri'], f['line'], f['column']]),
            },
          )
          .toList();
      final samples = <JsonMap>[];
      for (final sample in (event['samples'] as List? ?? const [])) {
        if (sample is! JsonMap) continue;
        final t = mapped(event, _number(sample['vmMicros']));
        if (t != null) {
          samples.add({
            ...sample,
            'identity': sha256
                .convert(
                  utf8.encode(
                    jsonEncode([
                      event['segment'],
                      event['isolate'],
                      sample['vmMicros'],
                      sample['threadId'],
                      (sample['stack'] as List? ?? const [])
                          .map(
                            (dynamic i) =>
                                i is int && i >= 0 && i < functions.length
                                ? functions[i]['key']
                                : null,
                          )
                          .toList(),
                    ]),
                  ),
                )
                .toString(),
            'micros': t['micros'],
            'uncertaintyMicros': t['uncertaintyMicros'],
          });
        }
      }
      cpu.add({...event, ...time, 'samples': samples, 'functions': functions});
    } else if (event['kind'] == 'gc') {
      final time = point(event);
      if (time != null) {
        gc.add({
          ...event,
          'micros': time['micros'],
          'uncertaintyMicros': time['uncertaintyMicros'],
        });
      }
    } else if (event['kind'] == 'widget_rebuild') {
      final time = frameTimes[_frameKey(event)];
      if (time != null) {
        rebuilds.add({
          ...event,
          ...time,
          'widgets': (event['widgets'] as List? ?? const [])
              .whereType<JsonMap>()
              .map(withSources)
              .toList(),
        });
      }
    }
  }
  memory.sort((a, b) => (a['micros'] as num).compareTo(b['micros'] as num));
  final starts = <String, JsonMap>{}, ends = <String, JsonMap>{};
  String contextKey(JsonMap event) => event['kind'] == 'runner'
      ? 'runner:${event['id']}'
      : 'context:${event['segment']}:${event['isolate']}:${event['id']}';
  final boundaryEvents =
      events
          .where((e) => e['kind'] == 'context' || e['kind'] == 'runner')
          .toList()
        ..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  for (final event in boundaryEvents) {
    final name = '${event['event']}';
    if (name.endsWith('_start')) {
      starts.putIfAbsent(contextKey(event), () => event);
    }
    if (name.endsWith('_end')) ends.putIfAbsent(contextKey(event), () => event);
  }
  final items = <JsonMap>[];
  final lastObserved = <String, num>{};
  for (final event in events) {
    final time = event['vmEndMicros'] is num
        ? point(event, 'vmEndMicros')
        : point(event);
    final at = _number(time?['micros']);
    final key = connection(event);
    if (at != null && key != null && event['kind'] != 'runner') {
      lastObserved[key] = _max(lastObserved[key] ?? at, at);
    }
  }
  for (final entry in starts.entries) {
    final start = entry.value, end = ends[entry.key];
    final a = point(start), b = end == null ? null : point(end);
    final name = '${start['event']}'.replaceFirst('_start', '');
    final parent =
        start['parentId'] ?? (name == 'operation' ? start['screenId'] : null);
    final aligned =
        a != null && b != null && (b['micros'] as num) >= (a['micros'] as num);
    final valid =
        aligned &&
        a['uncertaintyMicros'] is num &&
        b['uncertaintyMicros'] is num;
    items.add({
      'id': entry.key,
      'eventId': start['id'],
      'stableId': start['stableId'],
      'type': name,
      'label': start['label'] ?? start['stableId'] ?? 'Unnamed $name',
      'segment': start['segment'],
      'isolate': start['isolate'],
      'connection': connection(start),
      if (parent != null) 'parentId': contextKey({...start, 'id': parent}),
      'startMicros': a?['micros'],
      'endMicros': aligned ? b['micros'] : null,
      if (!aligned &&
          a != null &&
          lastObserved[connection(start)] != null &&
          lastObserved[connection(start)]! >= (a['micros'] as num))
        'observedEndMicros': lastObserved[connection(start)],
      'uncertaintyMicros': valid
          ? _max(a['uncertaintyMicros'] as num, b['uncertaintyMicros'] as num)
          : null,
      'coverage': valid
          ? 'bounded'
          : aligned
          ? 'approximate'
          : 'incomplete',
      'status': end?['status'] ?? 'unfinished',
      'durationMs': aligned
          ? ((b['micros'] as num) - (a['micros'] as num)) / 1000
          : null,
      'attribution': start['kind'] == 'runner'
          ? 'runner event'
          : 'explicit app context',
      if (start['source'] is Map) 'source': start['source'],
      if (!valid)
        'limitation': end == null
            ? 'End event was not captured. Only the observed portion is shown; total operation duration is unknown.'
            : 'Timing uncertainty is unknown; receipt times cannot establish exact action boundaries.',
    });
  }
  items.sort(_byStart);
  for (final item in items.where(
    (i) => i['parentId'] == null && i['type'] == 'screen',
  )) {
    final start = _number(item['startMicros']),
        end = _number(item['endMicros']);
    if (start == null || end == null) continue;
    final parents =
        items
            .where(
              (p) =>
                  ['test', 'step'].contains(p['type']) &&
                  p['startMicros'] is num &&
                  p['endMicros'] is num &&
                  (p['startMicros'] as num) <= start &&
                  (p['endMicros'] as num) >= end,
            )
            .toList()
          ..sort(
            (a, b) => ((a['endMicros'] as num) - (a['startMicros'] as num))
                .compareTo((b['endMicros'] as num) - (b['startMicros'] as num)),
          );
    if (parents.isNotEmpty &&
        (parents.length == 1 ||
            parents[0]['startMicros'] != parents[1]['startMicros'] ||
            parents[0]['endMicros'] != parents[1]['endMicros'])) {
      item['parentId'] = parents.first['id'];
      item['parentAttribution'] = 'temporally contained in runner interval';
    }
  }
  final byId = {for (final item in items) item['id'] as String: item};
  final counts = <String, int>{};
  final visiting = <String>{};
  void identify(JsonMap item) {
    if (item['comparisonKey'] != null) return;
    final id = item['id'] as String;
    if (!visiting.add(id)) {
      item.remove('parentId');
      return;
    }
    final parent = byId[item['parentId']];
    if (parent != null) identify(parent);
    final parentKey = parent?['comparisonKey'] as String? ?? '';
    final stableId = item['stableId'];
    final hierarchy =
        '$parentKey/${item['type']}:${stableId is String && stableId.isNotEmpty ? stableId : "unidentified"}';
    final occurrence = counts.update(
      hierarchy,
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    item.addAll({
      'hierarchyKey': hierarchy,
      'occurrence': occurrence,
      'comparisonKey': '$hierarchy#$occurrence',
      'comparable': stableId is String && stableId.isNotEmpty,
    });
    visiting.remove(id);
  }

  for (final item in items) {
    identify(item);
  }
  // Repeated concurrent operations with the same stable identity have no
  // reliable cross-run occurrence ordering. Keep their evidence, not a match.
  final activeByHierarchy = <String, JsonMap>{};
  for (final item in items) {
    final key = item['hierarchyKey'] as String;
    final start = _number(item['startMicros']);
    if (start == null) continue;
    final previous = activeByHierarchy[key];
    final previousEnd = _number(
      previous?['endMicros'] ?? previous?['observedEndMicros'],
    );
    if (previous != null &&
        (previous['startMicros'] == start ||
            (previousEnd != null && start < previousEnd))) {
      for (final ambiguous in [previous, item]) {
        ambiguous['comparable'] = false;
        ambiguous['comparisonLimitation'] =
            'Concurrent occurrences share the same stable identity; no cross-run match is asserted.';
      }
    }
    final end = _number(item['endMicros'] ?? item['observedEndMicros']);
    if (previous == null ||
        previousEnd == null ||
        (end != null && end > previousEnd)) {
      activeByHierarchy[key] = item;
    }
  }
  final result = <String, dynamic>{
    'version': 1,
    'clock': 'run_monotonic_microseconds',
    'items': items,
    'frames': alignedFrames,
    'memory': memory,
    'cpu': cpu,
    'traces': traces,
    'gc': gc,
    'widgetRebuilds': rebuilds,
    'unalignedFrameCount': unalignedFrames.length,
    'capabilities':
        (capture['telemetry'] as JsonMap?)?['connections'] ?? const <JsonMap>[],
    'limitations': <String>[
      if (unalignedFrames.isNotEmpty)
        '${unalignedFrames.length} frames have no exact VM timeline match and cannot be assigned to a screen or operation.',
      if (items.isEmpty)
        'No explicit test, screen, or operation boundaries were captured. Route names remain approximate hints.',
      'Clock uncertainty is retained. Boundary-overlapping evidence is shown separately and is excluded from attributed frame metrics.',
      'Dart heap is summed once per isolate group at each sample. Process RSS is a separate process-wide measurement; it is never added to Dart heap.',
      'CPU stack samples describe sampled execution, not process CPU utilization or exact function duration.',
      'An operation overlapping slow rendering is context, not proof that it caused the slow frame.',
    ],
  };
  final budget = (report['metrics'] as JsonMap?)?['budgetMs'] as num?;
  for (final item in items) {
    item['metrics'] = summarizeJourneyInterval(result, item, budgetMs: budget);
  }
  return result;
}

/// The same bounded interval is applied to every signal. Uncertainty is not
/// silently converted into exact attribution.
JsonMap summarizeJourneyInterval(
  JsonMap journey,
  JsonMap interval, {
  num? budgetMs,
}) {
  final start = _number(interval['startMicros']),
      end = _number(interval['endMicros'] ?? interval['observedEndMicros']);
  if (start == null || end == null || end < start) {
    return {
      'status': 'unavailable',
      'frameCount': 0,
      'reason': 'Both calibrated boundaries are required.',
    };
  }
  final approximate = _number(interval['uncertaintyMicros']) == null;
  final observed = interval['endMicros'] == null;
  final uncertainty = _number(interval['uncertaintyMicros']) ?? 0;
  final connection = interval['connection'];
  bool same(JsonMap event) =>
      connection == null ||
      event['connection'] == null ||
      '${event['connection']}' == '$connection';
  bool contains(JsonMap event) {
    if (!same(event)) return false;
    final a = _number(event['startMicros'] ?? event['micros']),
        b = _number(event['endMicros'] ?? event['micros']);
    final u = _number(event['uncertaintyMicros']);
    if (u == null) return false;
    return a != null &&
        b != null &&
        a - u >= start + uncertainty &&
        b + u <= end - uncertainty;
  }

  bool overlaps(JsonMap event) {
    if (!same(event)) return false;
    final a = _number(event['startMicros'] ?? event['micros']),
        b = _number(event['endMicros'] ?? event['micros']);
    final u = _number(event['uncertaintyMicros']) ?? 0;
    return a != null &&
        b != null &&
        a - u <= end + uncertainty &&
        b + u >= start - uncertainty;
  }

  List<JsonMap> list(String field) =>
      (journey[field] as List? ?? const []).cast<JsonMap>();
  final frames = list('frames').where(contains).toList();
  final memory = list('memory').where(contains).toList();
  final traces = list('traces').where(overlaps).toList();
  final functionCounts = <String, JsonMap>{};
  var sampleCount = 0;
  final seenSamples = <String>{};
  for (final batch in list('cpu')) {
    if (!same(batch)) continue;
    final functions = batch['functions'] as List? ?? const [];
    for (final sample
        in (batch['samples'] as List? ?? const []).cast<JsonMap>()) {
      if (!contains({...sample, 'connection': batch['connection']})) continue;
      final signature =
          sample['identity'] as String? ??
          jsonEncode([
            batch['segment'],
            batch['isolate'],
            sample['vmMicros'],
            (sample['stack'] as List? ?? const [])
                .map(
                  (dynamic i) => i is int && i >= 0 && i < functions.length
                      ? [
                          functions[i]['name'],
                          functions[i]['uri'],
                          functions[i]['line'],
                          functions[i]['column'],
                        ]
                      : null,
                )
                .toList(),
          ]);
      if (!seenSamples.add(signature)) continue;
      sampleCount++;
      final seen = <int>{};
      for (final index in sample['stack'] as List? ?? const []) {
        if (index is! int ||
            index < 0 ||
            index >= functions.length ||
            !seen.add(index)) {
          continue;
        }
        final function = functions[index];
        if (function is! JsonMap) continue;
        final key =
            function['key'] as String? ??
            jsonEncode([
              function['name'],
              function['uri'],
              function['line'],
              function['column'],
            ]);
        final row = functionCounts.putIfAbsent(
          key,
          () => {...function, 'samples': 0, 'selfSamples': 0},
        );
        row['samples'] = (row['samples'] as int) + 1;
        if (index == (sample['stack'] as List).first) {
          row['selfSamples'] = (row['selfSamples'] as int) + 1;
        }
      }
    }
  }
  final functions = functionCounts.values.toList()
    ..sort((a, b) {
      final self = (b['selfSamples'] as int).compareTo(a['selfSamples'] as int);
      return self != 0
          ? self
          : (b['samples'] as int).compareTo(a['samples'] as int);
    });
  for (final row in functions) {
    row['sampleSharePercent'] = sampleCount == 0
        ? null
        : (row['samples'] as int) * 100 / sampleCount;
    row['selfSharePercent'] = sampleCount == 0
        ? null
        : (row['selfSamples'] as int) * 100 / sampleCount;
  }
  num? peak(String field) {
    final values = memory.map((s) => _number(s[field])).whereType<num>();
    return values.isEmpty ? null : values.reduce(_max);
  }

  num? delta(String field) {
    if (memory.length < 2) return null;
    final first = _number(memory.first[field]),
        last = _number(memory.last[field]);
    return first == null || last == null ? null : last - first;
  }

  final slow = budgetMs == null
      ? null
      : frames
            .where(
              (f) =>
                  (f['buildMicros'] as num) / 1000 > budgetMs ||
                  (f['rasterMicros'] as num) / 1000 > budgetMs,
            )
            .length;
  return {
    'status': observed
        ? 'observed'
        : approximate
        ? 'approximate'
        : 'bounded',
    'durationMs': observed ? null : (end - start) / 1000,
    'observedDurationMs': (end - start) / 1000,
    'attribution': observed || approximate
        ? 'Evidence within an approximate observed window; not exact attribution.'
        : 'calibrated boundaries',
    'frameCount': frames.length,
    'boundaryFrameCount': list(
      'frames',
    ).where((f) => overlaps(f) && !contains(f)).length,
    'buildMs': journeyPercentiles(
      frames.map((f) => (f['buildMicros'] as num) / 1000).toList(),
    ),
    'rasterMs': journeyPercentiles(
      frames.map((f) => (f['rasterMicros'] as num) / 1000).toList(),
    ),
    'overBudgetCount': slow,
    'overBudgetPercent': slow == null || frames.isEmpty
        ? null
        : slow * 100 / frames.length,
    'memory': {
      'sampleCount': memory.length,
      'firstHeapBytes': memory.isEmpty ? null : memory.first['heapUsage'],
      'lastHeapBytes': memory.isEmpty ? null : memory.last['heapUsage'],
      'firstRssBytes': memory.isEmpty ? null : memory.first['rssBytes'],
      'lastRssBytes': memory.isEmpty ? null : memory.last['rssBytes'],
      'peakHeapBytes': peak('heapUsage'),
      'peakExternalBytes': peak('externalUsage'),
      'peakRssBytes': peak('rssBytes'),
      'heapDeltaBytes': delta('heapUsage'),
      'rssDeltaBytes': delta('rssBytes'),
      'scope': 'process snapshots; heap groups counted once',
    },
    'cpu': {
      'sampleCount': sampleCount,
      'functions': functions.take(20).toList(),
      'meaning':
          'Self (leaf) and inclusive stack sample share, not CPU utilization.',
    },
    'traceCount': traces.length,
    'gcCount': list('gc').where(contains).length,
    'approximateGcCount': list(
      'gc',
    ).where((e) => overlaps(e) && !contains(e)).length,
    'widgetRebuildCount': list('widgetRebuilds')
        .where(contains)
        .fold<num>(
          0,
          (n, e) =>
              n +
              (e['widgets'] as List? ?? const []).fold<num>(
                0,
                (sum, w) =>
                    sum +
                    (w is Map && w['count'] is num ? w['count'] as num : 0),
              ),
        ),
    'evidence': {
      'frameNumbers': frames
          .map(
            (f) => {
              'segment': f['segment'],
              'isolate': f['isolate'],
              'number': f['number'],
            },
          )
          .toList(),
      'traceCount': traces.length,
    },
  };
}

JsonMap journeyPercentiles(List<double> values) {
  values.sort();
  double? at(double p) =>
      values.isEmpty ? null : values[(values.length * p).ceil() - 1];
  return {
    'p50': at(.5),
    'p90': at(.9),
    'p95': at(.95),
    'p99': at(.99),
    'max': values.isEmpty ? null : values.last,
  };
}

String _frameKey(JsonMap e) =>
    '${e['segment']}|${e['isolate']}|${e['frameNumber'] ?? e['number']}';
num? _number(dynamic value) => value is num && value.isFinite ? value : null;
num _max(num a, num b) => a > b ? a : b;
num _min(num a, num b) => a < b ? a : b;
int _byStart(JsonMap a, JsonMap b) {
  final at = _number(a['startMicros']), bt = _number(b['startMicros']);
  if (at == null && bt != null) return 1;
  if (bt == null && at != null) return -1;
  final order = (at ?? 0).compareTo(bt ?? 0);
  return order != 0
      ? order
      : '${a['id'] ?? a['number']}'.compareTo('${b['id'] ?? b['number']}');
}

/// Match explicit identities and repeated occurrences; labels are never keys.
JsonMap compareJourneys(
  JsonMap baseline,
  JsonMap candidate, {
  required bool compatible,
  double? regressionPercent,
}) {
  List<JsonMap> items(JsonMap r) =>
      ((r['journey'] as JsonMap?)?['items'] as List? ?? const [])
          .cast<JsonMap>();
  final before = {
    for (final item in items(baseline))
      if (item['comparable'] == true) item['comparisonKey'] as String: item,
  };
  final after = {
    for (final item in items(candidate))
      if (item['comparable'] == true) item['comparisonKey'] as String: item,
  };
  final all = {...before.keys, ...after.keys}.toList()..sort();
  final differences = <JsonMap>[];
  for (final key in all) {
    final a = before[key], b = after[key];
    final reasons = <String>[
      if (!compatible)
        'Run environments, settings, or capture quality are incompatible.',
      if (a == null) 'No matching baseline occurrence.',
      if (b == null) 'No matching candidate occurrence.',
      if (a != null && a['coverage'] != 'bounded')
        'Baseline interval is incomplete.',
      if (b != null && b['coverage'] != 'bounded')
        'Candidate interval is incomplete.',
      if (a != null &&
          a['status'] != 'success' &&
          a['status'] != 'passed' &&
          a['status'] != 'ended')
        'Baseline interval did not finish successfully.',
      if (b != null &&
          b['status'] != 'success' &&
          b['status'] != 'passed' &&
          b['status'] != 'ended')
        'Candidate interval did not finish successfully.',
    ];
    final metrics = <String, dynamic>{};
    for (final phase in ['buildMs', 'rasterMs']) {
      final av = ((a?['metrics'] as JsonMap?)?[phase] as JsonMap?)?['p95'];
      final bv = ((b?['metrics'] as JsonMap?)?[phase] as JsonMap?)?['p95'];
      final change = av is num && bv is num && av > 0
          ? (bv - av) * 100 / av
          : av == 0 && bv == 0
          ? 0
          : null;
      if (change == null) {
        reasons.add('No comparable $phase samples inside both boundaries.');
      }
      metrics[phase] = {
        'baselineP95': av,
        'candidateP95': bv,
        'changePercent': change,
      };
    }
    final pass = reasons.isEmpty;
    final failed = metrics.values.any(
      (dynamic m) =>
          m['changePercent'] is num &&
          regressionPercent != null &&
          (m['changePercent'] as num) > regressionPercent,
    );
    differences.add({
      'comparisonKey': key,
      'label': b?['label'] ?? a?['label'],
      'type': b?['type'] ?? a?['type'],
      'baselineItemId': a?['id'],
      'candidateItemId': b?['id'],
      'status': !pass
          ? 'inconclusive'
          : regressionPercent == null
          ? 'compared'
          : failed
          ? 'fail'
          : 'pass',
      'reasons': reasons,
      'metrics': metrics,
      'reportingOnly': {
        for (final field in [
          'durationMs',
          'peakHeapBytes',
          'heapDeltaBytes',
          'peakRssBytes',
          'rssDeltaBytes',
          'sampleCount',
        ])
          field: _descriptiveDifference(a, b, field),
      },
    });
  }
  for (final side in [('baseline', baseline), ('candidate', candidate)]) {
    for (final item in items(side.$2).where((i) => i['comparable'] != true)) {
      differences.add({
        'comparisonKey': item['comparisonKey'],
        'label': item['label'],
        'type': item['type'],
        '${side.$1}ItemId': item['id'],
        'status': 'inconclusive',
        'reasons': [
          item['comparisonLimitation'] ?? 'No stable comparison identity.',
        ],
        'metrics': <String, dynamic>{},
      });
    }
  }
  return {
    'matching': 'stable identity, hierarchy, and occurrence',
    'items': differences,
    'unmatchedCount': differences
        .where(
          (i) => i['baselineItemId'] == null || i['candidateItemId'] == null,
        )
        .length,
  };
}

JsonMap _descriptiveDifference(JsonMap? a, JsonMap? b, String field) {
  num? value(JsonMap? item) {
    final metrics = item?['metrics'] as JsonMap?;
    if (field == 'durationMs') return _number(item?[field]);
    return _number(
      (metrics?[field == 'sampleCount' ? 'cpu' : 'memory'] as JsonMap?)?[field],
    );
  }

  final av = value(a), bv = value(b);
  return {
    'baseline': av,
    'candidate': bv,
    'delta': av == null || bv == null ? null : bv - av,
    'changePercent': av == null || bv == null || av == 0
        ? null
        : (bv - av) * 100 / av.abs(),
    'gate': false,
  };
}

/// Adds explicit context only when all measured frames fit a bounded interval.
JsonMap addJourneyInsights(JsonMap insights, JsonMap journey) {
  final items = (journey['items'] as List? ?? const []).cast<JsonMap>();
  final findings = (insights['findings'] as List? ?? const []).cast<JsonMap>();
  var linked = 0;
  for (final finding in findings) {
    final evidence = finding['evidence'] as JsonMap?;
    if (evidence == null) continue;
    final candidates =
        items.where((item) {
          if (item['coverage'] != 'bounded') return false;
          if (!['screen', 'operation', 'step', 'test'].contains(item['type'])) {
            return false;
          }
          final selected =
              (((item['metrics'] as JsonMap?)?['evidence']
                              as JsonMap?)?['frameNumbers']
                          as List? ??
                      const [])
                  .whereType<JsonMap>();
          bool includes(dynamic number) => selected.any(
            (f) =>
                f['number'] == number &&
                f['segment'] == evidence['segment'] &&
                f['isolate'] == evidence['isolate'],
          );
          return includes(evidence['firstFrame']) &&
              includes(evidence['lastFrame']);
        }).toList()..sort(
          (a, b) => (a['durationMs'] as num).compareTo(b['durationMs'] as num),
        );
    if (candidates.isEmpty) continue;
    final context = candidates.first;
    finding['title'] = '${context['label']}: ${finding['title']}';
    finding['context'] = {
      'itemId': context['id'],
      'type': context['type'],
      'label': context['label'],
      'attribution': context['attribution'],
    };
    evidence['journeyItemId'] = context['id'];
    finding['attribution'] =
        'These frames lie inside the calibrated ${context['type']} interval “${context['label']}”. This identifies the active context, not the widget or operation responsible for the delay.';
    linked++;
  }
  if (linked > 0) {
    insights['headline'] =
        'Start with ${findings.firstWhere((f) => f['context'] != null)['context']['label']}.';
  }
  insights['limitations'] = [
    ...(insights['limitations'] as List? ?? const []).where(
      (dynamic text) =>
          !'$text'.contains('separate clocks are not joined') &&
          !'$text'.startsWith('Frame timings do not identify'),
    ),
    ...journey['limitations'] as List,
  ];
  return insights;
}
