# Architecture

For a step-by-step explanation with definitions and examples, read [How Runalong works, in plain English](how-runalong-works.md).

```text
Existing test command ────────> Flutter profile app
         │                            │
    exit status                 VM Service events
         │                            │
         └──────── Runalong ─────────┘
                       │
                evidence + report
                       │
              CLI / CI / local MCP
```

The collector lives in the host process. No production app package, custom Flutter binding, or test wrapper is required.

## Why the recorder is external

**Performance reporting can be added to the development workflow without integrating a recorder into the app.** Flutter supplies its existing frame events through the VM Service; the automation runner keeps control of interactions and assertions.

This separation lets teams install and upgrade Runalong independently, reuse the collector across different runner commands, and keep aggregation, report generation, comparisons, and MCP processing on the host. Evidence already written to the host can remain available when the target app exits or crashes. A team can standardize its tooling across projects while maintaining project-specific workloads and budgets.

This is an integration and maintenance advantage, not an inherent accuracy advantage over in-app frame timing collection. The VM connection still adds work, can disconnect, and can miss frames before attachment. Profile-mode launch setup may need changes. The VM backend cannot observe release builds. Optional app context supplies explicit business-operation markers; the recorder alone cannot infer them. See the [plain-English comparison](how-runalong-works.md#why-choose-an-external-recorder) for the benefits and trade-offs.

## Run lifecycle

1. Read CLI options or a reviewed named profile.
2. If supplied, connect to the VM Service endpoint before starting automation. Otherwise start automation and look for its service endpoint.
3. Subscribe to Flutter extension events and preserve valid frame samples with their engine timestamps.
4. Record the automation result independently from capture coverage.
5. Close subscriptions, allow buffered frame delivery within the capture policy, and write the report.
6. Apply only explicitly configured budgets and compatible baseline comparisons.

Attaching late, losing the service connection, truncating capture, missing metrics, and unknown build mode cannot be converted into a clean performance pass.

## Capture backend

Flutter publishes `Flutter.Frame` in non-release builds. It contains frame number, build-start timestamp, build/raster duration, total span, and vsync overhead. `Flutter.Navigation` may supply route names. The collector uses these existing events rather than injecting Dart code or modifying application state.

Host receive time is not engine frame time. Navigation hints are deliberately separate from precise action boundaries. The collector also avoids treating route arguments as report content.

Measurement mode records frames, supported coarse timelines, one memory snapshot per second and GC notifications. Diagnostic mode polls at 500 ms and adds sampled Dart CPU stacks and supported widget/layout/paint tracing. It records and conditionally restores its setting changes, preserves existing timeline streams and never clears shared buffers. Native presentation timestamps, screenshots, network payloads and heap snapshots are not collected.

`telemetry_collector.dart` owns capability probes and bounded collection. `runner_events.dart` accepts reporter boundaries without persisting logs. `journey.dart` calibrates clocks and builds intervals and evidence. `source_resolver.dart` indexes local declaration candidates after capture. The offline UI and MCP consume that same versioned report.

## Extension points

The executable-and-arguments boundary is the stable automation interface. The Dart JSON reporter adapter supplies test boundaries; a structured JSONL input accepts named steps from other adapters without changing the performance backend. Native Android/iOS collectors could support release builds, but are not implemented here.

An MCP server is an interface to this same local machinery. AI can explain captured evidence; it is not responsible for measuring frames or deciding whether absent data means success.

## Sources

- [Flutter scheduler implementation](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/scheduler/binding.dart)
- [Flutter navigation implementation](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/widgets/navigator.dart)
- [Dart VM Service stream API](https://api.flutter.dev/flutter/vm_service/VmService/streamListen.html)
