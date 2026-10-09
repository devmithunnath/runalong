import 'dart:async';

import 'package:runalong/src/collector.dart';
import 'package:runalong/src/model.dart';
import 'package:test/test.dart';

import 'support/fake_vm.dart';

void main() {
  for (final mode in ['profile', 'debug', 'unknown']) {
    test(
      'runtime evidence identifies $mode without upgrading ambiguous failures',
      () async {
        final fake = await FakeVm.start(mode: mode);
        final capture = <String, dynamic>{
          'gaps': <dynamic>[],
          'segments': <dynamic>[],
          'invalidEvents': 0,
          'droppedEvents': 0,
        };
        final environment = <String, dynamic>{};
        final frames = <JsonMap>[];
        final received = Completer<void>();
        final collector = VmCollector(
          options: const RunOptions(workingDirectory: '.'),
          capture: capture,
          environment: environment,
          onRecord: (frame) {
            frames.add(frame);
            if (!received.isCompleted) received.complete();
          },
        );
        addTearDown(collector.close);
        addTearDown(fake.close);
        await collector.connect(fake.uri);
        fake.frame();
        await received.future.timeout(const Duration(seconds: 2));
        // Event processing completes synchronously before the following microtask.
        await Future<void>.delayed(Duration.zero);
        expect(environment['buildMode'], mode);
        expect(environment['refreshRateHz'], 60);
        expect(frames.single['buildMicros'], 2000);
        expect(fake.methods, isNot(contains('setVMTimelineFlags')));
        expect(fake.methods, isNot(contains('clearVMTimeline')));
      },
    );
  }

  test(
    'deduplicates, rejects malformed frames, caps samples, strips route arguments',
    () async {
      final fake = await FakeVm.start();
      final capture = <String, dynamic>{
        'gaps': <dynamic>[],
        'segments': <dynamic>[],
        'invalidEvents': 0,
        'droppedEvents': 0,
      };
      final records = <JsonMap>[];
      final collector = VmCollector(
        options: const RunOptions(workingDirectory: '.', maxFrames: 2),
        capture: capture,
        environment: {},
        onRecord: records.add,
      );
      addTearDown(collector.close);
      addTearDown(fake.close);
      await collector.connect(fake.uri);
      fake.frame(number: 2, start: 200000);
      fake.frame(number: 2, start: 200000);
      fake.frame(number: 1, start: 100000);
      fake.frame(number: 3, invalidBuild: 'bad');
      fake.frame(number: 4);
      fake.event('Flutter.Navigation', {
        'route': {
          'settings': {
            'name': '/checkout?token=private',
            'arguments': {'secret': 'private'},
          },
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(collector.frameCount, 2);
      expect(capture['invalidEvents'], 1);
      expect(capture['droppedEvents'], 1);
      expect(records.last['routeName'], '/checkout');
      expect(records.toString(), isNot(contains('private')));
    },
  );

  test(
    'restarted isolates do not collide with previous frame identities',
    () async {
      final fake = await FakeVm.start();
      final capture = <String, dynamic>{
        'gaps': <dynamic>[],
        'segments': <dynamic>[],
        'invalidEvents': 0,
        'droppedEvents': 0,
      };
      final records = <JsonMap>[];
      final collector = VmCollector(
        options: const RunOptions(workingDirectory: '.'),
        capture: capture,
        environment: {},
        onRecord: records.add,
      );
      addTearDown(collector.close);
      addTearDown(fake.close);
      await collector.connect(fake.uri);
      fake.frame();
      fake.notify('Isolate', {
        'kind': 'IsolateExit',
        'isolate': FakeVm.isolate,
      });
      fake.frame();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(records.length, 2);
      expect(records.first['segment'], isNot(records.last['segment']));
    },
  );

  test(
    'background worker exit does not mark a healthy capture partial',
    () async {
      final fake = await FakeVm.start();
      final capture = <String, dynamic>{
        'gaps': <dynamic>[],
        'segments': <dynamic>[],
        'invalidEvents': 0,
        'droppedEvents': 0,
      };
      final collector = VmCollector(
        options: const RunOptions(workingDirectory: '.'),
        capture: capture,
        environment: {},
        onRecord: (_) {},
      );
      addTearDown(collector.close);
      addTearDown(fake.close);
      await collector.connect(fake.uri);
      fake.notify('Isolate', {
        'kind': 'IsolateExit',
        'isolate': {...FakeVm.isolate, 'id': 'isolates/worker'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(capture['gaps'], isEmpty);
    },
  );
}
