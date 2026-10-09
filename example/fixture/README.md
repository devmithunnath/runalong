# Performance fixture

A local catalogue app with a three-second animation and a list scroll. The intentional-jank switch adds 35 ms of busy CPU work while an animation frame is built. It is deliberately bad code used only to validate measurement.

The fixture has no dependency on the external recorder. It includes the separate optional `runalong_context` helper, activated only by `--dart-define=RUNALONG_CONTEXT=true`. `integration_test/journey_test.dart` is an ordinary integration test. `reference_test.dart` reuses that journey and exports the fixture's independent frame recorder for validation.

## Prepare

From the repository root, activate the CLI locally:

```sh
dart pub global activate --source path .
cd example/fixture
flutter pub get
```

## Ordinary integration test with external capture

```sh
runalong run --connect-timeout 180 --timeout 300 \
  --environment macos-local --workload catalogue-v1 \
  --output ../../artifacts/fixture-smooth \
  -- flutter drive --profile --no-dds -d macos \
     --driver=test_driver/integration_test.dart \
     --target=integration_test/journey_test.dart
```

Use a real device ID instead of `macos` for mobile work. The profile build and device must support VM Service attachment. Command-output discovery may miss initial frames; inspect the capture warning.

Repeat with a separate output directory and `--dart-define=FIXTURE_JANK=true` appended to the Flutter command to run the same test with intentional jank. Do not interpret the macOS numbers as mobile performance.

## Independent frame reference

Replace the target with `integration_test/reference_test.dart`. The standard integration driver writes its `reportData` to `build/integration_response_data.json`, under `fixtureFrameReference`. Compare this with Runalong frame samples as described in [validation](../../doc/validation.md).

From this directory, compare an actual captured run with the exported reference:

```sh
python3 tool/compare_reference.py \
  ../../artifacts/fixture-smooth/RUN_ID/report.json \
  build/integration_response_data.json
```

The reference recorder exists only in this demonstration app. A real app does not need it.

## External automation with Maestro

On Android/iOS, first run the app in profile mode with `flutter run --profile -d DEVICE_ID`. Leave Flutter running and copy its VM Service URL.

From this directory, in another terminal:

```sh
runalong run --vm-service-uri 'YOUR_VM_SERVICE_URL' \
  --output ../../artifacts/fixture-maestro \
  -- maestro test maestro/catalogue.yaml
```

The flow intentionally does not relaunch the app, so it uses the process the collector attached to. It assumes the home screen is visible. Reset to the home screen before repeating. The flow is supplied for validation; a physical-device Maestro run is pending.

iOS signing is intentionally unconfigured. Choose your own development team locally when deploying to a physical iPhone.

## Minimal external Android runner

With the fixture already running on the selected emulator or device, this ordinary ADB script finds controls by their accessibility labels, opens the catalogue, starts the animation and verifies completion:

```sh
runalong run --capture-mode diagnose --vm-service-uri 'YOUR_VM_SERVICE_URL' \
  --source-root . -- python3 tool/android_journey.py --device DEVICE_ID
```

Keep `adb` on PATH. The script has no Runalong dependency. Launch the app with `--dart-define=RUNALONG_CONTEXT=true` for named context and optionally `--dart-define=FIXTURE_JANK=true` for the deliberate workload. A standalone debug-app Android emulator run is verified; representative performance measurements still require physical-device profile builds.

The fixture-only `ext.fixture.reference` service extension exports its bounded independent timing list for comparison without embedding validation instrumentation in real apps.
