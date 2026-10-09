# Runalong

**Flutter performance reports, alongside your existing tests.**

**Get Flutter performance reports without adding a recorder to your app.** Run your existing UI tests unchanged.

Runalong is a **host-side Dart CLI**. It connects to the running app's Dart VM Service, listens to Flutter frame events, and writes an offline report. Your runner still performs the taps, gestures, assertions, and cleanup.

New to performance tooling? Read [How Runalong works, in plain English](doc/how-runalong-works.md) for a guided explanation of the connection, measurements, reports, CI, and AI integration, with examples and a glossary.

This first release is a local development tool. It has not been published to pub.dev. Physical Android/iOS device validation and individual automation-runner certification are pending; see [validation status](doc/validation.md).

The chosen package and command name is `runalong`, with `ral` as an optional short command alias. Publishing availability remains unconfirmed.

## Why Runalong runs outside your app

- **No mandatory app integration:** install the CLI on your computer or CI machine. Basic recording needs no app dependency or test wrapper. An optional context helper adds named screens and operations.
- **Keep your automation:** the collector connects to Flutter's VM Service independently of the runner. Reuse existing journeys instead of maintaining separate performance tests.
- **Upgrade independently:** update Runalong's reports, comparisons, and agent integration without changing the app's dependencies or rebuilding it just for those tool updates.
- **Process reports on the host:** aggregation, HTML generation, baseline comparisons, and MCP communication run outside the app being measured.
- **Keep evidence outside the app process:** records already written on the host can remain available after an app crash, with missing coverage clearly marked.

The app must expose a reachable VM Service, and performance gates require a verified profile build. Launch configuration may need adjustment. Service communication still has overhead, and the external approach can miss startup before attachment. Its advantage is easier integration and independent tooling; it does not inherently make Flutter's timing measurements more accurate. Read [the design comparison and trade-offs](doc/how-runalong-works.md#why-choose-an-external-recorder).

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

- `report.html`: a journey view connecting named screens/operations to frames, memory, diagnostic CPU/widget evidence and available source locations.
- `report.json`: machine-readable measurements, capture metadata, and the same structured findings.
- `summary.md`: findings and evidence references for CI.
- `events.jsonl` and `manifest.json`: raw capture evidence and run metadata.

The report separates **automation status**, **capture status**, and **performance budget status**. A passing functional test is not a passing performance test.

Start with “Where to look first,” then use **Show these frames** to inspect a finding or **Copy investigation brief** to share its evidence with a teammate or coding agent. Charts and sample tables are available under **Explore the frame evidence**. These explanations are generated locally after collection and need no AI account. Named screens/operations require the optional context helper; deeper widget and CPU evidence requires an explicitly instrumented diagnosis. See [how to read the findings](doc/report-findings.md).

Measurements include build/raster duration distributions, over-budget frames when a refresh rate is known, and frame cadence where the samples support it. Frame cadence is not confirmed display-presentation FPS. Idle periods are not evidence of jank.

For useful screen and loading labels, use the optional [context helper](packages/runalong_context/README.md) and [journey guide](doc/journey.md). `--runner-adapter dart-json` adds existing Flutter test boundaries. `--capture-mode diagnose` enables deeper instrumented traces. Optional `--source-root` adds local declaration candidates without embedding source code. Unnamed navigation alone remains approximate; Runalong does not invent taps or screen identities.

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
