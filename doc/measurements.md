# Reading the measurements

## Frame duration is the primary evidence

A Flutter frame has separate UI/build and raster work. Runalong reports each phase in milliseconds, including percentiles and the worst observed value. Do not sum the phases and invert that number to calculate FPS: the rendering pipeline overlaps work.

When refresh-rate evidence exists, a phase budget is `1000 / refreshRateHz` milliseconds. A 60 Hz display has about 16.67 ms per phase; 120 Hz has about 8.33 ms. An over-budget frame is a frame whose build or raster duration exceeds the applicable budget. This is a rendering signal, not a verified count of display frames dropped by the OS compositor.

A build p95 of 18 ms means approximately 95% of observed build durations are at or below that value, subject to the report's percentile convention. It does not describe frames that were never captured.

## Cadence is not presentation FPS

Flutter renders on demand. A screen that is idle between two frames is not running badly at a low FPS. The report labels its cadence estimates accordingly. It does not measure when the display physically presented a frame or replace native compositor tracing.

## Coverage is part of the result

Read capture status before reading the graph. Missing startup, disconnection, truncated buffers, and zero-frame captures limit conclusions. Reports preserve unavailable measurements rather than replacing them with zero.

Navigation events arrive asynchronously and do not provide authoritative test action boundaries. Route hints are useful for investigation, but a spike beside a navigation label is not proof that the route caused the spike.

## Comparable runs

Use the same device, build mode, workload, refresh-rate conditions, data, and thermal state. Distinguish cold and warm runs. A physical device is needed before drawing conclusions about its mobile users; desktop fixture runs validate the collector, not Android/iOS performance.

Choose a repeatable workload and inspect repeated runs before choosing thresholds. Keep those thresholds under review rather than asking AI to pick a passing number.

Runalong itself has collection overhead. The included fixture-only reference helps verify sample fidelity, not zero overhead. Measure overhead separately before using very tight budgets.

## Evidence and explanation

The report leads with deterministic findings computed from the recorded phases. It groups nearby over-budget samples separately by phase, segment, and isolate, and links every finding to its supporting frames. The displayed relative times start at the first captured frame in that segment/isolate. They are not app-launch timestamps or automatic action labels. See [report findings](report-findings.md).

AI may identify unusual windows, compare distributions, and suggest a follow-up experiment. Frame timings alone do not identify the offending Dart function. A code-level diagnosis needs corroborating source, CPU traces, or a controlled change.

[Flutter performance guidance](https://docs.flutter.dev/perf/ui-performance) · [FrameTiming API](https://api.flutter.dev/flutter/dart-ui/FrameTiming-class.html)
