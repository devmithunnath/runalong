import 'package:path/path.dart' as p;

import 'model.dart';

/// Persist only source coordinates, never a source body or an absolute path.
JsonMap? telemetrySource(
  Object? value, {
  String? sourceRoot,
  required String provenance,
}) {
  if (value is! Map) return null;
  final raw = value['uri'] ?? value['file'];
  if (raw is! String || raw.length > 4096) return null;
  try {
    if (Uri.decodeComponent(
      raw,
    ).replaceAll('\\', '/').split('/').contains('..')) {
      return null;
    }
  } on FormatException {
    return null;
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      parsed.pathSegments.contains('..') ||
      parsed.host.isNotEmpty) {
    return null;
  }
  String uri;
  if (parsed.scheme == 'package') {
    uri = raw;
  } else if (parsed.scheme == 'file' || p.isAbsolute(raw)) {
    if (sourceRoot == null) return null;
    final path = parsed.scheme == 'file' ? parsed.toFilePath() : raw;
    final root = p.normalize(p.absolute(sourceRoot));
    final normalized = p.normalize(p.absolute(path));
    if (!p.isWithin(root, normalized)) return null;
    uri = p.relative(normalized, from: root).replaceAll('\\', '/');
  } else if (parsed.scheme.isEmpty && !raw.startsWith('/')) {
    uri = raw.replaceAll('\\', '/');
  } else {
    return null;
  }
  if (uri.split('/').contains('..') ||
      uri.length > 512 ||
      uri.contains(RegExp(r'[\x00-\x1f]'))) {
    return null;
  }
  return {
    'uri': uri,
    if (value['line'] case final int line when line > 0) 'line': line,
    if (value['column'] case final int column when column > 0) 'column': column,
    'provenance': provenance,
  };
}

String? telemetryText(Object? value, [int limit = 200]) {
  if (value is! String || value.trim().isEmpty) return null;
  final safe = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return safe.substring(0, safe.length.clamp(0, limit));
}

JsonMap? sanitizeContext(JsonMap data, {String? sourceRoot}) {
  const events = {
    'screen_start',
    'screen_end',
    'operation_start',
    'operation_end',
  };
  if (data['version'] != 1 || !events.contains(data['event'])) return null;
  final id = telemetryText(data['id'], 128);
  final stableId = telemetryText(data['stableId'], 128);
  final label = telemetryText(data['label']);
  final micros = data['vmMicros'];
  if (id == null ||
      stableId == null ||
      label == null ||
      micros is! int ||
      micros < 0) {
    return null;
  }
  final source = telemetrySource(
    data['source'],
    sourceRoot: sourceRoot,
    provenance: 'declared',
  );
  return {
    'kind': 'context',
    'version': 1,
    'event': data['event'],
    'id': id,
    'stableId': stableId,
    'label': label,
    'vmMicros': micros,
    if (telemetryText(data['parentId'], 128) case final String parent)
      'parentId': parent,
    if (telemetryText(data['screenId'], 128) case final String screen)
      'screenId': screen,
    if ({'success', 'error', 'ended', 'cancelled'}.contains(data['status']))
      'status': data['status'],
    'source': ?source,
  };
}

/// Stateful, bounded Chrome-timeline parser. Only complete engine frame trees
/// are exported; a timestamp guess can never turn into an exact frame link.
final class TimelineEvidence {
  TimelineEvidence({
    required this.diagnostic,
    required this.onRecord,
    required this.resolveFrame,
  });
  final bool diagnostic;
  final void Function(JsonMap) onRecord;
  final ({String segment, String isolate})? Function(
    int number,
    int startMicros,
  )
  resolveFrame;
  final Map<String, List<_Slice>> _stacks = {};
  final Set<String> _seen = {};
  final List<_Slice> _pending = [];
  final Map<String, _Slice> _engineOpen = {};
  final List<_Slice> _envelopes = [];
  int dropped = 0;
  int _nodes = 0;

  void add(Iterable<JsonMap> events) {
    var detailCount = 0, envelopeCount = 0;
    final sorted =
        events.where((event) {
          if (event['ts'] is! num) return false;
          if (event['name'] == 'Animator::BeginFrame' ||
              event['name'] == 'Rasterizer::DoDraw') {
            return ++envelopeCount <= 10000;
          }
          return ++detailCount <= 20000;
        }).toList()..sort(
          (a, b) => ((a['ts'] as num?) ?? 0).compareTo((b['ts'] as num?) ?? 0),
        );
    for (final event in sorted) {
      final phase = event['ph'];
      final ts = event['ts'];
      final tid = event['tid'];
      final pid = event['pid'];
      if (ts is! num || !ts.isFinite || ts < 0 || tid is! num) continue;
      if (phase != 'B' && phase != 'E' && phase != 'X') continue;
      final key = '$pid:$tid';
      final name = telemetryText(event['name'], 160);
      final identity = '$key:$phase:$ts:$name';
      if (!_seen.add(identity)) continue;
      if (_seen.length > 50000) _seen.remove(_seen.first);
      // Engine envelopes are independent of nested Dart/layout trace parsing.
      // A truncated detail tree must not discard otherwise complete frame IDs.
      if (name == 'Animator::BeginFrame' || name == 'Rasterizer::DoDraw') {
        final engineKey = '$key:$name';
        final args = event['args'];
        final number = args is Map
            ? int.tryParse('${args['frame_number']}')
            : null;
        if ((phase == 'B' || phase == 'X') && number != null && number >= 0) {
          final node = _Slice(name!, ts.toInt(), number);
          if (phase == 'X' &&
              event['dur'] is num &&
              (event['dur'] as num) >= 0) {
            node.end = node.start + (event['dur'] as num).toInt();
            _envelopes.add(node);
          } else if (phase == 'B') {
            _engineOpen[engineKey] = node;
          }
        } else if (phase == 'E') {
          final node = _engineOpen.remove(engineKey);
          if (node != null && ts >= node.start) {
            node.end = ts.toInt();
            _envelopes.add(node);
          }
        }
        if (_envelopes.length > 1000) {
          _envelopes.removeAt(0);
          dropped++;
        }
      }
      final stack = _stacks.putIfAbsent(key, () => []);
      while (stack.isNotEmpty && stack.last.complete && stack.last.end! <= ts) {
        stack.removeLast();
      }
      if (phase == 'E') {
        if (stack.isEmpty) continue;
        final node = stack.removeLast();
        if (name != null && name != node.name) {
          stack.clear();
          dropped++;
          continue;
        }
        node.end = ts.toInt();
        if (node.end! < node.start) {
          dropped++;
          continue;
        }
        if (node.frame != null) _queue(node);
      } else {
        if (name == null) continue;
        if (++_nodes > 50000 || stack.length >= 200) {
          dropped++;
          _stacks.clear();
          _nodes = 0;
          continue;
        }
        final args = event['args'];
        final frameRaw = args is Map ? args['frame_number'] : null;
        final frame = frameRaw is int
            ? frameRaw
            : (frameRaw is String ? int.tryParse(frameRaw) : null);
        final isFrame =
            name == 'Animator::BeginFrame' || name == 'Rasterizer::DoDraw';
        final node = _Slice(
          name,
          ts.toInt(),
          isFrame && frame != null && frame >= 0 ? frame : null,
        );
        if (phase == 'X') {
          final duration = event['dur'];
          if (duration is! num || !duration.isFinite || duration < 0) continue;
          node.end = node.start + duration.toInt();
          node.complete = true;
          if (stack.isNotEmpty) stack.last.children.add(node);
          stack.add(node);
          if (node.frame != null) _queue(node);
        } else {
          if (stack.isNotEmpty) stack.last.children.add(node);
          stack.add(node);
        }
      }
    }
    flush();
  }

  void _queue(_Slice node) {
    if (_pending.length >= 1000) {
      _pending.removeAt(0);
      dropped++;
    }
    _pending.add(node);
  }

  void flush() {
    for (final root in _envelopes.toList()) {
      final identity = resolveFrame(root.frame!, root.start);
      if (identity == null) continue;
      _envelopes.remove(root);
      onRecord({
        'kind': 'frame_timeline',
        'segment': identity.segment,
        'isolate': identity.isolate,
        'frameNumber': root.frame,
        'vmStartMicros': root.start,
        'vmEndMicros': root.end,
        'scope': root.name == 'Animator::BeginFrame' ? 'build' : 'raster',
      });
    }
    for (final root in _pending.toList()) {
      final identity = resolveFrame(root.frame!, root.start);
      if (identity == null) continue;
      _pending.remove(root);
      final envelope = {
        'segment': identity.segment,
        'isolate': identity.isolate,
        'frameNumber': root.frame,
      };
      void visit(_Slice node, bool inBuild) {
        if (node.end == null) return;
        final lower = node.name.toLowerCase();
        final isBuild = lower == 'build';
        final isPhase =
            isBuild ||
            lower == 'layout' ||
            lower == 'layout (root)' ||
            lower == 'paint' ||
            lower == 'paint (root)' ||
            node == root;
        // Widget traces contain runtimeType names. Arbitrary application spans
        // are not persisted. The category remains a diagnostic candidate.
        final isWidget =
            diagnostic &&
            inBuild &&
            RegExp(
              r'^_?[A-Z][A-Za-z0-9_]*(?:<[A-Za-z0-9_, ?]+>)?$',
            ).hasMatch(node.name) &&
            !isPhase;
        if (isPhase || isWidget) {
          onRecord({
            'kind': 'trace',
            ...envelope,
            'name': node.name,
            'category': isPhase ? 'phase' : 'widget',
            'vmStartMicros': node.start,
            'vmEndMicros': node.end,
          });
        }
        for (final child in node.children) {
          visit(child, inBuild || isBuild);
        }
      }

      visit(root, false);
    }
  }
}

final class _Slice {
  _Slice(this.name, this.start, this.frame);
  final String name;
  final int start;
  final int? frame;
  int? end;
  bool complete = false;
  final List<_Slice> children = [];
}
