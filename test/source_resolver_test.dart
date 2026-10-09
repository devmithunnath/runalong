import 'dart:convert';
import 'dart:io';

import 'package:runalong/src/source_resolver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'source candidates come from declarations, preserve provenance and omit code',
    () async {
      final dir = await Directory.systemTemp.createTemp('runalong-source-');
      addTearDown(() => dir.delete(recursive: true));
      await Directory('${dir.path}/lib').create();
      await File(
        '${dir.path}/pubspec.yaml',
      ).writeAsString('name: sample_app\n');
      await File('${dir.path}/lib/login.dart').writeAsString('''
// class FakeWidget {}
class LoginScreen {
  void load() { print('do-not-copy-source'); }
}
''');
      final index = await buildSourceIndex(dir.path);
      final entries = index['entries'] as List;
      expect(entries.map((dynamic e) => e['name']), [
        'LoginScreen',
        'LoginScreen.load',
      ]);
      expect(entries.first['line'], 2);
      expect(entries.first['uri'], 'package:sample_app/login.dart');
      expect(entries.first['provenance'], 'local_candidate');
      expect(index['revisionStatus'], 'unverified');
      expect(jsonEncode(index), isNot(contains('do-not-copy-source')));
      expect(jsonEncode(index), isNot(contains(dir.path)));
      final again = await buildSourceIndex(dir.path);
      expect(again, index);
    },
  );
}
