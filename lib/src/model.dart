import 'dart:async';

typedef JsonMap = Map<String, dynamic>;

/// A validated engine sample. Durations and monotonic timestamps are microseconds.
final class FrameSample {
  const FrameSample({
    required this.segment,
    required this.isolate,
    required this.number,
    required this.startTimeMicros,
    required this.buildMicros,
    required this.rasterMicros,
    required this.elapsedMicros,
    required this.vsyncOverheadMicros,
    required this.receivedAt,
  });

  final String segment;
  final String isolate;
  final int number;
  final int startTimeMicros;
  final int buildMicros;
  final int rasterMicros;
  final int elapsedMicros;
  final int vsyncOverheadMicros;
  final String receivedAt;

  String get identity => '$segment:$isolate:$number:$startTimeMicros';
  int get vsyncStartMicros => startTimeMicros - vsyncOverheadMicros;
  int get rasterFinishMicros => vsyncStartMicros + elapsedMicros;

  JsonMap toJson() => {
    'kind': 'frame',
    'segment': segment,
    'isolate': isolate,
    'number': number,
    'startTimeMicros': startTimeMicros,
    'buildMicros': buildMicros,
    'rasterMicros': rasterMicros,
    'elapsedMicros': elapsedMicros,
    'vsyncOverheadMicros': vsyncOverheadMicros,
    'receivedAt': receivedAt,
  };

  factory FrameSample.fromJson(JsonMap json) {
    int integer(String key) {
      final value = json[key];
      if (value is! int || value < 0) throw FormatException('Invalid $key');
      return value;
    }

    String string(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Invalid $key');
      }
      return value;
    }

    return FrameSample(
      segment: string('segment'),
      isolate: string('isolate'),
      number: integer('number'),
      startTimeMicros: integer('startTimeMicros'),
      buildMicros: integer('buildMicros'),
      rasterMicros: integer('rasterMicros'),
      elapsedMicros: integer('elapsedMicros'),
      vsyncOverheadMicros: integer('vsyncOverheadMicros'),
      receivedAt: string('receivedAt'),
    );
  }
}

/// Host-only capture settings; no Flutter application dependency is required.
final class RunOptions {
  const RunOptions({
    this.command = const [],
    required this.workingDirectory,
    this.outputDirectory,
    this.vmServiceUri,
    this.vmServiceUriFile,
    this.connectTimeout = const Duration(seconds: 30),
    this.timeout,
    this.duration,
    this.flushDuration = const Duration(milliseconds: 350),
    this.refreshRateHz,
    this.deviceId,
    this.environment = const {},
    this.gates = const {},
    this.maxFrames = 200000,
    this.captureMode = 'measure',
    this.runnerAdapter = 'none',
    this.journeyEventsFile,
    this.sourceRoot,
  });

  final List<String> command;
  final String workingDirectory;
  final String? outputDirectory;
  final Uri? vmServiceUri;
  final String? vmServiceUriFile;
  final Duration connectTimeout;
  final Duration? timeout;
  final Duration? duration;
  final Duration flushDuration;
  final double? refreshRateHz;
  final String? deviceId;

  /// id, workload, model, osVersion, physical, appRevision are optional metadata.
  final JsonMap environment;

  /// enabled, buildP95Ms, rasterP95Ms, overBudgetPercent, baseline, regressionPercent.
  final JsonMap gates;
  final int maxFrames;

  /// `diagnose` enables instrumentation and cannot establish a baseline pass.
  final String captureMode;
  final String runnerAdapter;
  final String? journeyEventsFile;
  final String? sourceRoot;

  bool get attachOnly => command.isEmpty;
}

final class CancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class RunProgress {
  const RunProgress(this.id, this.state, this.directory, this.frameCount);
  final String id;
  final String state;
  final String directory;
  final int frameCount;
  JsonMap toJson() => {
    'id': id,
    'state': state,
    'directory': directory,
    'frameCount': frameCount,
  };
}

final class RunResult {
  const RunResult({
    required this.id,
    required this.directory,
    required this.exitCode,
    required this.report,
  });
  final String id;
  final String directory;
  final int exitCode;
  final JsonMap report;
  JsonMap toJson() => {
    'id': id,
    'directory': directory,
    'exitCode': exitCode,
    'report': report,
  };
}

abstract final class RunalongExit {
  static const success = 0;
  static const usage = 2;
  static const capture = 3;
  static const budget = 4;
  static const inconclusive = 5;
  static const report = 6;
  static const timeout = 124;
  static const cancelled = 130;
}
