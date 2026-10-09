# Connect a slow frame to your app

Runalong records an automation journey and rendering/resource evidence on a shared timeline. Select a screen visit or named operation to inspect its frames, sampled memory, CPU hotspots and source evidence. An operation's elapsed duration includes waiting for I/O; it is not CPU time or proof that rendering stalled throughout.

## Give the recording recognizable names

The external recorder needs no app dependency. The optional [runalong_context package](../packages/runalong_context/README.md) adds developer-authored screen and loading boundaries. It is disabled unless the app is built with `--dart-define=RUNALONG_CONTEXT=true`, and remains inactive in release builds.

Keep a `RunalongNavigatorObserver` for each Navigator and preserve `RouteSettings` in your page constructors. Use `startScreen` for tabs or custom navigation. Wrap a meaningful operation with `RunalongContext.operation(stableId: 'login.submit', label: 'Submit login', body: ...)`. Reuse the stable ID across runs; the helper assigns unique occurrence IDs. Optional source annotations identify where you placed the wrapper, not the cause of an issue. No test imports or edits are needed.

The read-only context snapshot extension recovers open screens/operations when attachment is late. It cannot recover operations that already ended. The report continues to disclose missed startup and incomplete intervals.

## Run a measurement and a diagnosis

For an existing Flutter integration test on an Android emulator:

```sh
runalong run --capture-mode measure --runner-adapter dart-json \
  --source-root . --connect-timeout 180 --timeout 600 -- \
  flutter test integration_test/app_test.dart -d DEVICE_ID \
  --no-dds --verbose --reporter json --dart-define=RUNALONG_CONTEXT=true
```

Use `--capture-mode diagnose` for a separate investigation with sampled CPU stacks and supported widget/build/layout/paint traces. Launch flags can change while test source stays unchanged. This emulator/debug recipe is diagnostic: use a physical-device profile launch and your existing external runner for representative measurement. See [runner recipes](runners.md).

| Evidence | `measure` | `diagnose` |
| --- | --- | --- |
| Frames, context and available test boundaries | Yes | Yes |
| Heap usage/capacity, external and supported process memory | 1 second polling | 500 ms polling |
| GC markers and supported coarse frame timeline | Yes | Yes |
| Sampled Dart CPU work and detailed widget/layout/paint tracing | Off | On where supported |
| Widget creation locations | Off | Debug-only capability |

When the target loads `flutter_test`, Runalong skips detailed widget/layout/paint toggles: the test framework checks these globals before its completion event, so changing them can fail an otherwise passing test. CPU and memory evidence remain available. Use an independently launched app with an external runner for full tracing.

Diagnostic instrumentation can change timing. Its results cannot establish a normal rendering gate pass. Settings are restored where the connection permits and where another client has not subsequently changed them. The report records capability, coverage and restoration failures. Shared VM buffers are never cleared. Memory samples are observed values, not exact peaks between polls; shared isolate-group heaps are counted once.

CPU windows are retrieved about every two seconds, separately from the 500 ms memory schedule, plus a final tail window. Retrieval does not change the VM's sampling period. Large VM function tables still make diagnostic collection more expensive than measurement. CPU sample shares describe recorded Dart stacks, not whole-app CPU percentage. External memory is native memory accounted for by Dart, not all native/GPU memory. This backend does not claim actual display FPS. Native CPU/FPS, allocation tracing, heap snapshots and retaining-path exploration remain later work.

## Existing test names and external steps

`--runner-adapter dart-json` reads the Dart/Flutter JSON reporter's test names and start/end records; it discards printed messages, errors and input values. It does not infer the taps inside a test. Reporter clocks are aligned to receipt time, so test boundaries remain approximate. App context uses the VM's own monotonic clock.

Other runners can write a fresh, empty JSONL file selected by `--journey-events-file PATH`. A runner adapter or launcher writes a `sync` record followed by named boundaries; the existing test source can remain unchanged:

```json
{"version":1,"event":"sync","timeMicros":0}
{"version":1,"event":"step_start","id":"submit-1","stableId":"login.submit","label":"Submit login","timeMicros":100000}
{"version":1,"event":"step_end","id":"submit-1","stableId":"login.submit","label":"Submit login","timeMicros":800000,"status":"passed"}
```

`timeMicros` is elapsed time on the producer's monotonic clock. Flush complete lines promptly. `test_start`, `test_end`, `step_start` and `step_end` are accepted; `parentId` is optional. IDs must be distinct for each occurrence. Labels/stable IDs should be static, free of user data. Polling and transport leave an unknown delay: these events are receipt-aligned hints, not exact frame-causal labels. Old nonempty input files are rejected to prevent accidental reuse. Recorder compatibility with any runner does not imply a step adapter has been verified for every runner.

## Source evidence and comparisons

Use `--source-root` only with the matching app checkout. After recording, Runalong parses Dart declarations into an immutable index of paths, lines and hashes; it never embeds source bodies. Runtime function/creation locations, declared wrapper locations, and local declaration candidates have separate provenance. A name match can be ambiguous; even a unique declaration is not proof that the code caused the delay. A supplied `environment.appRevision` is compared with the checkout revision. Indexing failure does not erase the capture.

Run comparisons match stable IDs, hierarchy and occurrence rather than elapsed seconds. Unmatched/ambiguous intervals remain visible. Instrumentation mode, sampling settings and capture coverage are part of compatibility. New memory/CPU/operation metrics are descriptive in this preview; existing explicit rendering gates remain separate.

Manifest/report schema 2 adds journey context and resource evidence. Schema 1 recordings still regenerate; missing historical context cannot be invented. All explanations and comparisons remain local and work without an AI account. MCP's `list_journey` and `get_finding_evidence` let an agent investigate the same evidence you see.

### Partial operations and uncertain boundaries

An unfinished operation is clipped to the last observed evidence on its connection, with total duration left unknown. This is useful for functions that await a navigation route closing. Prefer narrower scopes around actual loading work. Approximate test windows can show nearby frames and memory, but cannot pass per-operation gates. Frame attribution requires both build and raster phase envelopes; missing phases remain unaligned.

CPU functions are ranked by self samples, with inclusive share shown separately. The VM specifies a [top-to-bottom sample stack](https://api.flutter.dev/flutter/vm_service/CpuSample-class.html). Function location provenance and candidate revision status remain visible. Memory/CPU and operation-duration differences are descriptive; they do not introduce new CI gates.
