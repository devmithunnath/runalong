import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runalong_context/runalong_context.dart';

void main() {
  final events = <Map<String, Object>>[];
  var clock = 100;
  setUp(() {
    events.clear();
    clock = 100;
    RunalongContext.debugConfigure(
      enabled: true,
      sink: (kind, event) {
        expect(kind, 'Runalong.Context');
        events.add(Map.of(event));
      },
      clock: () => clock++,
    );
  });
  tearDown(RunalongContext.debugConfigure);

  test(
    'disabled by default and disabled calls preserve immediate behavior',
    () async {
      RunalongContext.debugConfigure();
      expect(
        RunalongContext.isEnabled,
        const bool.fromEnvironment('RUNALONG_CONTEXT'),
      );
      RunalongContext.debugConfigure(
        enabled: false,
        sink: (_, event) => events.add(event),
      );
      final future = Future.value(12);
      expect(
        identical(
          RunalongContext.operation(
            stableId: 'same',
            label: 'Same',
            body: () => future,
          ),
          future,
        ),
        isTrue,
      );
      expect(
        RunalongContext.operationSync(
          stableId: 'sync',
          label: 'Sync',
          body: () => 7,
        ),
        7,
      );
      final scope = RunalongContext.startScreen(
        stableId: 'screen',
        label: 'Screen',
      );
      expect(scope.id, isNull);
      scope.end();
      expect(events, isEmpty);
    },
  );

  test(
    'nested async and sync operations retain parent and screen occurrences',
    () async {
      final screen = RunalongContext.startScreen(
        stableId: 'catalogue',
        label: 'Catalogue',
      );
      final result = await screen.run(
        () => RunalongContext.operation<int>(
          stableId: 'load',
          label: 'Load catalogue',
          body: () async {
            await Future<void>.delayed(Duration.zero);
            return RunalongContext.operationSync(
              stableId: 'parse',
              label: 'Parse',
              body: () => 42,
            );
          },
        ),
      );
      screen.end();
      expect(result, 42);
      expect(events.map((e) => e['event']), [
        'screen_start',
        'operation_start',
        'operation_start',
        'operation_end',
        'operation_end',
        'screen_end',
      ]);
      expect(events[2]['parentId'], events[1]['id']);
      expect(events[1]['screenId'], screen.id);
      expect(events[2]['screenId'], screen.id);
      expect(events[4]['id'], events[1]['id']);
      expect(events[4]['status'], 'success');
      expect(events[5]['id'], screen.id);
      expect(
        events.every((e) => e['version'] == 1 && e['vmMicros'] is int),
        isTrue,
      );
    },
  );

  test(
    'overlapping async operations have independent parent context',
    () async {
      final release = Completer<void>();
      final first = RunalongContext.operation<void>(
        stableId: 'first',
        label: 'First',
        body: () async {
          await release.future;
          RunalongContext.operationSync(
            stableId: 'child',
            label: 'Child',
            body: () {},
          );
        },
      );
      await RunalongContext.operation<void>(
        stableId: 'second',
        label: 'Second',
        body: () async {},
      );
      release.complete();
      await first;
      final firstStart = events.first;
      final child = events.firstWhere(
        (e) => e['event'] == 'operation_start' && e['stableId'] == 'child',
      );
      expect(child['parentId'], firstStart['id']);
      expect(events[1].containsKey('parentId'), isFalse);
    },
  );

  test(
    'failures preserve error identity and never emit error payloads',
    () async {
      final error = StateError('private payload');
      final stack = StackTrace.fromString('original stack');
      try {
        await RunalongContext.operation<void>(
          stableId: 'fail',
          label: 'Fail',
          body: () => Future.error(error, stack),
        );
        fail('Operation should throw');
      } catch (caught, trace) {
        expect(identical(caught, error), isTrue);
        expect(trace.toString(), 'original stack');
      }
      expect(events.last['status'], 'error');
      expect(events.toString(), isNot(contains('private payload')));
      expect(
        () => RunalongContext.operationSync<void>(
          stableId: 'sync',
          label: 'Sync',
          body: () => throw error,
        ),
        throwsA(same(error)),
      );
      expect(
        () => RunalongContext.operation<void>(
          stableId: 'immediate',
          label: 'Immediate',
          body: () => throw error,
        ),
        throwsA(same(error)),
      );
    },
  );

  test('transport failure never changes app result or exception', () {
    RunalongContext.debugConfigure(
      enabled: true,
      sink: (_, __) => throw StateError('transport'),
    );
    expect(
      RunalongContext.operationSync(stableId: 'ok', label: 'OK', body: () => 3),
      3,
    );
    final error = ArgumentError('app');
    expect(
      () => RunalongContext.operationSync<void>(
        stableId: 'fail',
        label: 'Fail',
        body: () => throw error,
      ),
      throwsA(same(error)),
    );
  });

  test(
    'late-attach snapshot retains original open IDs and timestamps only',
    () async {
      final screen = RunalongContext.startScreen(
        stableId: 'login',
        label: 'Login',
      );
      final release = Completer<void>();
      final work = RunalongContext.operation<void>(
        stableId: 'load',
        label: 'Load',
        body: () => release.future,
      );
      final snapshot = RunalongContext.debugSnapshot();
      expect(snapshot['version'], 1);
      expect(snapshot['screens'], [events[0]]);
      expect(snapshot['operations'], [events[1]]);
      release.complete();
      await work;
      expect(RunalongContext.debugSnapshot()['operations'], isEmpty);
      screen.end();
      expect(RunalongContext.debugSnapshot()['screens'], isEmpty);
    },
  );

  test(
    'repeated stable IDs have unique occurrences and declared safe sources',
    () {
      for (var i = 0; i < 2; i++) {
        RunalongContext.operationSync(
          stableId: 'load',
          label: 'Load',
          body: () {},
          source: const RunalongSource(
            uri: 'package:example/controller.dart',
            line: 8,
          ),
        );
      }
      expect(events[0]['id'], isNot(events[2]['id']));
      expect(events[0]['stableId'], events[2]['stableId']);
      expect(events[0]['source'], {
        'uri': 'package:example/controller.dart',
        'line': 8,
        'column': 1,
        'provenance': 'declared',
      });
      for (final uri in [
        '/Users/private/file.dart',
        'C:\\private.dart',
        '../file.dart',
        'https://example.com/file.dart',
        'lib/file.dart?secret=value',
      ]) {
        RunalongContext.operationSync(
          stableId: 'bad-source',
          label: 'Bad source',
          body: () {},
          source: RunalongSource(uri: uri, line: 1),
        );
        expect(events.last.containsKey('source'), isFalse);
      }
    },
  );

  test('explicit nested screens end independently and exactly once', () {
    final parent = RunalongContext.startScreen(
      stableId: 'shell',
      label: 'Shell',
    );
    final child = RunalongContext.startScreen(
      stableId: 'tab',
      label: 'Tab',
      parentId: parent.id,
    );
    expect(events[1]['parentId'], parent.id);
    expect(RunalongContext.currentScreenId, child.id);
    child.end();
    child.end();
    expect(RunalongContext.currentScreenId, parent.id);
    parent.end();
    expect(RunalongContext.currentScreenId, isNull);
    expect(events.where((e) => e['event'] == 'screen_end'), hasLength(2));
  });

  test('observer push/pop/replace/remove preserve visible route intervals', () {
    final observer = RunalongNavigatorObserver();
    final home = _route('/home');
    final detail = _route('/detail?token=secret');
    final replacement = _route('/replacement');
    observer.didPush(home, null);
    observer.didPush(detail, home);
    observer.didPop(detail, home);
    observer.didReplace(newRoute: replacement, oldRoute: home);
    observer.didRemove(replacement, null);
    expect(
      events.where((e) => e['event'] == 'screen_start').map((e) => e['label']),
      ['/home', '/detail', '/home', '/replacement'],
    );
    expect(events[4]['id'], isNot(events[0]['id']));
    expect(events.where((e) => e['event'] == 'screen_end'), hasLength(4));
    expect(events.toString(), isNot(contains('secret')));
  });

  test(
    'nested observer has declared parent and unnamed route clears context',
    () {
      final shell = RunalongContext.startScreen(
        stableId: 'shell',
        label: 'Shell',
      );
      final observer = RunalongNavigatorObserver(
        parentScreenId: shell.id,
        routeNameResolver:
            (route) => route.settings.name == 'raw' ? 'Named page' : null,
      );
      final route = _route('raw');
      observer.didPush(route, null);
      observer.didPush(_route(null), route);
      expect(events[1]['label'], 'Named page');
      expect(events[1]['stableId'], 'route:raw');
      expect(events[1]['parentId'], shell.id);
      expect(events.last['label'], 'Unnamed route');
      observer.close();
      shell.end();
    },
  );

  test('metadata resolver failure does not interrupt navigation', () {
    final observer = RunalongNavigatorObserver(
      routeNameResolver: (_) => throw StateError('metadata'),
    );
    observer.didPush(_route('/home'), null);
    expect(events.single['label'], 'Unnamed route');
    observer.close();
  });

  test('friendly labels do not merge distinct route identities', () {
    final observer = RunalongNavigatorObserver(
      routeNameResolver: (_) => 'Home',
    );
    final first = _route('/home');
    observer.didPush(first, null);
    observer.didPush(_route('/alternate-home'), first);
    final starts = events.where((event) => event['event'] == 'screen_start');
    expect(starts.map((event) => event['label']), ['Home', 'Home']);
    expect(starts.map((event) => event['stableId']), [
      'route:/home',
      'route:/alternate-home',
    ]);
    observer.close();
  });
}

Route<void> _route(String? name) => PageRouteBuilder<void>(
  settings: RouteSettings(name: name, arguments: {'never': 'record arguments'}),
  pageBuilder: (_, __, ___) => const SizedBox(),
);
