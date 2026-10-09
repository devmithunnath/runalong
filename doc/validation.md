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
- Physical-device profile overhead, sustained-load behavior, and thermal behavior. The preliminary emulator/host measurements below do not complete this requirement.
- Native presentation-time/FPS validation; this release does not collect it.
- Published-package installation; the package is currently installed from this checkout.

The included CI workflow is a validation recipe. Its presence is not evidence that a hosted CI run has occurred.

## Commercial Android app pilot

On 2026-10-09, Runalong recorded an existing commercial Flutter application on a dedicated Android 16 / API 36 ARM64 emulator. The application used Flutter 3.29.0 / Dart 3.7.0; the host recorder used Dart 3.11.4. No recorder dependency, timing callback, or test wrapper was added to the application.

| Existing journey | Automation result | Captured frames | Capture |
| --- | --- | ---: | --- |
| Original integration suite | 1 passed, 17 failed | 913 | Partial, debug |
| Owner-reduced two-login suite | 1 passed, 1 failed | 330 | Partial, debug |
| Username login only, selected through the runner's name filter | Passed in each of 3 recorded runs | 209, 204, 204 | Partial, debug |

The two-login suite encountered a disposed-notifier assertion in the app's syncing banner during its second login. A separate run of the same two tests without Runalong reproduced that assertion (1 passed, 1 failed), establishing that the failure occurs independently of the recorder. Failing automation retained exit code 1 while Runalong still produced timing reports. A passing username-login journey was selected for the repeated measurements below; that does not establish that the entire suite passes.

All 56 integration-test source files matched the owner's reduced-suite snapshot after testing. The app's dependency manifest, lockfile, and overrides were unchanged. The private app, isolated SDK, logs, and raw captures remain outside the public repository and package archive.

This pilot exposed and fixed discovery of Flutter 3.29's verbose `test N: VM Service uri is available at ...` message. Discovery uses the forwarded host endpoint and ignores the earlier device-local URL. The new regression test passed along with the package's 68 tests; one Windows-only test was skipped. Analysis of `lib`, `bin`, and `test` found no issues. See the [runner recipe](runners.md#existing-flutter-test-integration-suites).

The 913-frame capture's events, JSON, and embedded HTML data agree. Independently recomputed summaries matched. Offline regeneration of the 330-frame run produced byte-identical JSON, HTML, and Markdown. The runtime reported debug mode and approximately 60 Hz; it also identified the target as an emulator. Startup attachment and runner teardown caused visible coverage gaps. This is real-application capture evidence, not Android profile validation, a presentation-FPS measurement, or a whole-journey performance pass. The app emitted navigation events without route names, so this pilot does not demonstrate named-screen or exact-action attribution.

Some early attempts lost the ADB transport during VM startup, including an attempt without Runalong. Their unavailable-capture results were retained. The six comparison runs below completed after a cold restart with 4 GiB emulator RAM; this sequence does not prove that memory was the cause of the earlier disconnects.

### Preliminary overhead observations

The same username-login test ran in three pairs, ordered control/recorded, recorded/control, control/recorded. The runner flags, emulator, app source, and collector implementation were held constant. Both conditions used verbose output and disabled DDS. Builds and installation are excluded from the runner-reported test durations, but included in total command duration.

| Pair | Test without recorder | Test with recorder | Observed total command difference | Recorded frames |
| --- | ---: | ---: | ---: | ---: |
| 1 | 24 s | 23 s | +2.8 s | 209 |
| 2 | 23 s | 23 s | +3.2 s | 204 |
| 3 | 23 s | 23 s | +3.3 s | 204 |

The median test-time difference was zero at the runner's **one-second resolution**. The median total command difference was approximately +3.2 seconds, including launching Runalong from Dart source and producing its reports. Those total differences also include ordinary build/network variation and cannot isolate pure recorder startup cost.

During the active tests, the recorder PID averaged **1.33–1.44% of one host CPU core** and reached **121–128 MiB resident memory**. These are samples of the external Dart process, taken roughly every half-second, not measurements of app CPU or app memory. Each recorded run produced approximately 190–194 KiB of report/event artifacts. Report-generation peak memory after capture was not measured.

These small, network-dependent debug-emulator trials showed no obvious test slowdown. They do **not** establish zero overhead, a precise slowdown percentage, device-side VM event-delivery cost, or a production-device limit. The shared workstation was not an isolated benchmark host; a local offline-report check also overlapped the end of the first recorded trial. Use profile builds on physical devices and an independent reference workload for release-grade overhead claims. The [release criteria](releasing.md#stable-platform-support) remain unchanged.

## Reference comparison procedure

Run `integration_test/reference_test.dart` under the external collector, then join its `fixtureFrameReference` entries with report frames by frame number and build-start timestamp. Compare build, raster, elapsed, and vsync-overhead durations for matching frames.

The collector may attach after the fixture reference has already started. Record that coverage difference explicitly; compare matching frames rather than requiring equal whole-run frame counts. An observed overlap is evidence of measurement fidelity, not full startup coverage.

## Journey and resource preview validation (2026-10-09)

This extends the earlier frame-only pilot. The private app now has profiling-only context wrappers and a navigator observer from the optional helper; test source remains unchanged. Launch flags enable the helper and JSON reporter. The public package excludes the private app, SDK, captures and logs.

The same username-login journey passed with measurement and diagnostic collection on the Android 16 ARM64 emulator / Flutter 3.29.0. The final measurement retained **209 frames, 201 complete frame-envelope links, 21 memory snapshots and 23 named intervals**. The final diagnostic run retained **205 frames, 204 complete links, 27 memory snapshots and 12 CPU sample windows**. Both are debug/partial captures, not physical-device profile baselines. Recognizable intervals include Login, Verify credentials, Load account data, Home and Developer settings. Some custom routes remain unnamed. The outer login functions await route completion; their missing end events remain explicitly unfinished while narrower loading operations finish normally.

An early diagnostic run exposed Flutter test-framework invariant failures when enhanced tracing variables stayed enabled at test teardown. Runalong now detects the loaded test framework and leaves those toggles unchanged. CPU, memory and coarse phase evidence remain available. Separate real-app runs verified that the unchanged test passes with this guard. A prior cancelled run and the failed run retain partial artifacts and their original exit status; they are not counted as successful performance trials.

### Preliminary resource-mode overhead

One recorder-off control and one final run per mode used the same helper-enabled app, JSON reporter, username-login workload and emulator. Test durations use the reporter's millisecond clock. These are shared-workstation, network-dependent spot checks, not statistically reliable device-overhead bounds. They measure the incremental recorder configuration; they do not isolate the helper's cost. UI review and ordinary host activity were not suppressed.

| Condition | Test duration | Total command duration | Recorder host CPU, mean of one core | Recorder sampled peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Recorder off | 22.184 s | 46.874 s | — | — |
| Measure | 22.724 s | 55.987 s | 3.85% | 434.8 MiB |
| Diagnose | 27.354 s | 61.468 s | 32.67% | 743.1 MiB |

Host CPU/RSS samples cover the active test, not app CPU or app memory. Source indexing/report generation occurs afterward and is included only in total command time. Launching from Dart source also contributes startup cost. The richer measurement collector costs more on the host than the earlier frame-only recorder. Diagnosis is materially more expensive and must remain opt-in; neither these numbers nor a single small measurement-mode time difference justify a zero-overhead claim.

The initial diagnostic implementation repeatedly serialized the VM's historical function table. It now stores only referenced functions per window and retrieves CPU windows about every two seconds while retaining the VM's original sampling period. Buffer/truncation and missing-window information remain in the report.

### Independent standalone Android fixture

The public fixture ran as an independently launched Flutter 3.41.6 debug app on the same emulator. The external ADB journey opened the catalogue and ran its deliberate 35 ms build workload. Automation passed and capture completed. **All 74 captured frames matched the fixture's independent `FrameTiming` recorder exactly** across build, raster, total span and vsync overhead; the reference had 75 frames because it started earlier.

All 74 captured frames had complete build/raster timeline links. Diagnostic evidence included **2,127 CPU samples, 90 widget trace events and 65 rebuild batches**. Runtime CPU source coordinates included the fixture's animation closure, and widget creation locations were separately labeled. Before/after VM reads verified restoration of all four enhanced-tracing settings and preservation of timeline streams. This validates the independently launched app path, not end-to-end Maestro/Patrol/Appium support or iOS behavior.

The context helper passed its 12 tests on Flutter 3.29.0 and 3.41.6. Host unit tests cover clock mapping, partial/overlapping intervals, frame phase boundaries, restoration conflicts, CPU table compaction, shared-heap deduplication, source provenance, stable journey comparison and deterministic schema-2 regeneration. Schema-1 readers remain covered. The Python MCP client verified all eight tools, asynchronous status/cancellation and evidence bounds. Desktop and narrow report layouts were inspected; the offline report uses no remote assets.

Publication dry-run inspected the archive and reported only the expected warning about modified Git files. This working tree has not been committed or published as part of this change. Physical Android/iOS profile evidence, production overhead bounds and hosted cross-platform CI execution remain pending.
