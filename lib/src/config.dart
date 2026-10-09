import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';

JsonMap _map(dynamic value, String label) {
  if (value == null) return {};
  if (value is! Map) throw FormatException('$label must be a mapping.');
  return {for (final entry in value.entries) entry.key.toString(): entry.value};
}

void _keys(JsonMap map, Set<String> allowed, String label) {
  final unknown = map.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('Unknown $label field: ${unknown.join(', ')}');
  }
}

double? positiveNumber(
  dynamic value,
  String label, {
  bool zeroAllowed = false,
}) {
  if (value == null) return null;
  final n = value is num ? value.toDouble() : double.tryParse(value.toString());
  if (n == null || !n.isFinite || (zeroAllowed ? n < 0 : n <= 0)) {
    throw FormatException(
      '$label must be a ${zeroAllowed ? 'nonnegative' : 'positive'} finite number.',
    );
  }
  return n;
}

Duration? seconds(dynamic value, String label) {
  final n = positiveNumber(value, label);
  return n == null ? null : Duration(microseconds: (n * 1000000).round());
}

/// Normalizes a VM HTTP endpoint to its authenticated WebSocket endpoint.
Uri serviceWebSocketUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['http', 'https', 'ws', 'wss'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException(
      'Use a valid HTTP(S) or WebSocket VM Service URL.',
    );
  }
  var path = uri.path;
  if (!path.endsWith('/ws') && path != 'ws') {
    path = '${path.endsWith('/') ? path : '$path/'}ws';
  }
  return uri.replace(
    scheme: switch (uri.scheme) {
      'http' => 'ws',
      'https' => 'wss',
      _ => uri.scheme,
    },
    path: path,
  );
}

void validateGates(JsonMap gates) {
  _keys(gates, {
    'enabled',
    'buildP95Ms',
    'rasterP95Ms',
    'overBudgetPercent',
    'baseline',
    'regressionPercent',
  }, 'gates');
  if (gates['enabled'] != null && gates['enabled'] is! bool) {
    throw const FormatException('gates.enabled must be true or false.');
  }
  for (final key in [
    'buildP95Ms',
    'rasterP95Ms',
    'overBudgetPercent',
    'regressionPercent',
  ]) {
    final value = positiveNumber(gates[key], key, zeroAllowed: true);
    if (value != null) gates[key] = value;
  }
  if ((gates['overBudgetPercent'] as num? ?? 0) > 100) {
    throw const FormatException('overBudgetPercent cannot exceed 100.');
  }
  if (gates['regressionPercent'] != null && gates['baseline'] == null) {
    throw const FormatException('regressionPercent requires a baseline.');
  }
  if (gates['baseline'] != null && gates['baseline'] is! String) {
    throw const FormatException('baseline must be a run directory.');
  }
  if (gates['enabled'] == true &&
      ![
        'buildP95Ms',
        'rasterP95Ms',
        'overBudgetPercent',
        'regressionPercent',
      ].any(gates.containsKey)) {
    throw const FormatException(
      'Enable a gate with at least one explicit budget or regression threshold.',
    );
  }
}

/// Reads profiles without evaluating environment expressions or shell commands.
Future<Map<String, RunOptions>> loadProfiles(String projectDirectory) async {
  final file = File(p.join(projectDirectory, 'runalong.yaml'));
  if (!await file.exists()) return {};
  final root = _map(loadYaml(await file.readAsString()), 'configuration');
  _keys(root, {'version', 'profiles'}, 'configuration');
  if (root['version'] != 1) {
    throw const FormatException('runalong.yaml requires version: 1.');
  }
  final profiles = _map(root['profiles'], 'profiles');
  final result = <String, RunOptions>{};
  for (final entry in profiles.entries) {
    final value = _map(entry.value, 'profile ${entry.key}');
    _keys(value, {
      'command',
      'working_directory',
      'vm_service_uri',
      'vm_service_uri_file',
      'device_id',
      'environment',
      'capture',
      'gates',
      'runner_adapter',
      'journey_events_file',
      'source_root',
    }, 'profile ${entry.key}');
    final rawCommand = value['command'];
    if (rawCommand is! List ||
        rawCommand.isEmpty ||
        rawCommand.any((v) => v is! String) ||
        (rawCommand.first as String).isEmpty) {
      throw FormatException(
        'Profile ${entry.key}: command must be a nonempty list of strings.',
      );
    }
    final capture = _map(value['capture'], 'capture');
    _keys(capture, {
      'connect_timeout_seconds',
      'timeout_seconds',
      'duration_seconds',
      'refresh_rate_hz',
      'max_frames',
      'mode',
    }, 'capture');
    final environment = _map(value['environment'], 'environment');
    _keys(environment, {
      'id',
      'workload',
      'physical',
      'model',
      'osVersion',
      'appRevision',
    }, 'environment');
    if (environment['physical'] != null && environment['physical'] is! bool) {
      throw const FormatException(
        'environment.physical must be true or false.',
      );
    }
    for (final key in environment.keys.where((key) => key != 'physical')) {
      if (environment[key] is! String) {
        throw FormatException('environment.$key must be text.');
      }
    }
    final gates = _map(value['gates'], 'gates');
    validateGates(gates);
    if (gates['baseline'] case final String baseline) {
      gates['baseline'] = p.normalize(p.join(projectDirectory, baseline));
    }
    String? string(String key) {
      final item = value[key];
      if (item == null) return null;
      if (item is! String || item.isEmpty) {
        throw FormatException('$key must be nonempty text.');
      }
      return item;
    }

    final rawUri = string('vm_service_uri');
    final rawFile = string('vm_service_uri_file');
    if (rawUri != null && rawFile != null) {
      throw const FormatException('Choose a VM URL or URI file, not both.');
    }
    final maxFrames = capture['max_frames'];
    final captureMode = capture['mode'] ?? 'measure';
    if (!['measure', 'diagnose'].contains(captureMode)) {
      throw const FormatException('capture.mode must be measure or diagnose.');
    }
    final runnerAdapter = string('runner_adapter') ?? 'none';
    if (!['none', 'dart-json'].contains(runnerAdapter)) {
      throw const FormatException('runner_adapter must be none or dart-json.');
    }
    if (maxFrames != null &&
        (maxFrames is! int || maxFrames <= 0 || maxFrames > 1000000)) {
      throw const FormatException(
        'max_frames must be an integer from 1 to 1000000.',
      );
    }
    result[entry.key] = RunOptions(
      command: rawCommand.cast<String>(),
      workingDirectory: p.normalize(
        p.join(projectDirectory, string('working_directory') ?? '.'),
      ),
      vmServiceUri: rawUri == null ? null : serviceWebSocketUri(rawUri),
      vmServiceUriFile: rawFile == null
          ? null
          : p.normalize(p.join(projectDirectory, rawFile)),
      deviceId: string('device_id'),
      environment: environment,
      gates: gates,
      connectTimeout:
          seconds(
            capture['connect_timeout_seconds'],
            'connect_timeout_seconds',
          ) ??
          const Duration(seconds: 30),
      timeout: seconds(capture['timeout_seconds'], 'timeout_seconds'),
      duration: seconds(capture['duration_seconds'], 'duration_seconds'),
      refreshRateHz: positiveNumber(
        capture['refresh_rate_hz'],
        'refresh_rate_hz',
      ),
      maxFrames: maxFrames as int? ?? 200000,
      captureMode: captureMode as String,
      runnerAdapter: runnerAdapter,
      journeyEventsFile: string('journey_events_file') == null
          ? null
          : p.normalize(
              p.join(projectDirectory, string('journey_events_file')!),
            ),
      sourceRoot: string('source_root') == null
          ? null
          : p.normalize(p.join(projectDirectory, string('source_root')!)),
    );
  }
  return result;
}

const configurationTemplate =
    '''# Runalong keeps test sources unchanged. Start a Flutter profile build first.
# Paths below are relative to this file. Commands are argument lists, not shell scripts.
version: 1
profiles:
  smoke:
    command: [maestro, test, .maestro/smoke.yaml]
    vm_service_uri_file: .runalong/vm-service.txt
    environment:
      id: development-phone
      workload: smoke
      # Set physical: true only when using a physical device.
    capture:
      mode: measure # diagnose adds CPU and widget traces; timings are instrumented.
      connect_timeout_seconds: 30
      timeout_seconds: 300
    gates:
      enabled: false
      # buildP95Ms: 12
      # rasterP95Ms: 12
# For runner-owned launches, omit vm_service_uri_file and use a command that
# prints Flutter's VM Service URL. The report will flag missed startup coverage.
''';
