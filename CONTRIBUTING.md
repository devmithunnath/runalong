# Contributing

Use Dart 3.11 or later. The Flutter fixture uses Flutter 3.41.6 in CI.

```sh
dart pub get
dart format --output=none --set-exit-if-changed bin lib test
dart analyze
dart test
python3 tool/mcp_smoke.py
python3 tool/check_package.py
```

For fixture changes, run `flutter pub get`, `flutter analyze`, and `flutter test test/widget_test.dart` from `example/fixture`. Verify runtime changes using a profile build and preserve the resulting capture artifacts.

Test observable behavior: protocol events, partial capture, cancellation, process exit, report regeneration, incompatible baselines, and budget outcomes. Tests that only repeat implementation wording add little confidence.

Keep collector and runner boundaries separate. Do not add imports or wrappers to a user's tests to make generic attachment work. A runner-specific integration should be optional and document how it gets its endpoint and action timestamps.

Never report missing samples as zero, infer a precise business action from a route hint, or label rendered-frame cadence as presentation FPS. Update [validation status](doc/validation.md) only with checks that actually ran.

Before release, review the dry-run archive for capture data, local device identifiers, signing configuration, credentials, and generated build artifacts. Publishing is a separate, explicit action.

See [CI adoption](doc/ci.md), [troubleshooting](doc/troubleshooting.md), and [release requirements](doc/releasing.md). The archive check is strict: resolve every warning before publication and run it from a clean commit.
