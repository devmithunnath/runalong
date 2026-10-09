# Runalong

**Flutter performance reports, alongside your existing tests.**

Record Flutter rendering performance while your existing UI automation runs. Keep your test source files unchanged.

Runalong is a **host-side Dart CLI**. It connects to the running app's Dart VM Service, listens to Flutter frame events, and writes an offline report. Your runner still performs the taps, gestures, assertions, and cleanup.

This first release is a local development tool. It has not been published to pub.dev. Physical Android/iOS device validation and individual automation-runner certification are pending; see [validation status](doc/validation.md).

The chosen package and command name is `runalong`, with `ral` as an optional short command alias. Publishing availability remains unconfirmed.

## Start locally

Requires Dart 3.11 or later and a Flutter mobile/desktop **profile build** exposing a reachable VM Service.

```sh
dart pub get
dart pub global activate --source path .
runalong doctor
runalong init
```

Use `runalong` throughout these examples; `ral` accepts the same commands. Ensure your Dart pub-cache executable directory is on PATH. Alternatively run `dart run bin/runalong.dart` from this checkout.

If the app is already running, copy its VM Service URL from Flutter's output:

```sh
runalong run \
  --vm-service-uri 'http://127.0.0.1:12345/auth-token=/' \
  --environment local-phone \
  --workload catalogue \
  --output artifacts/catalogue \
  -- maestro test .maestro/catalogue.yaml
```

The URL above is an example; use the endpoint for your own running app. Runalong subscribes before starting the command when an endpoint is supplied. The automation should use that same app process. If a runner restarts the app, its service endpoint may change.

When your runner launches Flutter and prints a VM Service URL, Runalong can discover it:

```sh
runalong run --connect-timeout 180 --timeout 300 \
  --output artifacts/catalogue \
  -- flutter drive --profile --no-dds \
     --driver=test_driver/integration_test.dart \
     --target=integration_test/catalogue_test.dart \
     -d DEVICE_ID
```

This mode can miss activity before attachment. Its report records incomplete coverage; it cannot establish a passing performance gate for the whole test.

A command can also supply its endpoint through `--vm-service-uri-file PATH`. See [runner setup](doc/runners.md) for endpoint discovery, restarts, and separate-process automation.

## What you get

Each capture gets a unique run directory under `--output` (default: `.runalong/runs`). The CLI prints its exact path. That run directory contains:

- `report.html`: a self-contained interactive frame timeline.
- `report.json`: machine-readable measurements and capture metadata.
- `summary.md`: a short CI-friendly result.
- `events.jsonl` and `manifest.json`: raw capture evidence and run metadata.

The report separates **automation status**, **capture status**, and **performance budget status**. A passing functional test is not a passing performance test.

Measurements include build/raster duration distributions, over-budget frames when a refresh rate is known, and frame cadence where the samples support it. Frame cadence is not confirmed display-presentation FPS. Idle periods are not evidence of jank.

Flutter navigation events are included as approximate hints when available. They cannot identify every tap, tab, or business action. This release does not claim automatic per-action segmentation or provide runner-specific action adapters.

## Existing runners

Runalong accepts an executable and argument list after `--`. Its collector does not depend on the automation package: Flutter integration tests, Patrol, Maestro, Appium, and a custom executable can all be placed behind that boundary.

**A generic process boundary is not a guarantee that every runner configuration works.** The target app must expose a reachable VM Service and run a real engine on a device/desktop. Plain widget tests and release-only apps are outside this capture backend. Runner-owned startup and process restarts need coverage checks. Read [compatibility and setup](doc/runners.md).

## Reports, comparisons, and CI

```sh
runalong report artifacts/catalogue/RUN_ID
runalong compare artifacts/baseline/BASELINE_RUN_ID artifacts/candidate/CANDIDATE_RUN_ID
runalong run --profile smoke
```

Budgets are explicit and opt-in. Runalong does not invent thresholds or replace baselines. A profile example and the full configuration are in [configuration](doc/configuration.md). Read [measurement rules](doc/measurements.md) before treating a comparison as a regression.

## AI access

```sh
runalong mcp --project /absolute/path/to/your/flutter/project
```

The local stdio MCP server exposes configured profiles and captured reports. It does not accept arbitrary AI-supplied shell commands. Review the project's `runalong.yaml` profiles before exposing them to an assistant. See [MCP setup](doc/mcp.md) and the optional [Runalong skill](skills/runalong/SKILL.md).

## Try the fixture

[The fixture](example/fixture/README.md) contains a normal integration-test journey, an external Maestro flow, and a deliberate CPU-jank switch. Its test has no Runalong imports, wrappers, or dependency. An optional fixture-only reference capture supports independent validation.

[Troubleshooting](doc/troubleshooting.md) · [CI adoption](doc/ci.md) · [Release policy](doc/releasing.md)

[Architecture](doc/architecture.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)
