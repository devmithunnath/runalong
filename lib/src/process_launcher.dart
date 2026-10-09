import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves Windows launchers without turning native executable args into shell
/// text. Batch launchers still use cmd.exe and have narrower argument support.
final class CommandLaunch {
  const CommandLaunch(
    this.executable,
    this.arguments, {
    this.runInShell = false,
  });

  final String executable;
  final List<String> arguments;
  final bool runInShell;

  Future<Process> start({String? workingDirectory}) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: runInShell,
  );
}

CommandLaunch prepareCommand(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool? windows,
  Map<String, String>? environment,
  bool Function(String)? fileExists,
}) {
  if (!(windows ?? Platform.isWindows)) {
    return CommandLaunch(executable, arguments);
  }
  final env = environment ?? Platform.environment;
  String? variable(String name) {
    for (final entry in env.entries) {
      if (entry.key.toUpperCase() == name) return entry.value;
    }
    return null;
  }

  final paths = p.Context(
    style: p.Style.windows,
    current: workingDirectory ?? Directory.current.path,
  );
  final exists = fileExists ?? (String path) => File(path).existsSync();
  final extensions = (variable('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
      .split(';')
      .map((value) => value.toLowerCase())
      .where((value) => ['.com', '.exe', '.bat', '.cmd'].contains(value))
      .toList();
  final names = paths.extension(executable).isEmpty
      ? [
          executable,
          for (final extension in extensions) '$executable$extension',
        ]
      : [executable];
  final directories = executable.contains(RegExp(r'[/\\:]'))
      ? ['']
      : [
          paths.current,
          for (final directory in (variable('PATH') ?? '').split(';'))
            if (directory.trim().isNotEmpty)
              directory.trim().replaceAll(RegExp(r'^"|"$'), ''),
        ];
  var resolved = executable;
  search:
  for (final directory in directories) {
    for (final name in names) {
      final candidate = paths.normalize(paths.absolute(directory, name));
      if (exists(candidate)) {
        resolved = candidate;
        break search;
      }
    }
  }
  final batch = [
    '.bat',
    '.cmd',
  ].contains(paths.extension(resolved).toLowerCase());
  if (batch) {
    // cmd.exe can expand or execute these even through Process.start argument
    // lists. Do not silently reinterpret an automation argument as shell code.
    final unsafe = RegExp(r'["\r\n&|<>^%!()]');
    if ([resolved, ...arguments].any(unsafe.hasMatch)) {
      throw const FormatException(
        'Windows batch launchers cannot safely forward shell metacharacters. '
        'Use a native executable or a reviewed launcher with fixed arguments.',
      );
    }
  }
  return CommandLaunch(resolved, arguments, runInShell: batch);
}
