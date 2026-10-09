import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// A developer-declared location, not a profiler-attributed cost or call stack.
final class RunalongSource {
  const RunalongSource({
    required this.uri,
    required this.line,
    this.column = 1,
  });

  /// A project-relative or package URI. Absolute paths are not emitted.
  final String uri;
  final int line;
  final int column;

  Map<String, Object>? _toJson() {
    final parsed = Uri.tryParse(uri);
    if (parsed == null ||
        uri.length > 512 ||
        line < 1 ||
        column < 1 ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        parsed.hasAuthority ||
        (parsed.hasScheme && parsed.scheme != 'package') ||
        parsed.path.startsWith('/') ||
        uri.contains('\\') ||
        parsed.pathSegments.any((part) => part == '..') ||
        uri.isEmpty) {
      return null;
    }
    return {
      'uri': uri,
      'line': line,
      'column': column,
      'provenance': 'declared',
    };
  }
}

/// Explicit screen scopes and operations. Disabled unless the build sets
/// `--dart-define=RUNALONG_CONTEXT=true`, and always disabled in release mode.
abstract final class RunalongContext {
  static const _defined = bool.fromEnvironment('RUNALONG_CONTEXT');
  static final Object _operationKey = Object();
  static final Object _screenKey = Object();
  static final List<RunalongScreenScope> _screens = [];
  static final Map<String, Map<String, Object>> _operations = {};
  static bool _extensionRegistered = false;
  static int _sequence = 0;
  static bool? _testEnabled;
  static void Function(String, Map<String, Object>)? _testSink;
  static int Function()? _testClock;

  static bool get isEnabled => !kReleaseMode && (_testEnabled ?? _defined);

  /// Starts an explicit visible-screen interval, useful for tabs and nesting.
  /// Labels and stable IDs must be static developer-authored values.
  static RunalongScreenScope startScreen({
    required String stableId,
    required String label,
    String? parentId,
    RunalongSource? source,
  }) {
    if (!isEnabled) return RunalongScreenScope._(null);
    final data = _start(
      'screen_start',
      stableId,
      label,
      parentId: parentId,
      source: source,
    );
    final scope = RunalongScreenScope._(data);
    _screens.add(scope);
    return scope;
  }

  /// The explicit/observer screen active in this asynchronous context.
  static String? get currentScreenId =>
      Zone.current[_screenKey] as String? ??
      (_screens.isEmpty ? null : _screens.last.id);

  /// Runs an async operation without recording arguments, results or errors.
  /// Nested operations inherit the parent occurrence and screen through Zones.
  static Future<T> operation<T>({
    required String stableId,
    required String label,
    required Future<T> Function() body,
    String? parentId,
    String? screenId,
    RunalongSource? source,
  }) {
    if (!isEnabled) return body();
    final screen = screenId ?? currentScreenId;
    final data = _start(
      'operation_start',
      stableId,
      label,
      parentId: parentId ?? Zone.current[_operationKey] as String?,
      screenId: screen,
      source: source,
    );
    return runZoned(() {
      try {
        return body().then(
          (result) {
            _end(data, 'operation_end', 'success');
            return result;
          },
          onError: (Object error, StackTrace stack) {
            _end(data, 'operation_end', 'error');
            Error.throwWithStackTrace(error, stack);
          },
        );
      } catch (_) {
        _end(data, 'operation_end', 'error');
        rethrow;
      }
    }, zoneValues: {_operationKey: data['id'], _screenKey: screen});
  }

  /// Synchronous counterpart; returns the original value or rethrows the error.
  static T operationSync<T>({
    required String stableId,
    required String label,
    required T Function() body,
    String? parentId,
    String? screenId,
    RunalongSource? source,
  }) {
    if (!isEnabled) return body();
    final screen = screenId ?? currentScreenId;
    final data = _start(
      'operation_start',
      stableId,
      label,
      parentId: parentId ?? Zone.current[_operationKey] as String?,
      screenId: screen,
      source: source,
    );
    return runZoned(() {
      try {
        final result = body();
        _end(data, 'operation_end', 'success');
        return result;
      } catch (_) {
        _end(data, 'operation_end', 'error');
        rethrow;
      }
    }, zoneValues: {_operationKey: data['id'], _screenKey: screen});
  }

  static int _now() => _testClock?.call() ?? developer.Timeline.now;

  static Map<String, Object> _start(
    String event,
    String stableId,
    String label, {
    String? parentId,
    String? screenId,
    RunalongSource? source,
  }) {
    _ensureExtension();
    final now = _now();
    final sourceData = source?._toJson();
    final data = <String, Object>{
      'version': 1,
      'event': event,
      'id': 'ctx-$now-${++_sequence}',
      'stableId': _text(stableId, 128),
      'label': _text(label, 200),
      if (parentId != null) 'parentId': _text(parentId, 128),
      if (screenId != null) 'screenId': _text(screenId, 128),
      if (sourceData != null) 'source': sourceData,
      'vmMicros': now,
    };
    if (event == 'operation_start') _operations[data['id']! as String] = data;
    _emit(data);
    return data;
  }

  static void _end(Map<String, Object> data, String event, String status) {
    if (event == 'operation_end') _operations.remove(data['id']);
    if (!isEnabled) return;
    _emit({...data, 'event': event, 'status': status, 'vmMicros': _now()});
  }

  static void _ensureExtension() {
    if (_extensionRegistered || !isEnabled) return;
    try {
      developer.registerExtension(
        'ext.runalong.context',
        (_, __) async =>
            developer.ServiceExtensionResponse.result(jsonEncode(_snapshot())),
      );
      _extensionRegistered = true;
    } catch (_) {
      // A duplicate extension or unavailable transport must not affect the app.
    }
  }

  static Map<String, Object> _snapshot() => {
    'version': 1,
    'screens':
        isEnabled
            ? _screens
                .map((screen) => Map<String, Object>.of(screen._data!))
                .toList()
            : <Map<String, Object>>[],
    'operations':
        isEnabled
            ? _operations.values.map(Map<String, Object>.of).toList()
            : <Map<String, Object>>[],
  };

  /// The payload returned by the read-only service extension.
  @visibleForTesting
  static Map<String, Object> debugSnapshot() => _snapshot();

  static void _emit(Map<String, Object> data) {
    // Instrumentation must never replace an application's return or exception.
    try {
      (_testSink ?? developer.postEvent)('Runalong.Context', data);
    } catch (_) {
      // Capture transport failures do not affect application behavior.
    }
  }

  static String _text(String value, int limit) {
    final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return clean.isEmpty
        ? 'unnamed'
        : clean.substring(0, clean.length.clamp(0, limit));
  }

  /// Test seam only. It cannot enable recording in a release build.
  @visibleForTesting
  static void debugConfigure({
    bool? enabled,
    void Function(String, Map<String, Object>)? sink,
    int Function()? clock,
  }) {
    _testEnabled = enabled;
    _testSink = sink;
    _testClock = clock;
    _screens.clear();
    _operations.clear();
    _sequence = 0;
  }
}

/// An explicit visible-screen occurrence. End it when hidden or disposed.
final class RunalongScreenScope {
  RunalongScreenScope._(this._data);
  final Map<String, Object>? _data;
  bool _ended = false;
  String? get id => _data?['id'] as String?;

  /// Associates work (including async descendants) with this screen.
  T run<T>(T Function() body) =>
      _data == null || _ended
          ? body()
          : runZoned(body, zoneValues: {RunalongContext._screenKey: id});

  /// Idempotent. Closing a parent does not implicitly close child scopes.
  void end() {
    if (_ended) return;
    _ended = true;
    RunalongContext._screens.remove(this);
    if (_data != null) RunalongContext._end(_data, 'screen_end', 'ended');
  }
}
