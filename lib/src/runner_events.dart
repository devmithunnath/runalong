import 'dart:convert';
import 'dart:io';

import 'model.dart';

/// Records only named boundaries, never test output, input values or exceptions.
/// Reporter clocks are receipt-aligned: transport delay is not claimed exact.
final class RunnerEvents {
  RunnerEvents({required this.hostMicros, required this.onRecord});
  final int Function() hostMicros;
  final void Function(JsonMap) onRecord;
  final Map<int, JsonMap> _tests = {};
  final Map<int, String> _suites = {};
  final Set<String> _seen = {};
  int? _reporterOrigin;
  int? _externalOrigin;
  int _offset = 0;
  String _pending = '';
  bool _reading = false;
  int invalidRecords = 0;
  int count = 0;

  void dartLine(String line) {
    if (line.length > 131072 || !line.trimLeft().startsWith('{')) return;
    try {
      final raw = jsonDecode(line);
      if (raw is! Map<String, dynamic>) return;
      final time = raw['time'];
      if (time is! int || time < 0) return;
      _reporterOrigin ??= hostMicros() - time * 1000;
      if (raw['type'] == 'suite') {
        final suite = raw['suite'];
        if (suite is Map && suite['id'] is int && suite['path'] is String) {
          // Only a filename is needed to distinguish suite identities.
          _suites[suite['id'] as int] = (suite['path'] as String)
              .replaceAll('\\', '/')
              .split('/')
              .last;
        }
      } else if (raw['type'] == 'testStart') {
        final test = raw['test'];
        if (test is! Map ||
            test['id'] is! int ||
            test['name'] is! String ||
            test['hidden'] == true) {
          return;
        }
        final id = test['id'] as int;
        final name = _label(test['name']);
        // The reporter also exposes loader/teardown pseudo-tests. They are
        // runner plumbing, not user journeys (and loader names contain paths).
        if ((name.startsWith('loading ') &&
                (test['groupIDs'] as List? ?? const []).isEmpty) ||
            name == '(tearDownAll)' ||
            name == '(setUpAll)') {
          return;
        }
        final stableId = '${_suites[test['suiteID']] ?? 'test'}::$name';
        _tests[id] = {
          'id': 'dart-test-$id',
          'stableId': stableId,
          'label': name,
        };
        _emit({
          ..._tests[id]!,
          'event': 'test_start',
          'hostMicros': _reporterOrigin! + time * 1000,
        });
      } else if (raw['type'] == 'testDone' && raw['testID'] is int) {
        final test = _tests.remove(raw['testID']);
        if (test == null) return;
        _emit({
          ...test,
          'event': 'test_end',
          'hostMicros': _reporterOrigin! + time * 1000,
          'status': raw['skipped'] == true
              ? 'skipped'
              : raw['result'] == 'success'
              ? 'passed'
              : 'failed',
        });
      }
    } on FormatException {
      /* Ordinary logs are not journey data. */
    }
  }

  /// External producers write a fresh JSONL file. A sync record anchors their
  /// elapsed clock; polling/transport make this an approximate association.
  void externalLine(String line) {
    try {
      final raw = jsonDecode(line);
      if (raw is! Map<String, dynamic> ||
          raw['version'] != 1 ||
          raw['timeMicros'] is! int ||
          (raw['timeMicros'] as int) < 0) {
        throw const FormatException('Invalid event');
      }
      final time = raw['timeMicros'] as int;
      if (raw['event'] == 'sync') {
        _externalOrigin ??= hostMicros() - time;
        return;
      }
      if (_externalOrigin == null ||
          ![
            'test_start',
            'test_end',
            'step_start',
            'step_end',
          ].contains(raw['event']) ||
          raw['id'] is! String ||
          raw['stableId'] is! String ||
          raw['label'] is! String) {
        throw const FormatException('Missing sync or event fields');
      }
      final id = raw['id'] as String;
      if (!RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$').hasMatch(id)) {
        throw const FormatException('Invalid id');
      }
      _emit({
        'event': raw['event'],
        'id': 'external-$id',
        'stableId': _label(raw['stableId']),
        'label': _label(raw['label']),
        if (raw['parentId'] is String)
          'parentId': 'external-${_label(raw['parentId'])}',
        'hostMicros': _externalOrigin! + time,
        if ([
          'passed',
          'failed',
          'cancelled',
          'skipped',
        ].contains(raw['status']))
          'status': raw['status'],
      });
    } on FormatException {
      invalidRecords++;
    }
  }

  void _emit(JsonMap event) {
    if (count >= 20000) {
      invalidRecords++;
      return;
    }
    final key = '${event['id']}:${event['event']}';
    if (!_seen.add(key)) return;
    count++;
    onRecord({
      'kind': 'runner',
      ...event,
      'clock': 'host',
      'uncertaintyMicros': null,
      'attribution': 'receipt-aligned',
    });
  }

  Future<void> readFile(String path, {bool finish = false}) async {
    if (_reading) return;
    _reading = true;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final input = await file.open();
      try {
        final length = await input.length();
        if (length < _offset) {
          invalidRecords++;
          return;
        }
        await input.setPosition(_offset);
        final bytes = await input.read((length - _offset).clamp(0, 1048576));
        _offset += bytes.length;
        // JSONL permits ASCII escaped labels; incomplete UTF8 is retained below
        // by buffering bytes through complete newline-delimited records.
        _pending += latin1.decode(bytes);
        final lines = _pending.split('\n');
        _pending = lines.removeLast();
        for (final encoded in lines) {
          final line = utf8.decode(
            latin1.encode(encoded),
            allowMalformed: true,
          );
          if (line.trim().isNotEmpty) externalLine(line);
        }
        if (_pending.length > 131072) {
          _pending = '';
          invalidRecords++;
        }
        if (finish && _pending.trim().isNotEmpty) {
          externalLine(
            utf8.decode(latin1.encode(_pending), allowMalformed: true),
          );
          _pending = '';
        }
      } finally {
        await input.close();
      }
    } on FileSystemException {
      invalidRecords++;
    } finally {
      _reading = false;
    }
  }

  static String _label(Object? value) {
    final text = '$value'.replaceAll(RegExp(r'[\x00-\x1f]'), ' ');
    return text.substring(0, text.length.clamp(0, 256));
  }
}
