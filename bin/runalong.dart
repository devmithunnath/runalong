import 'dart:io';
import 'package:runalong/src/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
