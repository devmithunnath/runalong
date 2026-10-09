import 'dart:ui';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/scheduler.dart';

/// Independent validation instrumentation, confined to this fixture app.
/// Real apps do not need this class or a Runalong dependency.
abstract final class FixtureFrameReference {
  static final List<Map<String, int>> frames = [];
  static bool _installed = false;
  static void install() {
    if (_installed) return;
    _installed = true;
    developer.registerExtension('ext.fixture.reference', (_, _) async {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'frames': frames}),
      );
    });
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final frame in timings) {
        frames.add({
          'number': frame.frameNumber,
          'startTimeMicros': frame.timestampInMicroseconds(
            FramePhase.buildStart,
          ),
          'buildMicros': frame.buildDuration.inMicroseconds,
          'rasterMicros': frame.rasterDuration.inMicroseconds,
          'elapsedMicros': frame.totalSpan.inMicroseconds,
          'vsyncOverheadMicros': frame.vsyncOverhead.inMicroseconds,
        });
        if (frames.length > 10000) frames.removeAt(0);
      }
    });
  }
}
