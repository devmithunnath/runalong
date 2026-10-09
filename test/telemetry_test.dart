import 'dart:async';
import 'dart:convert';

import 'package:runalong/src/model.dart';
import 'package:runalong/src/telemetry_collector.dart';
import 'package:runalong/src/telemetry_data.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

void main() {
  test('complete engine frame links survive malformed nested detail trees', () {
    final records = <JsonMap>[];
    final parser = TimelineEvidence(
      diagnostic: true,
      onRecord: records.add,
      resolveFrame: (number, _) => (segment: 's', isolate: 'i'),
    );
    parser.add([
      {
        'name': 'Animator::BeginFrame',
        'ph': 'B',
        'ts': 10,
        'tid': 1,
        'args': {'frame_number': 7},
      },
      {'name': 'BUILD', 'ph': 'B', 'ts': 11, 'tid': 1},
      {'name': 'Missing nested event', 'ph': 'E', 'ts': 12, 'tid': 1},
      {'name': 'Animator::BeginFrame', 'ph': 'E', 'ts': 15, 'tid': 1},
      {
        'name': 'Rasterizer::DoDraw',
        'ph': 'B',
        'ts': 17,
        'tid': 2,
        'args': {'frame_number': 7},
      },
      {'name': 'Rasterizer::DoDraw', 'ph': 'E', 'ts': 20, 'tid': 2},
    ]);
    final links = records.where((r) => r['kind'] == 'frame_timeline').toList();
    expect(links, hasLength(2));
    expect(links.map((r) => r['scope']), ['build', 'raster']);
    expect(parser.dropped, greaterThan(0));
  });

  test(
    'Flutter test invariants prevent intrusive widget tracing mutations',
    () async {
      final fixture = _VmFixture()..flutterTest = true;
      final capture = <String, dynamic>{};
      final collector = fixture.collector([], capture, diagnose: true);
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      collector.inspectIsolate(fixture.isolate);
      await collector.ready;
      expect(fixture.extensions.values.every((v) => v == 'false'), isTrue);
      final state = capture['telemetry']['connections'].single;
      expect(
        state['capabilities']['ext.flutter.profileRenderObjectLayouts'],
        'unavailable-test-invariants',
      );
      expect(state['capabilities']['cpu'], 'available');
    },
  );

  test(
    'CPU retains only referenced functions, including IDs beyond historical cap',
    () async {
      final fixture = _VmFixture()..historicalFunctions = true;
      final records = <JsonMap>[];
      final collector = fixture.collector(records, {}, diagnose: true);
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      collector.inspectIsolate(fixture.isolate);
      await collector.ready;
      await collector.poll();
      final cpu = records.singleWhere((r) => r['kind'] == 'cpu');
      expect(cpu['functions'], hasLength(1));
      expect(cpu['functions'][0]['name'], 'LoginPanel.build');
      expect(cpu['samples'][0]['stack'], [0]);
      expect(jsonEncode(cpu).length, lessThan(1000));
    },
  );

  test(
    'diagnostic CPU records sampled stacks and runtime source coordinates',
    () async {
      final fixture = _VmFixture();
      final records = <JsonMap>[];
      final collector = fixture.collector(records, {}, diagnose: true);
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      collector.inspectIsolate(fixture.isolate);
      await collector.ready;
      await collector.poll();
      final cpu = records.where((r) => r['kind'] == 'cpu').single;
      expect(cpu['samples'], hasLength(1));
      expect((cpu['functions'] as List).single, {
        'name': 'LoginPanel.build',
        'uri': 'package:app/login.dart',
        'line': 45,
        'column': 3,
        'provenance': 'runtime',
      });
      expect(cpu.containsKey('cpuPercent'), isFalse);
    },
  );

  test(
    'duplicate frame IDs across isolates are not resolved using unrelated clocks',
    () async {
      final fixture = _VmFixture();
      final records = <JsonMap>[];
      final collector = fixture.collector(records, {});
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      collector.frame(frame());
      collector.frame(
        FrameSample.fromJson({
          ...frame().toJson(),
          'segment': '1-2',
          'isolate': 'isolates/2',
          'startTimeMicros': 90000000,
        }),
      );
      await collector.poll();
      expect(records.where((r) => r['kind'] == 'frame_timeline'), isEmpty);
    },
  );

  test('an accepted setting with a lost RPC reply is still restored', () async {
    final fixture = _VmFixture()..loseNextTimelineWrite = true;
    final capture = <String, dynamic>{};
    final collector = fixture.collector([], capture, diagnose: true);
    addTearDown(fixture.close);
    await collector.start();
    expect(fixture.streams, contains('Dart'));
    await collector.stop();
    expect(fixture.streams, ['Compiler']);
    final state =
        ((capture['telemetry'] as Map)['connections'] as List).single as Map;
    expect(
      (state['restoration'] as List).whereType<Map>().singleWhere(
        (s) => s['setting'] == 'timelineStreams',
      )['status'],
      'restored',
    );
  });

  test(
    'context is allowlisted, source is relative, unsafe URIs are rejected',
    () {
      final clean = sanitizeContext({
        ...context(),
        'arguments': {'password': 'private'},
        'error': 'private',
        'source': {'uri': '/project/lib/login.dart', 'line': 12, 'column': 2},
      }, sourceRoot: '/project');
      expect(clean!['source'], {
        'uri': 'lib/login.dart',
        'line': 12,
        'column': 2,
        'provenance': 'declared',
      });
      expect(clean.toString(), isNot(contains('private')));
      for (final uri in [
        '../secret.dart',
        'https://host/private',
        'file://host/path',
        'package:app/%2e%2e/secret.dart',
        '/outside/file.dart',
        'lib/a.dart?secret=1',
      ]) {
        expect(
          telemetrySource(
            {'uri': uri},
            sourceRoot: '/project',
            provenance: 'runtime',
          ),
          isNull,
          reason: uri,
        );
      }
      expect(sanitizeContext({...context(), 'vmMicros': -1}), isNull);
      expect(sanitizeContext({...context(), 'event': 'arbitrary'}), isNull);
    },
  );

  test('timeline joins exact engine IDs despite batched/reordered events', () {
    final records = <JsonMap>[];
    var frameSeen = false;
    final parser = TimelineEvidence(
      diagnostic: true,
      onRecord: records.add,
      resolveFrame: (number, _) => frameSeen && number == 7
          ? (segment: '1-1', isolate: 'isolates/1')
          : null,
    );
    final events = traceEvents();
    parser.add(events.reversed);
    expect(records, isEmpty);
    frameSeen = true;
    parser.flush();
    parser.add(events);
    expect(records.where((r) => r['kind'] == 'frame_timeline'), hasLength(1));
    final mapping = records.first;
    expect(mapping['frameNumber'], 7);
    expect(mapping['vmStartMicros'], 1000100);
    expect(mapping['vmEndMicros'], 1070000);
    expect(
      records.where((r) => r['category'] == 'widget').single['name'],
      'LoginPanel',
    );
    expect(records.toString(), isNot(contains('private')));
  });

  test(
    'complete timeline slices retain child phases; unknown frame has no attribution',
    () {
      final records = <JsonMap>[];
      final parser = TimelineEvidence(
        diagnostic: false,
        onRecord: records.add,
        resolveFrame: (number, _) =>
            number == 1 ? (segment: '1-1', isolate: 'main') : null,
      );
      parser.add([
        {
          'ph': 'X',
          'ts': 100,
          'dur': 100,
          'pid': 1,
          'tid': 1,
          'name': 'Animator::BeginFrame',
          'args': {'frame_number': 1},
        },
        {'ph': 'X', 'ts': 110, 'dur': 60, 'pid': 1, 'tid': 1, 'name': 'Build'},
        {
          'ph': 'X',
          'ts': 120,
          'dur': 40,
          'pid': 1,
          'tid': 1,
          'name': 'PrivateWidget',
        },
        {
          'ph': 'X',
          'ts': 500,
          'dur': 100,
          'pid': 1,
          'tid': 1,
          'name': 'Animator::BeginFrame',
          'args': {'frame_number': 2},
        },
        {'ph': 'B', 'ts': 'malformed', 'tid': 1},
      ]);
      expect(records.where((r) => r['name'] == 'Build'), hasLength(1));
      expect(records.where((r) => r['category'] == 'widget'), isEmpty);
      expect(records.every((r) => r['frameNumber'] == 1), isTrue);
    },
  );

  test(
    'measure polls unique memory groups without CPU or runtime flag changes',
    () async {
      final fixture = _VmFixture();
      final records = <JsonMap>[];
      final capture = <String, dynamic>{};
      final collector = fixture.collector(records, capture);
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      collector.inspectIsolate(fixture.isolate);
      collector.frame(frame());
      await collector.poll();
      final memory = records.where((r) => r['kind'] == 'memory').single;
      expect(memory['groups'], hasLength(1));
      expect(memory['rssBytes'], 4096);
      expect(
        fixture.requests.where(
          (r) => r['method'] == 'getIsolateGroupMemoryUsage',
        ),
        hasLength(1),
      );
      expect(memory['uncertaintyMicros'], greaterThanOrEqualTo(0));
      expect(records.where((r) => r['kind'] == 'cpu'), isEmpty);
      expect(
        fixture.requests.any((r) => r['method'] == 'getCpuSamples'),
        isFalse,
      );
      expect(records.where((r) => r['kind'] == 'frame_timeline'), hasLength(1));
      expect(
        fixture.requests.any((r) => (r['method'] as String).startsWith('set')),
        isFalse,
      );
      expect(
        fixture.requests.any(
          (r) => (r['method'] as String).startsWith('clear'),
        ),
        isFalse,
      );
    },
  );

  test(
    'diagnose unions existing streams then restores only owned settings',
    () async {
      final fixture = _VmFixture(profiler: false);
      final records = <JsonMap>[];
      final capture = <String, dynamic>{};
      final collector = fixture.collector(records, capture, diagnose: true);
      addTearDown(fixture.close);
      await collector.start();
      collector.inspectIsolate(fixture.isolate);
      await collector.ready;
      expect(
        fixture.streams,
        containsAll(['Compiler', 'Dart', 'Embedder', 'GC']),
      );
      expect(fixture.profiler, isTrue);
      expect(fixture.extensions['ext.flutter.profileWidgetBuilds'], 'true');
      expect(
        fixture.extensions['ext.flutter.inspector.trackRebuildDirtyWidgets'],
        'true',
      );
      fixture.streams = ['Dart', 'Embedder', 'GC', 'Compiler', 'API'];
      await collector.stop();
      expect(
        fixture.streams,
        contains('API'),
        reason: 'preserve concurrent DevTools settings',
      );
      expect(fixture.profiler, isFalse);
      expect(fixture.extensions['ext.flutter.profileWidgetBuilds'], 'false');
      final state =
          ((capture['telemetry'] as Map)['connections'] as List).single as Map;
      expect(
        (state['restoration'] as List).whereType<Map>().singleWhere(
          (s) => s['setting'] == 'timelineStreams',
        )['status'],
        'conflict-preserved',
      );
      expect(
        fixture.requests.any(
          (r) => (r['method'] as String).startsWith('clear'),
        ),
        isFalse,
      );
    },
  );

  test(
    'late context snapshot deduplicates live start and rebuild locations join frame IDs',
    () async {
      final fixture = _VmFixture();
      final records = <JsonMap>[];
      final collector = fixture.collector(records, {}, diagnose: true);
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      collector.extension(
        vm.Event.parse({
          'type': 'Event',
          'kind': 'Extension',
          'isolate': fixture.isolate.toJson(),
          'extensionKind': 'Runalong.Context',
          'extensionData': context(),
        })!,
      );
      collector.inspectIsolate(fixture.isolate);
      await collector.ready;
      expect(records.where((r) => r['kind'] == 'context'), hasLength(1));
      collector.extension(
        vm.Event.parse({
          'type': 'Event',
          'kind': 'Extension',
          'isolate': fixture.isolate.toJson(),
          'extensionKind': 'Flutter.RebuiltWidgets',
          'extensionData': {
            'frameNumber': 7,
            'locations': {
              'package:app/login.dart': {
                'ids': [1],
                'names': ['LoginPanel'],
                'lines': [45],
                'columns': [3],
              },
            },
            'events': [1, 2],
          },
        })!,
      );
      final rebuilt = records
          .where((r) => r['kind'] == 'widget_rebuild')
          .single;
      expect(rebuilt['frameNumber'], 7);
      expect((rebuilt['widgets'] as List).single, {
        'name': 'LoginPanel',
        'count': 2,
        'source': {
          'uri': 'package:app/login.dart',
          'line': 45,
          'column': 3,
          'provenance': 'runtime_creation',
        },
      });
    },
  );

  test(
    'overlapping polls share one job and unsupported telemetry is recoverable',
    () async {
      final fixture = _VmFixture();
      final collector = fixture.collector([], {});
      addTearDown(fixture.close);
      addTearDown(collector.stop);
      await collector.start();
      final one = collector.poll();
      final two = collector.poll();
      expect(identical(one, two), isTrue);
      await Future.wait([one, two]);
      expect(
        fixture.requests.where(
          (r) => r['method'] == 'getIsolateGroupMemoryUsage',
        ),
        hasLength(1),
      );
    },
  );
}

JsonMap context() => {
  'version': 1,
  'event': 'screen_start',
  'id': 'screen-1',
  'stableId': 'login',
  'label': 'Login',
  'vmMicros': 900000,
};

FrameSample frame() => const FrameSample(
  segment: '1-1',
  isolate: 'isolates/1',
  number: 7,
  startTimeMicros: 1000100,
  buildMicros: 69900,
  rasterMicros: 2000,
  elapsedMicros: 72000,
  vsyncOverheadMicros: 100,
  receivedAt: '2026-10-09T00:00:00Z',
);

List<JsonMap> traceEvents() => [
  {
    'ph': 'B',
    'ts': 1000100,
    'pid': 1,
    'tid': 2,
    'name': 'Animator::BeginFrame',
    'args': {'frame_number': '7', 'private': 'private'},
  },
  {'ph': 'B', 'ts': 1000200, 'pid': 1, 'tid': 2, 'name': 'Build'},
  {'ph': 'B', 'ts': 1000300, 'pid': 1, 'tid': 2, 'name': 'LoginPanel'},
  {'ph': 'E', 'ts': 1069900, 'pid': 1, 'tid': 2, 'name': 'LoginPanel'},
  {'ph': 'E', 'ts': 1069950, 'pid': 1, 'tid': 2, 'name': 'Build'},
  {
    'ph': 'E',
    'ts': 1070000,
    'pid': 1,
    'tid': 2,
    'name': 'Animator::BeginFrame',
  },
];

final class _VmFixture {
  _VmFixture({this.profiler = true}) {
    service = vm.VmService(_responses.stream, (message) {
      final request = jsonDecode(message) as JsonMap;
      requests.add(request);
      scheduleMicrotask(() => _respond(request));
    });
  }
  final _responses = StreamController<String>();
  late final vm.VmService service;
  final requests = <JsonMap>[];
  bool profiler;
  bool loseNextTimelineWrite = false;
  bool historicalFunctions = false;
  bool flutterTest = false;
  var streams = ['Compiler'];
  final extensions = {
    'ext.flutter.profileWidgetBuilds': 'false',
    'ext.flutter.profileRenderObjectLayouts': 'false',
    'ext.flutter.profileRenderObjectPaints': 'false',
    'ext.flutter.inspector.trackRebuildDirtyWidgets': 'false',
  };
  var clock = 900000;
  var host = 0;

  vm.Isolate get isolate => vm.Isolate(
    id: 'isolates/1',
    name: 'main',
    libraries: flutterTest
        ? [
            vm.LibraryRef(
              id: 'test-lib',
              uri: 'package:flutter_test/src/binding.dart',
            ),
          ]
        : [],
    extensionRPCs: [...extensions.keys, 'ext.runalong.context'],
  );

  VmTelemetry collector(
    List<JsonMap> records,
    JsonMap capture, {
    bool diagnose = false,
  }) => VmTelemetry(
    service: service,
    options: RunOptions(
      workingDirectory: '.',
      captureMode: diagnose ? 'diagnose' : 'measure',
      sourceRoot: '/project',
    ),
    capture: capture,
    connection: 1,
    hostMicros: () => host += 100,
    segmentFor: (_) => '1-1',
    onRecord: records.add,
  );

  void _respond(JsonMap request) {
    final method = request['method'];
    final params = request['params'] as Map? ?? {};
    Object? result;
    switch (method) {
      case 'getVMTimelineMicros':
        result = {'type': 'Timestamp', 'timestamp': clock += 100000};
      case 'getVMTimelineFlags':
        result = {
          'type': 'TimelineFlags',
          'recorderName': 'Ring',
          'availableStreams': ['Dart', 'GC', 'Embedder', 'Compiler', 'API'],
          'recordedStreams': streams,
        };
      case 'setVMTimelineFlags':
        streams = (params['recordedStreams'] as List).cast<String>();
        result = {'type': 'Success'};
      case 'getFlagList':
        result = {
          'type': 'FlagList',
          'flags': [
            {'name': 'profiler', 'valueAsString': '$profiler'},
            {'name': 'profile_period', 'valueAsString': '1000'},
          ],
        };
      case 'setFlag':
        profiler = params['value'] == 'true';
        result = {'type': 'Success'};
      case 'streamListen':
      case 'streamCancel':
        result = {'type': 'Success'};
      case 'getVM':
        result = {
          'type': 'VM',
          'isolates': <JsonMap>[],
          'isolateGroups': [
            for (var i = 0; i < 2; i++)
              {
                'type': '@IsolateGroup',
                'id': 'isolateGroups/1',
                'name': 'app',
                'isSystemIsolateGroup': false,
              },
          ],
          '_currentRSS': 4096,
        };
      case 'getIsolateGroupMemoryUsage':
        result = {
          'type': 'MemoryUsage',
          'heapUsage': 1024,
          'heapCapacity': 2048,
          'externalUsage': 256,
        };
      case 'getVMTimeline':
        result = {
          'type': 'Timeline',
          'traceEvents': traceEvents(),
          'timeOriginMicros': 1000000,
          'timeExtentMicros': 100000,
        };
      case 'getCpuSamples':
        result = {
          'type': 'CpuSamples',
          'samplePeriod': 1000,
          'sampleCount': 1,
          'timeOriginMicros': 1000000,
          'timeExtentMicros': 100000,
          'functions': [
            if (historicalFunctions)
              for (var i = 0; i < 10001; i++)
                {
                  'kind': 'Dart',
                  'function': {
                    'type': '@Function',
                    'id': 'old/$i',
                    'name': 'Historical$i',
                  },
                },
            {
              'kind': 'Dart',
              'resolvedUrl': '/project/lib/login.dart',
              'function': {
                'type': '@Function',
                'id': 'functions/1',
                'name': 'LoginPanel.build',
                'location': {
                  'type': 'SourceLocation',
                  'script': {
                    'type': '@Script',
                    'id': 'scripts/1',
                    'uri': 'package:app/login.dart',
                  },
                  'line': 45,
                  'column': 3,
                },
              },
            },
          ],
          'samples': [
            {
              'timestamp': 1050000,
              'tid': 2,
              'stack': [historicalFunctions ? 10001 : 0],
            },
          ],
        };
      case 'ext.runalong.context':
        result = {
          'version': 1,
          'screens': [context()],
          'operations': <JsonMap>[],
        };
      default:
        if (extensions.containsKey(method)) {
          if (params['enabled'] is String) {
            extensions[method as String] = params['enabled'] as String;
          }
          result = {'enabled': extensions[method]};
        }
    }
    if (_responses.isClosed) return;
    if (method == 'setVMTimelineFlags' && loseNextTimelineWrite) {
      loseNextTimelineWrite = false;
      return;
    }
    _responses.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        if (result != null)
          'result': result
        else
          'error': {'code': -32601, 'message': 'Unsupported'},
      }),
    );
  }

  Future<void> close() async {
    await service.dispose();
    await _responses.close();
  }
}
