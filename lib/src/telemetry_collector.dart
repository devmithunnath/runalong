import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart' as vm;

import 'model.dart';
import 'telemetry_data.dart';

/// Optional VM capabilities are isolated here so unsupported telemetry never
/// prevents the core frame recorder from producing a useful capture.
final class VmTelemetry {
  VmTelemetry({
    required this.service,
    required this.options,
    required this.capture,
    required this.connection,
    required this.hostMicros,
    required this.segmentFor,
    required this.onRecord,
  }) {
    _timeline = TimelineEvidence(
      diagnostic: diagnostic,
      onRecord: _record,
      resolveFrame: (number, _) {
        final matches = _frames[number] ?? const <FrameSample>[];
        // Never use apparent cross-clock timestamp proximity to disambiguate
        // engines or restarted isolates sharing a frame number.
        final chosen = matches.length == 1 ? matches.single : null;
        return chosen == null
            ? null
            : (segment: chosen.segment, isolate: chosen.isolate);
      },
    );
    _metadata = <String, dynamic>{
      'connection': connection,
      'captureMode': options.captureMode,
      'memoryIntervalMs': diagnostic ? 500 : 1000,
      'cpuPollIntervalMs': diagnostic ? 2000 : null,
      'cpuScope': 'flutter-isolates',
      'memoryScope': 'non-system-isolate-groups',
      'capabilities': <String, dynamic>{},
      'settings': <String, dynamic>{},
      'coverage': <String, dynamic>{'records': 0, 'dropped': 0},
      'restoration': <JsonMap>[],
    };
    final telemetry =
        capture.putIfAbsent('telemetry', () => <String, dynamic>{}) as JsonMap;
    (telemetry.putIfAbsent('connections', () => <JsonMap>[]) as List).add(
      _metadata,
    );
  }

  final vm.VmService service;
  final RunOptions options;
  final JsonMap capture;
  final int connection;
  final int Function() hostMicros;
  final String Function(String isolate) segmentFor;
  final void Function(JsonMap) onRecord;
  bool get diagnostic => options.captureMode == 'diagnose';
  late final JsonMap _metadata;
  late final TimelineEvidence _timeline;
  final Map<int, List<FrameSample>> _frames = {};
  final Map<String, vm.Isolate> _isolates = {};
  final Map<String, JsonMap> _locations = {};
  final List<_Setting> _settings = [];
  final Set<String> _extensionConfigured = {};
  final Set<String> _contextSnapshots = {};
  final Set<String> _contextEvents = {};
  final Set<String> _gcEvents = {};
  final Set<String> _disabled = {};
  final List<StreamSubscription<vm.Event>> _subscriptions = [];
  Timer? _timer;
  Future<void>? _polling;
  Future<void>? _initializing;
  final Set<Future<void>> _configuring = {};
  bool _stopping = false;
  bool _finishing = false;
  bool _stopped = false;
  bool _setupDone = false;
  Future<void>? _stopFuture;
  int _records = 0;
  int _recordBytes = 0;
  int _anchorHost = 0;
  int? _anchorVm;
  int _uncertainty = 0;
  int? _lastTimeline;
  int? _lastCpu;
  bool _cpuWindowCollected = false;
  int _invalid = 0;

  Future<T> _rpc<T>(Future<T> operation) =>
      operation.timeout(const Duration(seconds: 2));
  JsonMap get _capabilities => _metadata['capabilities'] as JsonMap;
  JsonMap get _coverage => _metadata['coverage'] as JsonMap;

  Future<void> start() => _initializing ??= _start();

  Future<void> get ready async {
    await start();
    await Future.wait(_configuring.toList());
    _metadata['settingsReadyHostMicros'] = hostMicros();
  }

  Future<void> _start() async {
    await _clock();
    await _timelineSettings();
    await _cpuSettings();
    if (_stopping) return;
    _subscriptions.add(service.onGCEvent.listen(_gc));
    try {
      await _rpc(service.streamListen('GC'));
      _capabilities['gc'] = 'available';
    } catch (_) {
      _capabilities['gc'] = 'unavailable';
    }
    _setupDone = true;
    _schedule();
  }

  void inspectIsolate(vm.Isolate info) {
    final id = info.id;
    if (id == null || _stopping || _finishing) return;
    _isolates[id] = info;
    if ((info.extensionRPCs ?? []).contains('ext.runalong.context') &&
        _contextSnapshots.add(id)) {
      final pending = _contextSnapshot(id);
      _configuring.add(pending);
      unawaited(pending.whenComplete(() => _configuring.remove(pending)));
    }
    if (diagnostic) {
      final pending = _configureExtensions(info);
      _configuring.add(pending);
      unawaited(pending.whenComplete(() => _configuring.remove(pending)));
    }
  }

  void isolateExited(String id) {
    _isolates.remove(id);
    _contextSnapshots.remove(id);
    _locations.removeWhere((key, _) => key.startsWith('$id:'));
    _extensionConfigured.removeWhere((key) => key.startsWith('$id:'));
  }

  void frame(FrameSample sample) {
    if (diagnostic && (!_setupDone || _configuring.isNotEmpty)) {
      _coverage['preInstrumentationFrameCount'] =
          ((_coverage['preInstrumentationFrameCount'] as int?) ?? 0) + 1;
    }
    final list = _frames.putIfAbsent(sample.number, () => []);
    list.add(sample);
    if (list.length > 4) list.removeAt(0);
    if (_frames.length > 10000) _frames.remove(_frames.keys.first);
    _timeline.flush();
  }

  void extension(vm.Event event) {
    if (_stopping) return;
    final id = event.isolate?.id;
    final data = event.extensionData?.data;
    if (id == null || data == null) return;
    if (event.extensionKind == 'Runalong.Context') {
      final clean = sanitizeContext(data, sourceRoot: options.sourceRoot);
      if (clean == null) {
        _coverage['invalidContextEvents'] = ++_invalid;
        return;
      }
      _capabilities['context'] = 'available';
      _context(clean, id);
    } else if (diagnostic && event.extensionKind == 'Flutter.RebuiltWidgets') {
      _rebuilt(id, data);
    }
  }

  void _context(JsonMap clean, String isolate, {bool snapshot = false}) {
    final segment = segmentFor(isolate);
    if (!_contextEvents.add('$segment:${clean['event']}:${clean['id']}')) {
      return;
    }
    if (_contextEvents.length > 20000) {
      _contextEvents.remove(_contextEvents.first);
    }
    _record({
      ...clean,
      'segment': segment,
      'isolate': isolate,
      'hostMicros': hostMicros(),
      if (snapshot) 'snapshot': true,
    });
  }

  void _record(JsonMap event) {
    if (_stopped) return;
    final bytes = utf8.encode(jsonEncode(event)).length;
    if (_records >= 100000 || _recordBytes + bytes > 64 * 1024 * 1024) {
      _coverage['dropped'] = (_coverage['dropped'] as int) + 1;
      return;
    }
    _recordBytes += bytes;
    _coverage['bytes'] = _recordBytes;
    _coverage['records'] = ++_records;
    onRecord({'connection': connection, ...event});
  }

  Future<void> _clock() async {
    if (_disabled.contains('clock')) return;
    final before = hostMicros();
    try {
      final stamp = await _rpc(service.getVMTimelineMicros());
      final after = hostMicros();
      final micros = stamp.timestamp;
      if (micros == null || micros < 0) {
        throw const FormatException('Missing VM clock');
      }
      _anchorHost = (before + after) ~/ 2;
      _anchorVm = micros;
      _uncertainty = (after - before + 1) ~/ 2;
      _lastTimeline ??= micros;
      _lastCpu ??= micros;
      _capabilities['clock'] = 'available';
      _record({
        'kind': 'clock',
        'hostMicros': _anchorHost,
        'vmMicros': micros,
        'uncertaintyMicros': _uncertainty,
      });
    } catch (_) {
      if (_capabilities['clock'] != 'available') {
        _capabilities['clock'] = 'unavailable';
      }
      _coverage['clockRefreshFailed'] = true;
      _disabled.add('clock');
    }
  }

  Future<void> _timelineSettings() async {
    try {
      final flags = await _rpc(service.getVMTimelineFlags());
      final previous = flags.recordedStreams;
      if (previous == null) {
        throw const FormatException('Missing timeline flags');
      }
      (_metadata['settings'] as JsonMap)['timelineStreams'] = previous;
      if (diagnostic) {
        final wanted = {
          ...previous,
          ...[
            'Dart',
            'Embedder',
            'GC',
          ].where((s) => flags.availableStreams?.contains(s) ?? false),
        }.toList()..sort();
        if (!_sameStrings(previous, wanted)) {
          _settings.add(
            _Setting(
              'timelineStreams',
              previous,
              wanted,
              () async =>
                  (await _rpc(service.getVMTimelineFlags())).recordedStreams,
              (value) async {
                await _rpc(
                  service.setVMTimelineFlags((value as List).cast<String>()),
                );
              },
            ),
          );
          await _rpc(service.setVMTimelineFlags(wanted));
        }
        (_metadata['settings'] as JsonMap)['effectiveTimelineStreams'] = wanted;
      }
      _capabilities['timeline'] = 'available';
    } catch (_) {
      _capabilities['timeline'] = 'unavailable';
      _disabled.add('timeline');
    }
  }

  Future<void> _cpuSettings() async {
    if (!diagnostic) {
      _capabilities['cpu'] = 'diagnostic-only';
      _disabled.add('cpu');
      return;
    }
    try {
      final flags = await _rpc(service.getFlagList());
      final profiler = flags.flags
          ?.where((flag) => flag.name == 'profiler')
          .firstOrNull;
      if (profiler?.valueAsString == null) {
        throw const FormatException('No profiler flag');
      }
      final previous = profiler!.valueAsString!;
      (_metadata['settings'] as JsonMap)['profiler'] = previous;
      (_metadata['settings'] as JsonMap)['profilePeriod'] = flags.flags
          ?.where((f) => f.name == 'profile_period')
          .firstOrNull
          ?.valueAsString;
      if (previous != 'true' && diagnostic) {
        _settings.add(
          _Setting(
            'profiler',
            previous,
            'true',
            () async {
              return (await _rpc(service.getFlagList())).flags
                  ?.where((f) => f.name == 'profiler')
                  .firstOrNull
                  ?.valueAsString;
            },
            (value) async {
              final response = await _rpc(
                service.setFlag('profiler', value as String),
              );
              if (response is! vm.Success) {
                throw const FormatException('Profiler restore refused');
              }
            },
          ),
        );
        final result = await _rpc(service.setFlag('profiler', 'true'));
        if (result is! vm.Success) {
          throw const FormatException('Profiler refused');
        }
      } else if (previous != 'true') {
        _capabilities['cpu'] = 'disabled';
        _disabled.add('cpu');
        return;
      }
      _capabilities['cpu'] = 'available';
    } catch (_) {
      _capabilities['cpu'] = 'unavailable';
      _disabled.add('cpu');
    }
  }

  Future<void> _configureExtensions(vm.Isolate info) async {
    final id = info.id!;
    final guardedByTestFramework = (info.libraries ?? const <vm.LibraryRef>[])
        .any(
          (library) => library.uri?.startsWith('package:flutter_test/') == true,
        );
    for (final name in [
      'ext.flutter.profileWidgetBuilds',
      'ext.flutter.profileRenderObjectLayouts',
      'ext.flutter.profileRenderObjectPaints',
      'ext.flutter.inspector.trackRebuildDirtyWidgets',
    ]) {
      // TestWidgetsFlutterBinding verifies these globals before emitting the
      // test-end reporter event. Restoring on test-end is therefore too late.
      // Do not make an unchanged test fail solely because diagnosis was on.
      if (guardedByTestFramework) {
        _capabilities[name] = 'unavailable-test-invariants';
        _metadata['tracingLimitation'] =
            'Flutter test framework is loaded. Detailed tracing is skipped to preserve its debug-variable invariants. Use an independently launched app for full tracing.';
        continue;
      }
      if (_stopping ||
          !(info.extensionRPCs ?? const []).contains(name) ||
          !_extensionConfigured.add('$id:$name')) {
        continue;
      }
      try {
        final response = await _rpc(
          service.callServiceExtension(name, isolateId: id),
        );
        final previous = response.json?['enabled'];
        if (previous != 'true' && previous != 'false') {
          throw const FormatException('Invalid extension response');
        }
        if (previous == 'false') {
          _settings.add(
            _Setting(
              '$id:$name',
              previous as String,
              'true',
              () async {
                return (await _rpc(
                  service.callServiceExtension(name, isolateId: id),
                )).json?['enabled'];
              },
              (value) async {
                await _rpc(
                  service.callServiceExtension(
                    name,
                    isolateId: id,
                    args: {'enabled': value as String},
                  ),
                );
              },
            ),
          );
          await _rpc(
            service.callServiceExtension(
              name,
              isolateId: id,
              args: {'enabled': 'true'},
            ),
          );
        }
        _capabilities[name] = 'available';
        (_metadata['settings'] as JsonMap)[name] = {
          'isolate': id,
          'previous': previous,
          'effective': 'true',
        };
      } catch (_) {
        _capabilities[name] = 'unavailable';
      }
    }
  }

  void _schedule() {
    if (_stopping || _finishing) return;
    _timer = Timer(Duration(milliseconds: diagnostic ? 500 : 1000), () {
      final work = poll();
      unawaited(work.whenComplete(_schedule));
    });
  }

  /// Exposed for deterministic fixture tests; simultaneous polls share one job.
  Future<void> poll() {
    if (_stopping) return Future.value();
    if (_polling != null) return _polling!;
    final work = _poll();
    _polling = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_polling, work)) _polling = null;
      }),
    );
    return work;
  }

  Future<void> _poll() async {
    try {
      await _clock();
      if (_stopping) return;
      await _memory();
      if (_stopping) return;
      final until = _anchorVm;
      if (until == null) return;
      await _timelinePoll(until);
      if (_stopping) return;
      await _cpuPoll(until);
    } catch (_) {
      _coverage['pollFailures'] =
          ((_coverage['pollFailures'] as int?) ?? 0) + 1;
    }
  }

  Future<void> _memory() async {
    if (_disabled.contains('memory')) return;
    final before = hostMicros();
    try {
      final info = await _rpc(service.getVM());
      final ids = (info.isolateGroups ?? [])
          .where((g) => g.isSystemIsolateGroup != true && g.id != null)
          .map((g) => g.id!)
          .toSet();
      if (ids.isEmpty) {
        _capabilities['memory'] = 'unavailable';
        return;
      }
      final groups = <JsonMap>[];
      if (ids.length > 16) _coverage['memoryGroupsTruncated'] = true;
      for (final id in ids.take(16)) {
        if (_stopping) return;
        try {
          final usage = await _rpc(service.getIsolateGroupMemoryUsage(id));
          if ([
            usage.heapUsage,
            usage.heapCapacity,
            usage.externalUsage,
          ].any((v) => v == null || v < 0)) {
            continue;
          }
          groups.add({
            'id': id,
            'heapUsage': usage.heapUsage,
            'heapCapacity': usage.heapCapacity,
            'externalUsage': usage.externalUsage,
          });
        } catch (_) {
          /* The group may have exited between enumeration and polling. */
        }
      }
      if (groups.isEmpty) {
        _capabilities['memory'] = 'unavailable';
        return;
      }
      final after = hostMicros();
      final middle = (before + after) ~/ 2;
      final rss = info.json?['_currentRSS'];
      _capabilities['memory'] = 'available';
      _capabilities['rss'] = rss is int && rss >= 0
          ? 'private-vm-adapter'
          : 'unavailable';
      _record({
        'kind': 'memory',
        'hostMicros': middle,
        if (_anchorVm != null) 'vmMicros': _anchorVm! + middle - _anchorHost,
        'uncertaintyMicros': _uncertainty + (after - before + 1) ~/ 2,
        'groups': groups,
        if (rss is int && rss >= 0) 'rssBytes': rss,
      });
    } catch (_) {
      _capabilities['memory'] = 'unavailable';
    }
  }

  Future<void> _timelinePoll(int until) async {
    final start = _lastTimeline;
    if (_disabled.contains('timeline') || start == null || until <= start) {
      return;
    }
    try {
      final result = await _rpc(
        service.getVMTimeline(
          timeOriginMicros: start > 0 ? start - 1 : 0,
          timeExtentMicros: until - start + 1,
        ),
      );
      final events = result.traceEvents ?? [];
      if (events.length > 20000) _coverage['timelineTruncated'] = true;
      _timeline.add(events.map((e) => e.json ?? <String, dynamic>{}));
      _coverage['timelineDropped'] = _timeline.dropped;
      _lastTimeline = until;
    } catch (_) {
      _capabilities['timeline'] = 'unavailable';
      _disabled.add('timeline');
    }
  }

  Future<void> _cpuPoll(int until) async {
    final start = _lastCpu;
    if (_disabled.contains('cpu') || start == null || until <= start) return;
    // CPU responses include the VM's historical function table. Retrieve less
    // often than memory while preserving continuous sample windows and the
    // VM's sampling period. Always collect the trailing interval on shutdown.
    if (_cpuWindowCollected && !_finishing && until - start < 2000000) return;
    for (final entry in _isolates.entries.toList().take(8)) {
      if (_stopping) return;
      try {
        final result = await _rpc(
          service.getCpuSamples(
            entry.key,
            start > 0 ? start - 1 : 0,
            until - start + 1,
          ),
        );
        final samples = result.samples ?? [];
        final functions = result.functions ?? [];
        if (samples.length > 20000) _coverage['cpuTruncated'] = true;
        // The VM function table can cover its entire profiling history. Keep
        // only functions referenced by this incremental window, remapping IDs.
        final safeFunctions = <JsonMap>[];
        final functionIds = <int, int>{};
        final safeSamples = <JsonMap>[];
        for (final sample in samples.take(20000)) {
          final stamp = sample.timestamp, stack = sample.stack;
          if (stamp == null ||
              stamp < start ||
              stamp >= until ||
              stack == null) {
            continue;
          }
          if (stack.any((i) => i < 0 || i >= functions.length)) continue;
          final retainedStack = <int>[];
          var valid = true;
          for (final oldId in stack.take(256)) {
            var newId = functionIds[oldId];
            if (newId == null) {
              if (safeFunctions.length >= 10000) {
                _coverage['cpuTruncated'] = true;
                valid = false;
                break;
              }
              final function = functions[oldId];
              final value = function.function;
              final ref = value is vm.FuncRef ? value : null;
              final source = telemetrySource(
                {
                  'uri': ref?.location?.script?.uri ?? function.resolvedUrl,
                  'line': ref?.location?.line,
                  'column': ref?.location?.column,
                },
                sourceRoot: options.sourceRoot,
                provenance: 'runtime',
              );
              newId = safeFunctions.length;
              functionIds[oldId] = newId;
              safeFunctions.add({
                'name':
                    telemetryText(
                      ref?.name ??
                          (value is vm.NativeFunction ? value.name : null),
                      180,
                    ) ??
                    'Unresolved function',
                if (source != null) ...source,
                'provenance': 'runtime',
              });
            }
            retainedStack.add(newId);
          }
          if (!valid) continue;
          safeSamples.add({
            'vmMicros': stamp,
            'threadId': ?sample.tid,
            'stack': retainedStack,
            if (sample.truncated == true || stack.length > 256)
              'truncated': true,
          });
        }
        _record({
          'kind': 'cpu',
          'segment': segmentFor(entry.key),
          'isolate': entry.key,
          'vmStartMicros': start,
          'vmEndMicros': until,
          'samplePeriodMicros': result.samplePeriod,
          'samples': safeSamples,
          'functions': safeFunctions,
        });
      } catch (_) {
        _coverage['cpuWindowFailures'] =
            ((_coverage['cpuWindowFailures'] as int?) ?? 0) + 1;
      }
    }
    _lastCpu = until;
    _cpuWindowCollected = true;
  }

  void _gc(vm.Event event) {
    if (_stopping) return;
    final id = event.isolate?.id;
    if (id == null) return;
    final group = event.isolateGroup?.id ?? _isolates[id]?.isolateGroupId;
    final type = telemetryText(event.gcType, 80);
    if (group != null && event.timestamp != null) {
      final newHeap = event.json?['new'], oldHeap = event.json?['old'];
      final key =
          '$group:${event.timestamp}:$type:${newHeap is Map ? newHeap['used'] : null}:${oldHeap is Map ? oldHeap['used'] : null}';
      if (!_gcEvents.add(key)) return;
      if (_gcEvents.length > 10000) _gcEvents.remove(_gcEvents.first);
    }
    // VM GC notification timestamp is wall time; transport receipt cannot be
    // upgraded to an exact VM-monotonic timestamp.
    _record({
      'kind': 'gc',
      'segment': segmentFor(id),
      'isolate': id,
      'hostMicros': hostMicros(),
      'attribution': 'receipt',
      'isolateGroup': ?group,
      'gcType': ?type,
      if (event.timestamp != null) 'eventTimestampMillis': event.timestamp,
    });
  }

  void _rebuilt(String id, JsonMap data) {
    final locations = data['locations'];
    if (locations is Map) {
      for (final entry in locations.entries.take(500)) {
        final values = entry.value;
        if (entry.key is! String || values is! Map) continue;
        final ids = values['ids'],
            names = values['names'],
            lines = values['lines'],
            columns = values['columns'];
        if (ids is! List ||
            names is! List ||
            lines is! List ||
            columns is! List) {
          continue;
        }
        for (var i = 0; i < ids.length && i < 1000; i++) {
          if (i >= names.length ||
              i >= lines.length ||
              i >= columns.length ||
              ids[i] is! int) {
            break;
          }
          final source = telemetrySource(
            {'uri': entry.key, 'line': lines[i], 'column': columns[i]},
            sourceRoot: options.sourceRoot,
            provenance: 'runtime_creation',
          );
          final name = telemetryText(names[i], 160);
          if (source != null && name != null && _locations.length < 10000) {
            _locations['$id:${ids[i]}'] = {'name': name, 'source': source};
          }
        }
      }
    }
    final number = data['frameNumber'], pairs = data['events'];
    if (number is! int || number < 0 || pairs is! List) return;
    final widgets = <JsonMap>[];
    for (var i = 0; i + 1 < pairs.length && i < 2000; i += 2) {
      final location = _locations['$id:${pairs[i]}'];
      final count = pairs[i + 1];
      if (location != null && count is int && count >= 0) {
        widgets.add({...location, 'count': count});
      }
    }
    if (widgets.isNotEmpty) {
      _record({
        'kind': 'widget_rebuild',
        'segment': segmentFor(id),
        'isolate': id,
        'frameNumber': number,
        'widgets': widgets,
      });
    }
  }

  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _finishing = true;
    _timer?.cancel();
    await _initializing;
    await _polling;
    await Future.wait(_configuring.toList());
    // Fetch the trailing sub-interval before restoring flags or closing the
    // service. An exited VM is a recoverable missing tail, never a hang.
    await _clock();
    if (_anchorVm case final int until) {
      await _timelinePoll(until);
      await _cpuPoll(until);
    }
    _stopping = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final setting in _settings.reversed) {
      var status = 'restored';
      try {
        final current = await setting.read();
        final matches = current is List && setting.expected is List
            ? _sameStrings(
                current.cast<String>(),
                (setting.expected as List).cast<String>(),
              )
            : current == setting.expected;
        final alreadyRestored = current is List && setting.previous is List
            ? _sameStrings(
                current.cast<String>(),
                (setting.previous as List).cast<String>(),
              )
            : current == setting.previous;
        if (alreadyRestored) {
          // The original write may have failed or another client restored it.
        } else if (!matches) {
          status = 'conflict-preserved';
        } else {
          await setting.write(setting.previous);
        }
      } catch (_) {
        status = 'unavailable';
      }
      (_metadata['restoration'] as List).add({
        'setting': setting.name,
        'status': status,
      });
    }
    _stopped = true;
  }

  Future<void> _contextSnapshot(String id) async {
    try {
      final response = await _rpc(
        service.callServiceExtension('ext.runalong.context', isolateId: id),
      );
      final json = response.json;
      if (json == null) return;
      final data = json['result'] is Map ? json['result'] as Map : json;
      for (final key in ['screens', 'operations']) {
        final values = data[key];
        if (values is! List) continue;
        for (final item in values.take(500).whereType<Map>()) {
          final clean = sanitizeContext(
            Map<String, dynamic>.from(item),
            sourceRoot: options.sourceRoot,
          );
          if (clean == null) continue;
          _context(clean, id, snapshot: true);
          _capabilities['context'] = 'available';
        }
      }
    } catch (_) {
      _capabilities['contextSnapshot'] = 'unavailable';
    }
  }
}

bool _sameStrings(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);

final class _Setting {
  _Setting(this.name, this.previous, this.expected, this.read, this.write);
  final String name;
  final Object previous;
  final Object expected;
  final Future<Object?> Function() read;
  final Future<void> Function(Object) write;
}
