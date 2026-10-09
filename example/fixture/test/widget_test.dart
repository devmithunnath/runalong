import 'package:flutter_test/flutter_test.dart';
import 'package:runalong_fixture/main.dart';

void main() {
  testWidgets('opens the named catalogue', (tester) async {
    await tester.pumpWidget(const FixtureApp());
    await tester.tap(find.text('Open catalogue'));
    await tester.pumpAndSettle();
    expect(find.text('Catalogue'), findsOneWidget);
    expect(find.text('Run animation'), findsOneWidget);
  });
}
