import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:runalong_fixture/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('catalogue animation and scroll', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-catalogue')));
    await tester.pumpAndSettle();
    expect(find.text('Catalogue'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-animation')));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.text('Animation complete'), findsOneWidget);
    await tester.fling(
      find.byKey(const ValueKey('catalogue-list')),
      const Offset(0, -600),
      1500,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalogue-list')), findsOneWidget);
  });
}
