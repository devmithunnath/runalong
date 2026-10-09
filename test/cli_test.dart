import 'dart:convert';
import 'dart:io';

import 'package:runalong/src/cli.dart';
import 'package:runalong/src/model.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _devices = [
  {
    'id': 'phone-1',
    'name': 'Fixture phone',
    'targetPlatform': 'android-arm64',
    'emulator': false,
    'isSupported': true,
  },
  {
    'id': 'simulator-1',
    'name': 'Fixture simulator',
    'targetPlatform': 'ios',
    'emulator': true,
    'isSupported': true,
  },
];

void main() {
  test(
    'device selection requires an exact unique ID and reports physical status',
    () {
      final selected = selectedDeviceCheck(_devices, 'phone-1');
      expect(selected['status'], 'ok');
      expect(selected['device']['physical'], isTrue);
      expect(
        selectedDeviceCheck(_devices, 'simulator-1')['device']['physical'],
        isFalse,
      );
      expect(selectedDeviceCheck(_devices, 'phone')['status'], 'error');
      expect(
        selectedDeviceCheck([..._devices, _devices.first], 'phone-1')['status'],
        'error',
      );
      expect(selectedDeviceCheck([], 'phone-1')['status'], 'error');
    },
  );

  test(
    'discovery failure is distinct from an unsupported or missing device',
    () {
      expect(selectedDeviceCheck(null, 'phone-1')['status'], 'unavailable');
      expect(
        selectedDeviceCheck({'error': 'bad'}, 'phone-1')['status'],
        'unavailable',
      );
      expect(
        selectedDeviceCheck([<String, dynamic>{}], 'phone-1')['status'],
        'unavailable',
      );
      expect(
        selectedDeviceCheck([
          {..._devices.first, 'isSupported': false},
        ], 'phone-1')['status'],
        'error',
      );
    },
  );

  test(
    'doctor uses the explicit device ID and returns failure for a missing device',
    () async {
      final project = await Directory.systemTemp.createTemp('runalong-doctor-');
      addTearDown(() => project.delete(recursive: true));
      final launcher = File(
        p.join(project.path, Platform.isWindows ? 'flutter.bat' : 'flutter'),
      );
      final listing = jsonEncode(_devices);
      final log = p.join(project.path, 'invocations.txt');
      if (Platform.isWindows) {
        await launcher.writeAsString('''@echo off
echo %*>> "$log"
if "%~1"=="devices" (
  echo $listing
) else (
  echo {"frameworkVersion":"fixture"}
)
''');
      } else {
        final quotedLog = "'${log.replaceAll("'", "'\\''")}'";
        await launcher.writeAsString('''#!/bin/sh
printf '%s\\n' "\$*" >> $quotedLog
if [ "\$1" = devices ]; then
  printf '%s\\n' '$listing'
else
  printf '%s\\n' '{"frameworkVersion":"fixture"}'
fi
''');
        final chmod = await Process.run('chmod', ['+x', launcher.path]);
        expect(chmod.exitCode, 0);
      }
      final pathKey = Platform.environment.keys.firstWhere(
        (key) => key.toUpperCase() == 'PATH',
        orElse: () => 'PATH',
      );
      final separator = Platform.isWindows ? ';' : ':';
      final environment = {
        pathKey:
            '${project.path}$separator${Platform.environment[pathKey] ?? ''}',
      };
      final executable = p.absolute('bin/runalong.dart');
      for (final id in ['phone-1', 'missing']) {
        final result = await Process.run(Platform.resolvedExecutable, [
          executable,
          'doctor',
          '--json',
          '--project',
          project.path,
          '--device-id',
          id,
        ], environment: environment).timeout(const Duration(seconds: 20));
        expect(
          result.exitCode,
          id == 'phone-1' ? 0 : RunalongExit.capture,
          reason: result.stderr as String,
        );
        final output = jsonDecode(result.stdout as String) as JsonMap;
        final check = (output['checks'] as List).cast<JsonMap>().singleWhere(
          (check) => check['name'] == 'Selected device',
        );
        expect(check['status'], id == 'phone-1' ? 'ok' : 'error');
      }
      final invocations = await File(log).readAsLines();
      expect(
        invocations.where((line) => line.trim() == 'devices --machine'),
        hasLength(2),
      );
    },
  );
}
