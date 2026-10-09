import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A protocol-level fixture: no Flutter or production collector internals imported.
final class FakeVm {
  FakeVm._(this._server, {required this.mode, required this.refreshRate});
  final HttpServer _server;
  final String mode;
  final double? refreshRate;
  final List<WebSocket> sockets = [];
  final Set<String> subscriptions = {};
  final List<String> methods = [];
  final Completer<void> _ready = Completer<void>();
  Future<void> get ready => _ready.future;
  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/fake-secret/ws');

  static Future<FakeVm> start({
    String mode = 'profile',
    double? refreshRate = 60,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeVm._(server, mode: mode, refreshRate: refreshRate);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      fake.sockets.add(socket);
      socket.listen(
        (dynamic raw) => fake._request(
          socket,
          jsonDecode(raw as String) as Map<String, dynamic>,
        ),
      );
    });
    return fake;
  }

  static Map<String, dynamic> get isolate => {
    'type': '@Isolate',
    'id': 'isolates/1',
    'name': 'main',
    'number': '1',
    'isSystemIsolate': false,
  };

  void _request(WebSocket socket, Map<String, dynamic> message) {
    final method = message['method'] as String;
    methods.add(method);
    final parameters = message['params'] as Map? ?? {};
    Object? response;
    Map<String, dynamic>? error;
    switch (method) {
      case 'streamListen':
        subscriptions.add(parameters['streamId'] as String);
        response = {'type': 'Success'};
      case 'streamCancel':
        response = {'type': 'Success'};
      case 'getVM':
        response = {
          'type': 'VM',
          'name': 'vm',
          'architectureBits': 64,
          'hostCPU': 'arm64',
          'operatingSystem': 'android',
          'targetCPU': 'arm64',
          'version': '3.11.4 fixture',
          'pid': 123,
          'startTime': 0,
          'isolates': [isolate],
        };
      case 'getIsolate':
        response = {
          ...isolate,
          'type': 'Isolate',
          'startTime': 0,
          'runnable': true,
          'livePorts': 1,
          'pauseOnExit': false,
          'pauseEvent': {'type': 'Event', 'kind': 'Resume', 'timestamp': 0},
          'extensionRPCs': [
            'ext.flutter.platformOverride',
            if (mode == 'debug') 'ext.flutter.reassemble',
          ],
          'libraries': [
            {
              'type': '@Library',
              'id': 'libraries/1',
              'name': 'dart.io',
              'uri': 'dart:io',
            },
          ],
        };
      case 'evaluate':
        if (mode == 'debug') {
          response = {
            'type': '@Instance',
            'kind': 'Bool',
            'id': 'objects/true',
            'valueAsString': 'true',
          };
        } else {
          error = {
            'code': 100,
            'message': mode == 'profile'
                ? 'Cannot evaluate in a precompiled runtime'
                : 'No compilation service available',
          };
        }
      case '_flutter.listViews':
        response = {
          'type': 'FlutterViewList',
          'views': [
            {
              'type': 'FlutterView',
              'id': '_flutterView/123',
              'isolate': isolate,
            },
          ],
        };
      case '_flutter.getDisplayRefreshRate':
        if (parameters['viewId'] != '_flutterView/123') {
          error = {'code': -32000, 'message': 'Missing viewId'};
        }
        response = {
          'type': 'DisplayRefreshRate',
          if (refreshRate != null) 'fps': refreshRate,
        };
        if (!_ready.isCompleted) _ready.complete();
      default:
        error = {'code': -32601, 'message': 'Method not found'};
    }
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': message['id'],
        if (error != null) 'error': error else 'result': response,
      }),
    );
  }

  void frame({
    int number = 1,
    int start = 100000,
    int build = 2000,
    int raster = 3000,
    String isolateId = 'isolates/1',
    Object? invalidBuild,
  }) {
    event('Flutter.Frame', {
      'number': number,
      'startTime': start,
      'build': invalidBuild ?? build,
      'raster': raster,
      'elapsed': build + raster + 100,
      'vsyncOverhead': 100,
    }, isolateId: isolateId);
  }

  void event(
    String kind,
    Map<String, dynamic> data, {
    String isolateId = 'isolates/1',
  }) {
    notify('Extension', {
      'kind': 'Extension',
      'extensionKind': kind,
      'extensionData': data,
      'isolate': {...isolate, 'id': isolateId},
    });
  }

  void notify(String stream, Map<String, dynamic> event) {
    for (final socket in sockets.where((s) => s.readyState == WebSocket.open)) {
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'streamNotify',
          'params': {
            'streamId': stream,
            'event': {
              'type': 'Event',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              ...event,
            },
          },
        }),
      );
    }
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
