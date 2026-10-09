# Validation status

This file distinguishes intended compatibility from executed checks. Do not describe unrun device/runner combinations as verified.

The runtime measurements below were collected before the Runalong rename, under the original working name Perfwatch. Raw archived evidence retains its original identifiers; the two verified HTML/Markdown reports were regenerated with Runalong branding without changing the measurement JSON or event data. These results do not claim a new physical-device validation after the rename.

## Included validation material

- A Flutter fixture with a deterministic catalogue journey.
- A smooth default and a deliberate 35 ms build-work variant.
- A normal `integration_test` journey with no Runalong dependency.
- A separate fixture-only reference recorder that exports raw `FrameTiming` values.
- A Maestro flow for external automation against an already-running app.
- CLI/unit test CI configured for Linux, macOS, and Windows; the hosted Linux/Windows workflows were not executed here.
- A macOS profile fixture CI job that preserves reports even when the run fails.

## Executed during development

- Flutter 3.41.6 / Dart 3.11.4: fixture analysis passed.
- Flutter fixture widget test: passed.
- macOS profile integration journey: passed with the test source unchanged (2026-10-09).
- macOS independent reference runs after the refresh-rate lookup fix: the smooth run matched 141/141 frames; the deliberate-jank run matched 94/94 frames. Every overlapping sample matched exactly for build, raster, total span, and vsync overhead.
- Runtime profile-mode detection succeeded. The collector reported partial coverage because it attached after automation started and the runner closed the app's VM connection. No whole-journey performance pass is claimed.
- Runtime refresh-rate discovery returned 60 Hz for both verified runs. An earlier run without refresh-rate evidence correctly left frame-budget metrics unavailable.
- Package verification: 67 Dart tests passed; one Windows-only batch execution test is deferred to the Windows CI host. The Dart analyzer reported no issues.
- The native macOS CLI executable compiled successfully; its version and SDK/configuration doctor checks passed.
- Python standard-library MCP smoke client passed against the actual CLI using protocol version 2025-11-25.
- Initial archive inspection used `tool/check_package.py --allow-missing-repository` while the owner URL was pending. Repository metadata is now configured, and CI uses the strict `tool/check_package.py` check.

## Rename verification

After adopting Runalong, the 67 Dart tests, analyzer, Python MCP smoke client, and fixture analysis/widget test passed again. Both `runalong` and `ral` compiled and reported the same version; the short command generated `runalong.yaml` successfully. The publication dry-run retained only the known owner-URL warning.

## Observed fixture results

These are single-run desktop diagnostics from 2026-10-09, not a mobile baseline, CI gate, or collector-overhead measurement. Both runs used the same catalogue journey, with the fixture’s deliberate 35 ms build work toggled by `FIXTURE_JANK`.

| Measurement | Smooth fixture | Deliberate jank |
| --- | ---: | ---: |
| Captured / reference frames | 141 / 141 | 94 / 94 |
| Exact matching samples | 141 | 94 |
| Build p95 | 1.965 ms | 35.360 ms |
| Raster p95 | 2.719 ms | 3.177 ms |
| Frames over the 60 Hz phase budget | 1 / 141 (0.709%) | 44 / 94 (46.809%) |
| Capture status | Partial | Partial |

The intentional CPU workload appears in build timings as expected. The reports retain incomplete-coverage flags despite exact agreement on captured samples. Each local verified run preserves `fixture_reference.json` and `reference_comparison.json` beside the report, so a later fixture run cannot overwrite its proof.

## Pending

- Physical Android profile capture and reference comparison.
- Physical iOS profile capture and reference comparison: attempted 2026-10-09; blocked before installation by the Apple Developer account requiring acceptance of the updated Program License Agreement and by a missing development provisioning profile for the fixture bundle ID. The account owner must resolve those prerequisites. No agreement or global signing setting was changed.
- End-to-end Patrol, Maestro, and Appium runs on physical devices.
- Quantified collector overhead and sustained thermal behavior.
- Native presentation-time/FPS validation; this release does not collect it.
- Published-package installation; the package is currently installed from this checkout.

The included CI workflow is a validation recipe. Its presence is not evidence that a hosted CI run has occurred.

## Reference comparison procedure

Run `integration_test/reference_test.dart` under the external collector, then join its `fixtureFrameReference` entries with report frames by frame number and build-start timestamp. Compare build, raster, elapsed, and vsync-overhead durations for matching frames.

The collector may attach after the fixture reference has already started. Record that coverage difference explicitly; compare matching frames rather than requiring equal whole-run frame counts. An observed overlap is evidence of measurement fidelity, not full startup coverage.
