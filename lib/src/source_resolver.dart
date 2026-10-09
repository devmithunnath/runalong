import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';

/// Immutable declaration index made after recording, never copied source text.
/// A declaration match remains a candidate, even with a matching git revision.
Future<JsonMap> buildSourceIndex(
  String sourceRoot, {
  String? expectedRevision,
}) async {
  final entries = <JsonMap>[];
  var skipped = 0;
  var truncated = false;
  String? revision;
  String? package;
  var modified = false;
  try {
    final root = await Directory(sourceRoot).resolveSymbolicLinks();
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (await pubspec.exists()) {
      final spec = loadYaml(await pubspec.readAsString());
      if (spec is Map && spec['name'] is String) {
        package = spec['name'] as String;
      }
    }
    try {
      final git = await Process.run('git', [
        '-C',
        root,
        'rev-parse',
        'HEAD',
      ]).timeout(const Duration(seconds: 3));
      final value = '${git.stdout}'.trim();
      final tracked = await Process.run('git', [
        '-C',
        root,
        'ls-files',
        '--error-unmatch',
        'pubspec.yaml',
      ]).timeout(const Duration(seconds: 3));
      if (git.exitCode == 0 &&
          tracked.exitCode == 0 &&
          RegExp(r'^[a-f0-9]{40,64}$').hasMatch(value)) {
        revision = value;
        final status = await Process.run('git', [
          '-C',
          root,
          'status',
          '--porcelain',
          '--',
          'lib',
          'pubspec.yaml',
        ]).timeout(const Duration(seconds: 3));
        modified = status.exitCode != 0 || '${status.stdout}'.trim().isNotEmpty;
      }
    } catch (_) {
      /* A checkout is optional; file hashes remain available. */
    }
    final lib = Directory(p.join(root, 'lib'));
    final files = await lib.exists()
        ? await lib
              .list(recursive: true, followLinks: false)
              .where((e) => e is File && e.path.endsWith('.dart'))
              .cast<File>()
              .toList()
        : <File>[];
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      if (entries.length >= 20000) {
        truncated = true;
        break;
      }
      try {
        if (await file.length() > 1024 * 1024) {
          skipped++;
          continue;
        }
        final resolved = await file.resolveSymbolicLinks();
        if (!p.isWithin(root, resolved)) {
          skipped++;
          continue;
        }
        final content = await file.readAsString();
        final parsed = parseString(content: content, throwIfDiagnostics: false);
        final relative = p.relative(resolved, from: root).replaceAll('\\', '/');
        final uri = package == null
            ? relative
            : 'package:$package/${relative.substring(4)}';
        final fileHash = sha256.convert(utf8.encode(content)).toString();
        void add(String name, int offset) {
          if (entries.length >= 20000) {
            truncated = true;
            return;
          }
          final location = parsed.lineInfo.getLocation(offset);
          entries.add({
            'name': name,
            'uri': uri,
            'path': relative,
            'line': location.lineNumber,
            'column': location.columnNumber,
            'fileHash': fileHash,
            'provenance': 'local_candidate',
          });
        }

        parsed.unit.accept(_Declarations(add));
      } catch (_) {
        skipped++;
      }
    }
  } catch (_) {
    skipped++;
  }
  return {
    'version': 1,
    'revision': revision,
    'expectedRevision': expectedRevision,
    'revisionStatus': expectedRevision == null || revision == null
        ? 'unverified'
        : modified
        ? 'modified'
        : revision == expectedRevision
        ? 'matched'
        : 'mismatch',
    'entries': entries,
    'skippedFiles': skipped,
    'truncated': truncated,
  };
}

final class _Declarations extends RecursiveAstVisitor<void> {
  _Declarations(this.add);
  final void Function(String, int) add;
  String? _class;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final old = _class;
    final token = node.namePart.typeName;
    _class = token.lexeme;
    add(_class!, token.offset);
    super.visitClassDeclaration(node);
    _class = old;
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_class != null) add('$_class.${node.name.lexeme}', node.name.offset);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    add(node.name.lexeme, node.name.offset);
    super.visitFunctionDeclaration(node);
  }
}
