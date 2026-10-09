import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:runalong_fixture/reference_frames.dart';
import 'journey_test.dart' as journey;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The journey is identical. Only this validation harness exports a reference.
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    binding.reportData = {
      ...?binding.reportData,
      'fixtureFrameReference': FixtureFrameReference.frames,
    };
  });
  journey.main();
}
