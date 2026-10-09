import 'dart:async';
import 'dart:io';

import 'package:runalong/src/model.dart';
import 'package:runalong/src/run_service.dart';
import 'package:test/test.dart';

void main() {
  test('unresponsive VM respects the connection deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) {});
    });
    final temp = await Directory.systemTemp.createTemp('runalong-deadline-');
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    final watch = Stopwatch()..start();
    final result = await RunService().run(
      RunOptions(
        workingDirectory: temp.path,
        vmServiceUri: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        connectTimeout: const Duration(milliseconds: 100),
        duration: const Duration(milliseconds: 100),
        flushDuration: Duration.zero,
      ),
    );
    expect(result.exitCode, RunalongExit.capture);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('cancelling during VM negotiation closes the stalled session', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = CancellationToken();
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) {
        token.cancel();
      });
    });
    final temp = await Directory.systemTemp.createTemp('runalong-cancel-');
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    final result = await RunService()
        .run(
          RunOptions(
            workingDirectory: temp.path,
            vmServiceUri: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
          ),
          cancellation: token,
        )
        .timeout(const Duration(seconds: 2));
    expect(result.exitCode, RunalongExit.cancelled);
  });

  test('a timed-out auxiliary probe is stopped', () async {
    final temp = await Directory.systemTemp.createTemp('runalong-probe-');
    addTearDown(() => temp.delete(recursive: true));
    final script = File('${temp.path}/wait.dart');
    await script.writeAsString(
      "import 'dart:async'; void main() { Timer.periodic(const Duration(seconds: 1), (_) {}); }",
    );
    final watch = Stopwatch()..start();
    await expectLater(
      runHostCommand(Platform.resolvedExecutable, [
        script.path,
      ], timeout: const Duration(milliseconds: 150)),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
  });
}
