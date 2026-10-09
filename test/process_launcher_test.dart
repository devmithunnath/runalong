import 'dart:io';

import 'package:runalong/src/process_launcher.dart';
import 'package:test/test.dart';

void main() {
  test('Windows resolves bare Flutter from mixed-case PATH and PATHEXT', () {
    final launch = prepareCommand(
      'flutter',
      ['drive', '--target=integration_test/a test.dart'],
      windows: true,
      workingDirectory: r'C:\project',
      environment: {
        'Path': r'"C:\Flutter SDK\bin"',
        'PathExt': '.EXE;.BAT;.CMD',
      },
      fileExists: (path) => path == r'C:\Flutter SDK\bin\flutter.bat',
    );
    expect(launch.executable, r'C:\Flutter SDK\bin\flutter.bat');
    expect(launch.arguments.last, '--target=integration_test/a test.dart');
    expect(launch.runInShell, isTrue);
  });

  test(
    'native Windows executables retain literal arguments without a shell',
    () {
      final arguments = [
        'space in arg',
        r'$(literal)',
        'a&b',
        '%PATH%',
        'മലയാളം',
      ];
      final launch = prepareCommand(
        'runner',
        arguments,
        windows: true,
        workingDirectory: r'C:\project',
        environment: {'PATH': r'C:\tools'},
        fileExists: (path) => path == r'C:\tools\runner.exe',
      );
      expect(launch.executable, r'C:\tools\runner.exe');
      expect(launch.arguments, arguments);
      expect(launch.runInShell, isFalse);
    },
  );

  test('relative cmd launcher resolves against the automation directory', () {
    final launch = prepareCommand(
      r'tools\journey.cmd',
      ['run'],
      windows: true,
      workingDirectory: r'C:\project',
      environment: {},
      fileExists: (path) => path == r'C:\project\tools\journey.cmd',
    );
    expect(launch.executable, r'C:\project\tools\journey.cmd');
    expect(launch.runInShell, isTrue);
  });

  test('batch arguments which cmd could reinterpret fail before launching', () {
    for (final value in ['x&calc', '%PATH%', '!value!', 'a"b', 'a\nb', '(x)']) {
      expect(
        () => prepareCommand(
          r'C:\tools\runner.cmd',
          [value],
          windows: true,
          workingDirectory: r'C:\project',
          environment: {},
          fileExists: (_) => true,
        ),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test(
    'Windows runs batch file at a path with spaces',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'runalong batch ',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/runner.cmd');
      await script.writeAsString('@echo off\r\necho %~1\r\nexit /b 7\r\n');
      final process = await prepareCommand(script.path, [
        'literal with spaces',
      ]).start();
      final output = await process.stdout.toList();
      await process.stderr.drain<void>();
      expect(await process.exitCode, 7);
      expect(
        String.fromCharCodes(output.expand((chunk) => chunk)),
        contains('literal with spaces'),
      );
    },
    skip: !Platform.isWindows ? 'Runs on the Windows CI host.' : false,
  );
}
