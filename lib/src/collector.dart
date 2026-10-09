import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart' as vm;

import 'config.dart';
import 'model.dart';
import 'telemetry_collector.dart';

/// Frame recording remains independent of the automation framework. Diagnostic
/// instrumentation is explicit and its previous runtime settings are restored.
final class VmCollector {
  VmCollector({
    required this.options,
    required this.capture,
    required this.environment,
    required this.onRecord,
    int Function()? hostMicros,
  }) : hostMicros =
           hostMicros ?? (Stopwatch()..start()).elapsedMicrosecondsGetter;

  final RunOptions options;
  final JsonMap capture;
  final JsonMap environment;
  final void Function(JsonMap event) onRecord;
  final int Function() hostMicros;
  VmTelemetry? _telemetry;
  vm.VmService? _service;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<vm.Event>? _extensions;
  StreamSubscription<vm.Event>? _isolates;
  final Map<String, String> _isolateSegments = {};
  final Set<String> _seen = {};
  final Set<String> _inspecting = {};
  final Set<String> _inspectAgain = {};
  final Map<String, String> _modes = {};
  final Set<String> _frameIsolates = {};
  final Map<String, DateTime> _lastProbe = {};
  var _connection = 0;
  var _incarnation = 0;
  var _closed = false;
  var _navigationCount = 0;
  var frameCount = 0;

  Future<void> get onDone => _service?.onDone ?? Future.value();
  Future<void> get telemetryReady => _telemetry?.ready ?? Future.value();

  Future<void> connect(
    Uri uri, {
    Duration timeout = const Duration(seconds: 10),
    Future<void>? interrupted,
  }) async {
    if (_closed) throw StateError('Collector is closed.');
    final deadline = DateTime.now().add(timeout);
    Future<T> bounded<T>(Future<T> operation) {
      final remaining = deadline.difference(DateTime.now());
      return Future.any<T>([
        operation,
        if (interrupted != null)
          interrupted.then<T>(
            (_) => throw StateError('Connection interrupted.'),
          ),
      ]).timeout(remaining.isNegative ? Duration.zero : remaining);
    }

    final normalized = serviceWebSocketUri(uri.toString());
    var expired = false;
    final pendingSocket = WebSocket.connect(normalized.toString());
    unawaited(
      pendingSocket.then((socket) async {
        if (expired || _closed) await socket.close();
      }, onError: (Object error, StackTrace stack) {}),
    );
    final WebSocket socket;
    try {
      socket = await bounded(pendingSocket);
    } catch (_) {
      expired = true;
      rethrow;
    }
    if (_closed) {
      await socket.close();
      return;
    }
    await _disconnect();
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 10);
    final stream = StreamController<dynamic>();
    _socketSubscription = socket.listen(
      stream.add,
      onDone: stream.close,
      onError: (Object error, StackTrace stack) {
        unawaited(stream.close());
      },
    );
    final service = vm.VmService(
      stream.stream,
      socket.add,
      disposeHandler: () async {
        await socket.close();
      },
    );
    _service = service;
    _connection++;
    _isolateSegments.clear();
    _modes.clear();
    _frameIsolates.clear();
    _lastProbe.clear();
    environment['buildMode'] = 'unknown';
    environment['buildModeEvidence'] = 'Runtime verification pending';
    _extensions = service.onExtensionEvent.listen(_event);
    _isolates = service.onIsolateEvent.listen((event) {
      final id = event.isolate?.id;
      if (id == null) return;
      if (event.kind == 'IsolateExit') {
        _telemetry?.isolateExited(id);
        final wasFlutter = _frameIsolates.contains(id);
        _isolateSegments.remove(id);
        _modes.remove(id);
        _frameIsolates.remove(id);
        _lastProbe.remove(id);
        if (wasFlutter) {
          _gap(
            'Flutter isolate exited; subsequent frames start a new segment.',
          );
        }
      } else if (event.kind == 'IsolateRunnable' ||
          event.kind == 'ServiceExtensionAdded') {
        if (_inspecting.contains(id)) {
          _inspectAgain.add(id);
        } else {
          unawaited(_inspectIsolate(id));
        }
      }
    });
    try {
      await bounded(service.streamListen('Extension'));
      await bounded(service.streamListen('Isolate'));
      if (_closed) return;
      capture['startedAt'] ??= DateTime.now().toUtc().toIso8601String();
      final info = await bounded(service.getVM());
      environment.addAll({
        'os': info.operatingSystem,
        'architecture': info.targetCPU,
        'dartVersion': info.version,
      });
      // Flutter mobile/desktop targets expose a native operating system.
      if (info.operatingSystem == null || info.operatingSystem == 'web') {
        throw const FormatException(
          'This collector requires a native Flutter VM.',
        );
      }
      _telemetry = VmTelemetry(
        service: service,
        options: options,
        capture: capture,
        connection: _connection,
        hostMicros: hostMicros,
        segmentFor: _segmentFor,
        onRecord: onRecord,
      );
      // Optional capabilities are probed in the background; a slow or older
      // VM must not delay the existing automation/capture handshake.
      unawaited(_telemetry!.start());
      await bounded(
        Future.wait([
          for (final isolate in info.isolates ?? <vm.IsolateRef>[])
            if (isolate.id != null) _inspectIsolate(isolate.id!),
        ]),
      );
    } catch (_) {
      await _disconnect();
      rethrow;
    }
  }

  void _gap(String reason) {
    (capture['gaps'] as List<dynamic>).add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'reason': reason,
    });
  }

  void _event(vm.Event event) {
    if (_closed) return;
    final isolate = event.isolate?.id;
    final data = event.extensionData?.data;
    if (isolate == null || data == null) return;
    _telemetry?.extension(event);
    final now = DateTime.now().toUtc().toIso8601String();
    if (event.extensionKind == 'Flutter.Frame') {
      try {
        final segment = _segmentFor(isolate);
        final frame = FrameSample.fromJson({
          'segment': segment,
          'isolate': isolate,
          'number': data['number'],
          'startTimeMicros': data['startTime'],
          'buildMicros': data['build'],
          'rasterMicros': data['raster'],
          'elapsedMicros': data['elapsed'],
          'vsyncOverheadMicros': data['vsyncOverhead'],
          'receivedAt': now,
        });
        if (_seen.contains(frame.identity)) return;
        if (frameCount >= options.maxFrames) {
          capture['droppedEvents'] = (capture['droppedEvents'] as int) + 1;
          return;
        }
        _seen.add(frame.identity);
        _frameIsolates.add(isolate);
        frameCount++;
        capture['frameCount'] = frameCount;
        onRecord(frame.toJson());
        _telemetry?.frame(frame);
        _updateMode();
        if (!_modes.containsKey(isolate) &&
            DateTime.now()
                    .difference(_lastProbe[isolate] ?? DateTime(1970))
                    .inSeconds >=
                5) {
          unawaited(_inspectIsolate(isolate));
        }
      } on FormatException {
        capture['invalidEvents'] = (capture['invalidEvents'] as int) + 1;
      }
    } else if (event.extensionKind == 'Flutter.Navigation' &&
        _navigationCount < 2000) {
      final route = data['route'];
      final settings = route is Map ? route['settings'] : null;
      final rawName = settings is Map ? settings['name'] : null;
      final name = rawName is String
          ? rawName.split('?').first.split('#').first
          : null;
      onRecord({
        'kind': 'navigation',
        'receivedAt': now,
        'timestampMillis': event.timestamp,
        'isolate': isolate,
        'routeName': name?.substring(0, name.length.clamp(0, 256)),
        'attribution': 'approximate',
      });
      _navigationCount++;
    }
  }

  String _segmentFor(String isolate) =>
      _isolateSegments.putIfAbsent(isolate, () {
        final id = '$_connection-${++_incarnation}';
        (capture['segments'] as List<dynamic>).add({
          'id': id,
          'connection': _connection,
          'isolate': isolate,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        });
        return id;
      });

  Future<void> _inspectIsolate(String id) async {
    final service = _service;
    if (service == null || _closed || !_inspecting.add(id)) return;
    _lastProbe[id] = DateTime.now();
    try {
      final info = await service
          .getIsolate(id)
          .timeout(const Duration(seconds: 3));
      if (_closed || service != _service) return;
      final extensions = info.extensionRPCs ?? [];
      final flutter =
          extensions.any((e) => e.startsWith('ext.flutter.')) ||
          _frameIsolates.contains(id);
      if (!flutter) return;
      _telemetry?.inspectIsolate(info);
      if (extensions.contains('ext.flutter.reassemble')) {
        _modes[id] = 'debug';
      } else {
        final ioLibraries = (info.libraries ?? <vm.LibraryRef>[]).where(
          (library) => library.uri == 'dart:io',
        );
        if (ioLibraries.isNotEmpty && ioLibraries.first.id != null) {
          try {
            final value = await service
                .evaluate(id, ioLibraries.first.id!, 'Platform.isAndroid')
                .timeout(const Duration(seconds: 3));
            if (value is vm.InstanceRef && value.kind == 'Bool') {
              _modes[id] = 'debug';
            }
          } on vm.RPCError catch (error) {
            final description = '${error.message} ${error.data}'.toLowerCase();
            if (description.contains('precompiled') ||
                description.contains('aot mode') ||
                description.contains('aot runtime')) {
              _modes[id] = 'profile';
            }
          }
        }
      }
      _updateMode();
      if (options.refreshRateHz == null) {
        try {
          final listing = await service
              .callMethod('_flutter.listViews')
              .timeout(const Duration(seconds: 3));
          final views = (listing.json?['views'] as List? ?? [])
              .whereType<Map>()
              .where(
                (view) =>
                    view['isolate'] is Map &&
                    (view['isolate'] as Map)['id'] == id,
              )
              .toList();
          // The engine requires viewId for this RPC. Avoid assigning a budget
          // to the wrong view when several displays share an isolate.
          if (views.length != 1 || views.single['id'] is! String) return;
          final response = await service
              .callMethod(
                '_flutter.getDisplayRefreshRate',
                args: {'viewId': views.single['id']},
              )
              .timeout(const Duration(seconds: 3));
          final fps = response.json?['fps'];
          if (fps is num && fps.isFinite && fps > 0 && !_closed) {
            final previous = environment['refreshRateHz'];
            if (previous is num && (previous - fps).abs() > 0.5) {
              _gap('Display refresh rate changed during capture.');
            }
            environment['refreshRateHz'] = fps.toDouble();
            environment['refreshRateSource'] = 'runtime';
          }
        } catch (_) {
          /* A missing engine extension leaves the budget unknown. */
        }
      }
    } catch (_) {
      // A disconnected or not-yet-runnable isolate is unknown, never "profile".
    } finally {
      _inspecting.remove(id);
      if (_inspectAgain.remove(id) && !_closed && service == _service) {
        unawaited(_inspectIsolate(id));
      }
    }
  }

  void _updateMode() {
    if (_closed) return;
    final modes = _frameIsolates.map((id) => _modes[id] ?? 'unknown').toList();
    final mode = modes.contains('debug')
        ? 'debug'
        : modes.isNotEmpty && modes.every((m) => m == 'profile')
        ? 'profile'
        : 'unknown';
    environment['buildMode'] = mode;
    environment['buildModeEvidence'] = switch (mode) {
      'debug' => 'Debug service extension or successful runtime evaluation',
      'profile' => 'Flutter frame events and explicit AOT evaluation rejection',
      _ => 'Insufficient runtime evidence',
    };
  }

  Future<void> _disconnect() async {
    await _telemetry?.stop();
    _telemetry = null;
    await _extensions?.cancel();
    await _isolates?.cancel();
    await _service?.dispose();
    await _socketSubscription?.cancel();
    await _socket?.close();
    _extensions = null;
    _isolates = null;
    _service = null;
    _socket = null;
  }

  Future<void> close() async {
    _closed = true;
    await _disconnect();
  }
}

extension on Stopwatch {
  int elapsedMicrosecondsGetter() => elapsedMicroseconds;
}
