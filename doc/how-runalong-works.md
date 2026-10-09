# How Runalong works, in plain English

Runalong watches a Flutter app while your existing UI tests use it, saves the frame timings Flutter reports, and turns those timings into a report you can read or check in CI.

**Its main advantage: add performance reporting to your workflow without adding a recorder to your app.** Install the tool on your computer or CI machine; keep your app dependencies and test source unchanged. The app still needs a reachable VM Service, which can require launch configuration changes.

Think of your test runner as the person driving a car through a planned route. Runalong is the observer recording how the journey went. Flutter supplies the measurements. Runalong does not drive the car, and a successful journey does not automatically mean it was smooth.

This guide explains the current **0.1.0 implementation**. It starts with the everyday problem and gradually opens up the internals. Examples with made-up numbers are marked as illustrations. For executed device and runner checks, use the [validation record](validation.md).

## Reading map

- [The problem and the three moving parts](#1-what-problem-does-runalong-solve)
- [The connection to Flutter](#3-how-can-it-observe-an-app-without-being-installed-inside-it)
- [Why an external recorder: benefits and trade-offs](#why-choose-an-external-recorder)
- [A complete journey from command to report](#5-what-happens-when-you-run-a-test)
- [What gets recorded](#7-what-information-actually-arrives)
- [Understanding the numbers](#9-what-do-build-raster-and-frame-budget-mean)
- [Screens, actions, and missing coverage](#12-can-it-tell-which-screen-or-action-was-slow)
- [Files and the report interface](#14-what-is-saved-and-why-are-there-five-files)
- [Configuration, comparisons, and CI](#16-what-is-a-saved-profile)
- [Cancellation and privacy](#19-what-happens-when-something-stops-or-fails)
- [AI, MCP, and skills](#21-where-do-ai-mcp-and-skills-fit)
- [The codebase and validation](#23-how-is-the-code-organized)
- [A practical investigation and glossary](#26-how-would-you-use-this-to-investigate-a-real-problem)

## 1. What problem does Runalong solve?

A UI test might open a catalogue, scroll, select a product, and check its title. Every assertion can pass even if scrolling visibly stutters.

That leaves two different questions:

| Question | Who answers it? |
| --- | --- |
| Did the app do the correct thing? | Your existing automation and its assertions. |
| How long did Flutter spend preparing and rendering frames during that journey? | Flutter's timing events, collected and summarized by Runalong. |

Runalong makes the second question part of an existing test workflow. You do not need to create a second set of tests just to collect rendering measurements.

It records rendering, sampled memory and garbage-collection notifications. Optional diagnostic mode also records sampled Dart call stacks and supported widget/layout/paint traces. It does not measure battery use, prove memory leaks, or know the exact moment an image appears on the physical display.

## 2. What are the three moving parts?

1. **Your automation runner:** Flutter integration tests, Maestro, Patrol, Appium, or another executable. It performs the interactions and decides whether its tests passed.
2. **The Flutter app:** the program on the device. It produces timing events while rendering.
3. **Runalong:** a separate program on your development computer or CI machine. It starts or accompanies the runner and listens to the app.

```text
                       launches and observes exit status
                Runalong --------------------------------> Test runner
                    ^                                           |
                    | timing events                             | taps, scrolls,
                    |                                           | assertions
                    +---------------- Flutter app <--------------+
                    |
                    +--> local evidence files --> report / CI / coding agent
```

The **host** is the computer running Runalong. The **target** is the Flutter app being observed. Host-platform support and target-device support are separate: a macOS host recording an Android phone is one combination; a macOS host recording a desktop Flutter app is another.

Runalong is a Dart command-line package. Installing it on the host does not require adding it to your app's production dependencies. `runalong` and `ral` are two entry points to the same implementation. Using Dart keeps development and installation in the toolchain Flutter developers already use; the current package requires Dart 3.11 or later on the host.

## 3. How can it observe an app without being installed inside it?

Flutter's native development runtime exposes a **Dart VM Service**: an inspection connection that tools can use to ask about the running program and receive events.

An **endpoint** is the address of that connection. Flutter may print a URL that looks like this fictional example:

```text
http://127.0.0.1:12345/example-token=/
```

Runalong converts an HTTP(S) service address to the equivalent WebSocket address when needed. A **WebSocket** keeps a connection open so events can arrive over time. The `vm_service` dependency handles the Dart service messages. A reachable DDS endpoint can also be used; DDS is a service layer that can sit between development tools and the VM.

“Reachable” matters. The address must work from the machine running Runalong. Device port forwarding or runner launch configuration may be necessary. Runalong does not scan arbitrary ports or guess which app you meant.

Flutter already supplies frame events in the supported non-release runtime. Runalong subscribes to those events and inspects runtime information. It does not inject a test wrapper or register a timing callback in your application source.

The relevant implementation is in [the collector](../lib/src/collector.dart). Flutter's own scheduler connects engine frame timings to its development tooling; see [Flutter's timing callback documentation](https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addTimingsCallback.html).

### Why choose an external recorder?

Putting a recorder inside an app is a valid approach, but it makes recording part of the app's integration work. Runalong instead uses Flutter's existing inspection connection so developers can adopt the tool through their development and test workflow.

| Benefit | What changes in your day-to-day work |
| --- | --- |
| No app dependency or initialization | You install Runalong on the host. You do not add a recorder package, initialize it in `main()`, or maintain profiling wrappers in the app. |
| Existing test journeys stay useful | The test runner performs its normal interactions while Runalong observes the app. You can add rendering evidence without rewriting assertions. |
| Independence from test syntax | The recorder needs the app's service connection and the runner's command, not knowledge of how its test files are written. Actual runner compatibility still needs validation. |
| Tool upgrades stay separate | Improvements to report rendering, comparisons, or MCP can be installed without changing app dependencies or rebuilding the app just to receive those improvements. |
| Report processing happens on the host | Statistical aggregation, HTML generation, comparisons, and agent communication do not execute inside the measured app. |
| Evidence has a separate lifetime | If the app crashes, records already written by the host can survive. Missing or buffered events are not guaranteed to survive, and coverage remains incomplete. |
| One workflow across projects | A team can use the same Runalong version and reporting process across apps, while choosing suitable workloads and budgets for each one. |

Both an in-app recorder and Runalong can use Flutter's underlying frame timings. Moving collection outside the app does not automatically improve accuracy or eliminate measurement overhead. The practical advantage is separation: the app implements its features, the runner exercises them, and Runalong manages the evidence.

### What does that choice give up?

| Need | Current external approach | What an in-app integration could provide |
| --- | --- | --- |
| Earliest startup frames | Can miss work before attachment; records the coverage gap. | A suitably early timing callback can capture work before an external connection is ready. |
| Exact business-action labels | Has approximate route hints by default; the optional context helper adds named screen and business-operation boundaries. | Explicit markers placed where the application performs those actions. |
| Release-build observation | The current VM Service backend cannot record release builds. | Appropriately designed in-app timing collection can operate in release builds. |
| No external service connection | Requires a reachable endpoint and handles disconnects. | Can collect locally without depending on a host VM connection, while needing its own storage/export handling. |

For Runalong's existing-test workflow, the external approach is the default. The optional `runalong_context` helper adds screen and business-operation names without changing test source. It is a separate app dependency enabled explicitly for profiling; the external recorder still works without it. For most adoption decisions, first check whether a profile build and reachable endpoint fit your project, then consult the [verified compatibility status](validation.md).

## 4. Why use a profile build?

A **profile build** is Flutter's mode for investigating performance while retaining inspection capabilities. Debug mode prioritizes development features and has different performance characteristics; release mode removes the inspection access this collector needs. [Flutter build modes](https://docs.flutter.dev/testing/build-modes)

| App mode | How Runalong treats it |
| --- | --- |
| Verified profile | Suitable for evaluating configured budgets if the other capture requirements are met. |
| Debug | Useful diagnostic information; cannot establish a passing performance gate. |
| Unknown | The tool could not verify enough about the runtime; cannot establish a passing performance gate. |
| Release | Unsupported by this VM Service collector. |

Runalong does not trust the presence of `--profile` in a command as proof. It inspects the runtime and the isolates supplying Flutter frames. An **isolate** is a separate Dart execution context; an app can have more than one.

The current check combines Flutter service-extension evidence with a small, read-only `Platform.isAndroid` evaluation probe. A successful probe indicates a debug-style runtime; the expected AOT rejection, together with Flutter frame evidence, supports profile classification. **AOT** means code compiled ahead of execution. Unexpected or incomplete evidence remains unknown. This is an implementation-specific runtime check, so compatibility still needs testing as Flutter changes.

Measurement mode does not enable expensive widget tracing. Diagnostic mode explicitly enables supported tracing and restores previous settings when possible; neither mode clears shared Flutter timeline or CPU buffers. However, connecting, asking questions, delivering events, and writing files still have a cost. “No app dependency” does not mean “zero overhead.”

## 5. What happens when you run a test?

There are two main ways to start.

### Path A: attach first, then start automation

Start your app in profile mode and keep it running. Give Runalong its real VM Service URL, then put your existing automation command after `--`:

```sh
runalong run --vm-service-uri 'YOUR_VM_SERVICE_URL' \
  -- maestro test .maestro/catalogue.yaml
```

The URL and flow path above are placeholders for your project. The steps are:

1. Validate the options and create a new run directory.
2. Connect to the supplied service and subscribe to events.
3. Start `maestro` with the supplied arguments.
4. Collect frame events while Maestro performs the journey.
5. Record Maestro's exit result, allow a short final delivery window, and close collection.
6. Generate the report and evaluate any budgets you explicitly enabled.

With an explicit URL, connection must succeed before the automation starts. This avoids missing the beginning of the automation window. It does **not** measure app startup that happened before attachment.

The runner must interact with that app process. If its first step closes and relaunches the app, the original connection may no longer describe the app now on screen.

### Path B: let the runner launch the app

```sh
runalong run --connect-timeout 180 --timeout 300 \
  -- flutter drive --profile --no-dds \
     --driver=test_driver/integration_test.dart \
     --target=integration_test/journey_test.dart -d DEVICE_ID
```

Use your project's existing driver, test path, and device ID. Runalong starts the command, watches supported Flutter launch messages for the service address, and connects when it becomes available.

This is convenient, but the app or test can start doing work before Runalong attaches. The report marks that missing startup coverage. It does not pretend that the earliest recorded frame was the first frame of the journey.

### A third connection option: an endpoint file

Some runners hide the VM URL from their normal output. Their launcher can write it to a file, which Runalong reads through `--vm-service-uri-file`.

If the file already contains a reachable endpoint, Runalong attempts an early attachment. If the endpoint appears later, automation may already have started, so coverage can still be partial. Use a fresh file to avoid attaching to a previous launch.

For exact recipes and their validation status, read [runner setup](runners.md).

## 6. What does “existing tests unchanged” really mean?

Your test source keeps its existing assertions and interactions. Runalong receives an executable and an argument list rather than requiring a particular test API.

The separator `--` means “everything after this belongs to the command being wrapped.” A saved command such as `[maestro, test, .maestro/catalogue.yaml]` contains the executable `maestro` and its two arguments. Runalong preserves those boundaries rather than combining the values into a shell script.

You may still need to change **how the app is launched**: use profile mode, expose a service URL, configure forwarding, or prevent a runner from replacing an already-attached app.

The same boundary can accommodate many runners, but that does not certify every runner configuration. A release-only app, Flutter web, and ordinary widget tests do not provide the supported capture environment. Runalong also does not learn a runner's test names or action boundaries simply by launching its command.

On Windows, launchers such as `flutter.bat` require special handling. Runalong resolves `PATH` and `PATHEXT`, the executable-search settings. Native executable arguments are forwarded directly; batch-file arguments containing unsupported shell metacharacters are rejected rather than silently reinterpreted. Details are in [runner expectations](runners.md#runner-expectations).

## 7. What information actually arrives?

Runalong listens for two Flutter extension-event types:

| Event | What it contributes |
| --- | --- |
| `Flutter.Frame` | Frame number, timing information, and the isolate that supplied it. |
| `Flutter.Navigation` | A route-name hint when the app emits a supported navigation event. |

The frame fields saved by Runalong include:

| Saved field | Plain meaning |
| --- | --- |
| `number` | Flutter's number for that frame. |
| `startTimeMicros` | The engine timestamp for the start of build work. |
| `buildMicros` | Time spent in the UI/build phase. |
| `rasterMicros` | Time spent in the raster phase. |
| `elapsedMicros` | Span from the frame's vsync start through raster finish. |
| `vsyncOverheadMicros` | Delay between the vsync signal and the start of build work. |
| `receivedAt` | When the host received the event. |
| `segment` and `isolate` | Which part of the capture and Dart execution context this sample belongs to. |

**Vsync** is a timing signal associated with the display's refresh cycle. A **microsecond** is one millionth of a second; 1,000 microseconds equal 1 millisecond. Flutter defines these frame timing concepts in [the FrameTiming API](https://api.flutter.dev/flutter/dart-ui/FrameTiming-class.html).

The collector accepts the known fields, validates their types and nonnegative values, and counts malformed frame events. It does not copy every unknown event payload into a report. See [the sample model](../lib/src/model.dart) for the stored shape.

## 8. Why are timestamps, duplicates, and segments important?

Imagine receiving ten letters together. Their delivery time does not tell you when each letter was written. Frame timing information can also arrive in bursts because Flutter batches timing delivery. Runalong uses the engine's recorded timestamps for frame calculations, not the speed at which messages reach your laptop.

Two clocks are involved: engine timestamps describe frame timing; host timestamps describe reception and capture lifecycle. They are not assumed to share an origin. The engine's clock is not a normal calendar timestamp.

A **segment** keeps one observed connection/isolate lifetime separate from another. Frame numbers or timestamps can overlap after a restart. Runalong uses the segment, isolate, frame number, and build-start timestamp together to identify a sample. Repeated copies do not count as extra frames. Report generation also sorts samples so event arrival order does not dictate the statistics.

If the selected connection disappears, Runalong records a gap and can try to reconnect while the run remains active. A replacement isolate starts a new segment. A refreshed explicit URI file can supply a replacement endpoint.

Automatic output discovery is deliberately narrower: if two different service endpoints appear, collection stops as ambiguous while automation continues. Runalong cannot know whether the second URL means “the same app restarted” or “another app.” It does not silently switch targets.

Segments explain changes in the evidence. They do not fill the missing intervals between them.

## 9. What do build, raster, and frame budget mean?

Use an assembly line as an analogy. One stage prepares the instructions for a frame; another performs the rendering work. Runalong reports the time for each stage separately:

- **Build/UI duration:** Flutter's UI-thread work preparing the frame.
- **Raster duration:** Flutter's raster-thread work rendering it. This is not a direct measurement of GPU utilization or confirmation that the display presented it.

Different frames can overlap in the rendering pipeline. Adding build and raster time and turning that sum into FPS would describe the wrong thing.

A **frame budget** is the time available per refresh interval:

```text
budget in milliseconds = 1000 / refresh rate in hertz
```

| Refresh rate | Approximate phase budget |
| --- | --- |
| 60 Hz | 16.67 ms |
| 90 Hz | 11.11 ms |
| 120 Hz | 8.33 ms |

Illustration: a frame with a 12 ms build phase and a 4 ms raster phase is within each phase's budget at 60 Hz. Its build phase exceeds the budget at 120 Hz. The same timings mean different things under different refresh-rate conditions.

Runalong counts a frame as over budget when **either** phase exceeds the budget. If both exceed it, the frame is still counted once. Equal to the budget does not count as exceeding it. This is a signal of slow rendering work, not a verified count of frames dropped by the operating system.

Runalong asks the runtime for its reported refresh rate when it can identify one Flutter view for the isolate. Missing or ambiguous view information can leave the rate unknown. `--refresh-rate` supplies an explicit override and the report labels it as such. If no usable rate is available, refresh-dependent metrics remain unknown.

This version uses one refresh-budget value for a run. A sufficiently large change detected during runtime inspection adds a coverage gap, but Runalong does not continuously monitor every physical refresh or prove that a variable-refresh display maintained that rate throughout.

## 10. Why show p50, p90, p95, p99, and maximum?

An average can hide occasional pauses. A **percentile** describes a position in the sorted measurements.

For an illustration with exactly 100 frames, sort their build times from fastest to slowest:

| Statistic | Runalong's selected value |
| --- | --- |
| p50 | The 50th value. |
| p90 | The 90th value. |
| p95 | The 95th value. |
| p99 | The 99th value. |
| Maximum | The slowest value. |

For other sample counts, Runalong uses the nearest-rank rule: round `sample count × percentile` upward and select that position. Build and raster have separate distributions.

If build p95 is 18 ms, at least 95% of the **captured** build durations are at or below 18 ms under this rule; ties can make that proportion higher. It says nothing about work that was missed before attachment or during a disconnect. With a tiny sample, p95 may simply be the maximum, so always read the frame count too.

An over-budget percentage uses captured frames as its denominator. For example, 5 slow frames among 100 captured frames means 5%; it is not a claim that 5% of all possible display updates were lost.

## 11. Why doesn't Runalong just report FPS?

There are several different things people call “FPS.” The display's refresh rate, Flutter's frame-production rhythm, and the number of frames actually presented by the operating system are related, but they are not interchangeable.

Runalong computes **observed cadence** from positive intervals between recorded vsync starts within the same segment and isolate. It reports interval statistics and converts the median interval into a frequency. It does not join intervals across restarts.

An app might render a frame, sit still for two seconds, and render another after a tap. That long interval is not evidence that an animation ran at half a frame per second. The cadence calculation can include idle time, so its labels explicitly warn against interpreting it as presentation FPS.

Use build/raster durations and over-budget counts to investigate the measured rendering work. Actual presentation FPS and compositor-dropped frames require an additional native measurement source that Runalong does not currently implement.

## 12. Can it tell which screen or action was slow?

It can preserve route-name hints, when Flutter supplies them. It cannot currently label every tap, scroll, tab change, or test step automatically.

Navigation and frame events use different timing information, and delivery can be delayed. The written findings can include a preceding named route as an approximate hint when the isolate and receipt ordering are unambiguous. Unknown navigation events clear that context. The full event list retains host receipt times. These hints are not authoritative frame-to-screen assignments.

For example, a slow frame received near a `/catalogue` navigation event is a useful investigation clue. It does not prove that the catalogue route caused it, and it cannot support a precise “Add to basket took 34 ms” claim.

For named operations today, enable the optional context helper and put a marker around the work. Runalong calibrates its VM clock and joins engine frame IDs. The JSON reporter adds test boundaries, and external adapters can supply structured steps, but receipt-aligned runner events stay approximate. See [journey setup](journey.md).

## 13. Why does one run have three different results?

Because three independent things can go right or wrong:

| Result | The question it answers |
| --- | --- |
| Automation | Did the wrapped test command succeed? |
| Capture | Did Runalong collect usable evidence for its intended window, with no known gaps or truncation? |
| Budget | Did the valid evidence satisfy the limits you enabled? |

Illustration: Maestro exits successfully, but Runalong attaches halfway through the journey. Automation passed; capture is partial. If a gate was enabled, the tool cannot establish a clean performance pass from that partial evidence.

Another illustration: capture is complete and shows fast frames, but the test's final assertion failed. Good rendering numbers do not turn that failed test into a success.

**Complete** is bounded by the selected capture window and the collector's detected conditions. It is not proof that every future user interaction is fast or that every possible form of event loss can be detected. Attach-only recording describes its observation window, not startup before attachment.

By default, Runalong is reporting first. A successful command with useful partial evidence can return exit code 0 while explicitly reporting partial coverage and disabled gates. Exit 0 alone is not a performance certification.

## 14. What is saved, and why are there five files?

Each run gets a unique ID and a new directory. By default, CLI runs use `.runalong/runs` under the working directory; `--output` chooses another parent directory. A saved profile can change that working directory. MCP has a separate, fixed project-root policy described below.

| File | Think of it as | Why it exists |
| --- | --- | --- |
| `events.jsonl` | The measurement notebook | Each line is one selected, sanitized event. Records are appended during collection. |
| `manifest.json` | The notebook cover sheet | Run identity, lifecycle, environment information, capture conditions, and budgets. It is written at setup and updated during finalization. |
| `report.json` | The calculated result | Versioned, machine-readable measurements, statuses, frames, and report metadata. |
| `report.html` | The visual explanation | A standalone report for a person to open in a browser. |
| `summary.md` | The short handover | A Markdown summary suitable for CI job output. |

The HTML opens with a written review: what rendering work needs attention, when the captured slow moments occurred, what the evidence suggests, and what to investigate next. Each finding selects its supporting frame range. The same findings are stored in JSON for agents and written into the CI summary. This layer runs after capture, so it adds no on-device tracing. [Read the findings guide](report-findings.md) for the grouping rules and attribution limits.

**JSON** stores structured data. **JSONL** stores one JSON object per line, so earlier valid lines can remain useful if the last write was interrupted. A **schema version** tells readers which data format they are dealing with; the current schema is version 2; version-1 frame-only captures are still readable.

The run directory is never silently reused for a new recording. However, derived report files are intentionally replaceable:

```sh
runalong report .runalong/runs/RUN_ID
```

Replace `RUN_ID` with the actual printed ID. This reads the saved manifest and events, recalculates the result, and rewrites JSON/HTML/Markdown without rerunning the app. It preserves any comparison saved in the finalized manifest rather than rereading a baseline that may since have changed. With the same tool implementation and unchanged valid input, regeneration is deterministic: the same evidence produces the same derived files. A future renderer version can legitimately produce different HTML.

Malformed or truncated saved records are handled conservatively and reflected in coverage. Recovery can use records that reached disk; it cannot recover events never received or guarantee that buffered writes survived a machine crash. Derived files are written through temporary files and renamed into place to reduce the risk of leaving a half-written report.

## 15. What does the HTML report do?

The HTML contains its own data, styles, and JavaScript. It opens directly from disk without a local web server, CDN, or hosted account.

Use it in this order:

1. Read automation, capture, and budget status.
2. Check the build mode, sample count, refresh-rate source, and coverage warnings.
3. Select the test, screen visit or named operation in the journey.
4. Read the explanation, then inspect frames, memory, Sampled code and Widgets & sources within that same window.
5. Copy source references and compare equivalent occurrences; use the detailed charts when needed.

Selecting a smaller interval is an investigation aid; it does not silently replace the whole-run CI gate with a more favorable result. A comparison is included when that run was evaluated against a configured baseline; the standalone `compare` command prints comparison data without rewriting either run.

For large selections, the graph reduces its visual preview to roughly 650 points per phase while preserving peaks. Statistics and the paginated frame inspector still use the retained samples. A simplified drawing is not the same as discarding evidence from the calculation.

Collected labels are escaped before rendering, and report data is encoded for safe embedding. Text from the app should appear as text rather than become executable HTML. That protects the viewer; it does not make private route names suitable for public sharing.

## 16. What is a saved profile?

A saved profile is a named recipe in `runalong.yaml`. It is different from a Flutter **profile build**: one describes how to run a journey; the other describes how Flutter compiled the app.

Illustrative configuration:

```yaml
version: 1
profiles:
  catalogue:
    command: [maestro, test, .maestro/catalogue.yaml]
    working_directory: .
    vm_service_uri_file: .runalong/vm-service.txt
    environment:
      id: android-lab-phone
      workload: catalogue-v1
      physical: true
    capture:
      timeout_seconds: 300
    gates:
      enabled: false
```

The flow must exist and your launcher must supply a fresh endpoint file. `physical: true` is a declaration about the actual test device, not a switch that turns an emulator into one.

Run the recipe with `runalong run --profile catalogue`. Use `runalong init` to generate a commented starter configuration; it refuses to overwrite an existing file. Configuration paths are resolved relative to the project containing the configuration. YAML does not expand shell variables or evaluate command substitutions.

The loader rejects unknown configuration keys and invalid values so a typo does not silently change the experiment. Selected CLI options can override a profile; use [the configuration reference](configuration.md) for the supported fields.

With `--device-id`, Runalong can ask `flutter devices --machine` for the exact matching device's model, OS version, and physical/emulator information. Other identity fields come from configuration, and the report records metadata provenance. The flag does not choose the wrapped runner's target. Your Flutter, Maestro, or Appium command remains responsible for device selection.

## 17. How do budgets and comparisons work?

A **gate** is an optional rule that can fail CI. A **baseline** is a previous run you explicitly chose as the reference. Runalong has no universal “good performance” threshold.

### Absolute limits

You can require build p95 to remain at or below a chosen number of milliseconds, raster p95 at or below another, or the over-budget percentage at or below a chosen percentage.

The refresh budget and the CI limit are separate ideas. A known 60 Hz refresh rate establishes the per-frame timing budget; it does not automatically fail your build when a frame exceeds it. You must enable a gate and choose the acceptable aggregate limits.

Absolute gates require successful automation, or an explicit attach-only observation, verified profile mode, complete capture, and usable samples. An over-budget-percentage gate also needs a known refresh budget. Missing requirements make the gate inconclusive. Absolute gates do not by themselves require physical-device metadata; baseline comparison requires recorded `physical: true`, supplied by device discovery or configuration.

### Relative regression limits

The implemented baseline comparison checks build p95 and raster p95. An illustrative rise from 10 ms to 12 ms is a 20% increase:

```text
change percent = (candidate - baseline) / baseline × 100
```

Without a regression threshold, compatible runs are reported as compared. With a threshold, a phase fails when its percentage increase exceeds that threshold. A zero baseline needs special treatment: zero to zero is no increase; zero to a positive value has no meaningful finite percentage and stays inconclusive.

Before judging those differences, Runalong checks schema support, environment and workload identities, profile mode, physical-device metadata, successful and comparable automation modes, complete nonempty captures, and matching refresh-budget definitions. Device model/OS-version differences also invalidate comparison. Runtime versus manually overridden refresh evidence must match, not merely the numeric rate.

Some identity fields are supplied by you. Matching labels do not independently prove identical phones, data, temperature, or background activity. Keep the experimental conditions consistent. A new app revision is expected in a regression experiment; a different workload is not.

If absolute limits and a baseline are configured together, both contribute to the final result. Incompatible evidence remains inconclusive even if some numbers look good. Runalong does not rerun until it gets lucky, relax limits, or silently promote the latest run to baseline.

## 18. How does this fit into CI/CD?

**CI** runs automated checks when code changes. **CD** uses checks and release steps to deliver software. Runalong produces evidence that either kind of pipeline can retain or use in an explicitly enabled gate.

The exit code is the short signal the pipeline receives. A Runalong-triggered timeout or cancellation takes precedence. Otherwise, a nonzero automation result is preserved ahead of capture, budget, or report-processing errors. Its documented codes distinguish configuration problems, unusable capture, failed or inconclusive gates, report failures, timeout, and cancellation. See [the exact exit-code table](configuration.md#exit-codes).

Because runners can use the same numeric codes for their own errors, the report's separate statuses give more context than an exit code alone. A script error and slow frames are different failures even if both make a job red.

Configure artifact upload and summary publication to run **even if the recording step fails**. Otherwise, the failing run that most needs investigation may be the one whose report nobody can find. The [CI guide](ci.md) and [GitHub Actions workflow](../.github/workflows/ci.yml) demonstrate this.

A shared CI desktop runner can exercise the collector and package tests. Its timing results do not establish mobile performance on a physical Android phone or iPhone.

## 19. What happens when something stops or fails?

Runalong manages the automation command and recording connection separately, then brings their results together during finalization.

| Situation | Intended behavior |
| --- | --- |
| Explicit `--vm-service-uri` cannot be reached | Do not start automation against an unobserved target; preserve the run's failure information. A URI file has the different startup behavior explained above. |
| Automatic discovery never finds a service | Record the missing capture; do not invent zero-duration frames. |
| VM disconnects | Keep earlier evidence, record a gap, and attempt reconnection within the run lifecycle. |
| Automation fails | Preserve its failure and finalize whatever evidence was captured. |
| Timeout or cancellation | Stop owned work, close collection, and try to finalize a partial report. |
| Disk/report write fails | Record the report-processing problem and preserve a nonzero automation result if there is one. Saved evidence may still allow recovery after the filesystem problem is fixed. |

For an explicit URL or attach-only connection, `--connect-timeout` bounds connection setup immediately. For runner-owned discovery, that deadline starts once an endpoint becomes available, so building and launching the app do not consume it. A runner that never publishes an endpoint can therefore keep running until it exits, is cancelled, or reaches the separate overall `--timeout`. Set that overall timeout when you need a firm bound on the whole job.

`attach --duration` provides a bounded observation when Runalong is not starting a test command. An attach-only run reports automation as not applicable. For example, substituting the real service URL:

```sh
runalong attach --vm-service-uri 'YOUR_VM_SERVICE_URL' --duration 30
```

Runner stdout and stderr are drained while it runs so a large amount of output does not block the process. Discovery examines supported launch output; it does not derive frame timings from log text. The CLI normally forwards runner output to the terminal. With `--json`, it sends that output to stderr, leaving stdout for the structured result. MCP suppresses runner output from its protocol channel.

On cancellation, cleanup targets the process Runalong launched and its observed descendants. It does not issue a machine-wide “kill Flutter” command or intentionally stop a separately launched app. Process cleanup uses host-specific mechanisms; detached or reparented processes outside its ownership tracking can require runner-specific cleanup.

At normal completion, the collector allows a short flush window, currently 350 ms by default in the application service, for late timing delivery. This helps with batching but cannot make disconnected or never-delivered frames appear.

## 20. What are the resource and privacy boundaries?

The default collection limit is 200,000 frames. Collection can be configured up to 1,000,000, but current report aggregation separately caps itself at 200,000 unique frames. Increasing the collector limit does not remove the report limit. Exceeding a relevant limit is reported as truncation/partial evidence.

Navigation retention is limited to 2,000 events, and route names to 256 characters. These are investigation hints, not a complete navigation audit. Recording and report generation have finite memory and disk costs; offline does not mean unlimited.

Runalong has no telemetry service, model API key, or hosted report upload. It connects to the VM endpoint you selected and writes evidence locally. Your automation can still contact its normal backend, and an AI client can have its own data-sharing behavior.

Reports omit VM authentication URLs, raw application logs, route arguments, and environment-variable dumps. Route query strings and fragments are removed. However:

- A route path such as `/customer/12345` can still contain an identifier.
- User-supplied environment/workload labels can contain private information.
- Configured baseline paths can reveal local path names.
- The terminal still receives runner output, which may contain sensitive application logs or service URLs; your CI log policy is separate from report sanitization.

Review the actual artifacts before publishing them. “Sanitized” describes specific exclusions, not a guarantee that every app-defined string is anonymous.

## 21. Where do AI, MCP, and skills fit?

Runalong records and calculates results without AI. An assistant can help operate it and interpret the evidence.

Three terms describe three different things:

| Term | Plain meaning | Runalong's role |
| --- | --- | --- |
| Coding agent | A program that uses an AI model and tools to work on code. | Can run the CLI or call MCP tools, inspect evidence, and propose changes. |
| MCP | Model Context Protocol: a standard way for a client to discover and call tools. | Exposes structured Runalong operations to compatible clients. |
| Skill | Written workflow instructions that an agent can follow. | Explains how to check capture quality, compare runs, and ground findings in evidence. |

MCP is not an AI model, and a skill is not a collector. Neither makes an incomplete recording complete. Runalong does not bundle a dedicated assistant or send reports to a model by itself.

An agent with terminal access can simply use the CLI. An MCP client can start `runalong mcp --project PATH`. The server communicates through **stdio**, meaning the child process's standard input and output, rather than opening a public web server. A thin adapter using `dart_mcp` calls the same application services as the CLI.

The useful AI sequence is: check setup, run an authorized journey, inspect capture quality, compare compatible evidence, investigate a suspected cause, and verify a proposed change. The [included skill](../skills/runalong/SKILL.md) requires observations and hypotheses to remain distinct.

For example, “build p95 increased from 10 to 18 ms” is an observation. “An expensive JSON parser caused it” is a hypothesis until source inspection, profiling, or a controlled experiment supports it.

## 22. What can an MCP client actually do?

| Tool | What it does |
| --- | --- |
| `list_profiles` | Lists saved journey names from the selected project. |
| `start_run` | Starts one named profile and promptly returns a run ID. |
| `get_run` | Reports progress or the recorded final state. |
| `cancel_run` | Requests cancellation of an active run and finalization of available evidence. |
| `get_report` | Returns compact metadata, metrics, and up to 20 slowest measured frames. |
| `compare_runs` | Compares two saved reports without changing their baselines. |
| `list_journey` | Pages through named tests, screens and operations. |
| `get_finding_evidence` | Returns bounded metrics and source references for one recorded item or finding. |

A run ID works like a claim ticket: the client can ask about the same job again without holding a single tool call open for the whole test. The current server permits one active run at a time and does not use optional MCP task extensions.

Runs stay within the server's lifetime. Closing its input requests cancellation of active work. After a restart, finalized runs can still be read from disk; an interrupted job is not automatically resumed.

MCP accepts saved profile names, not arbitrary shell command strings. However, profiles themselves execute commands. Someone who can edit the configuration can change what a profile runs, so this is a reviewed-command boundary, not an operating-system sandbox.

MCP stores artifacts under the chosen project's `.runalong/runs`, even when a profile uses a different command working directory. Run lookups validate IDs and directory boundaries, including symlinks. Reads over 128 MiB are rejected. Compact report responses omit the full frame array and limit navigation hints to 200 entries to avoid flooding an agent's context. CLI runs saved under a custom output directory remain available through the CLI and files; they are not automatically available through MCP's run-ID lookup.

App-supplied report text is evidence, not instructions for an agent to obey. The assistant's own permissions and handling of that text still matter.

The adapter's SDK is experimental. Protocol negotiation with version `2025-11-25` has been exercised using a Python client. That verifies one interoperability path, not every coding agent or protocol version. See [MCP setup](mcp.md) for client configuration.

## 23. How is the code organized?

The code follows the same steps as the user experience. Each module has a narrow responsibility so a change to the report does not need to change how a process launches.

| File | Its job, in everyday terms |
| --- | --- |
| [`bin/runalong.dart`](../bin/runalong.dart), [`bin/ral.dart`](../bin/ral.dart) | The front doors. Both enter the same CLI implementation. |
| [`cli.dart`](../lib/src/cli.dart) | Reads commands, prints results, and translates outcomes into exit codes. |
| [`config.dart`](../lib/src/config.dart) | Checks the saved recipes, paths, options, and service-address format. |
| [`process_launcher.dart`](../lib/src/process_launcher.dart) | Turns an executable and arguments into a host-appropriate process launch. |
| [`run_service.dart`](../lib/src/run_service.dart) | Coordinates the command, recorder, cancellation, evidence files, and final result. |
| [`collector.dart`](../lib/src/collector.dart) | Connects to Flutter and turns recognized events into validated records. |
| [`model.dart`](../lib/src/model.dart) | Defines the shared shapes for frames, settings, progress, cancellation, and results. |
| [`reporting.dart`](../lib/src/reporting.dart) | Calculates statistics, checks budgets, compares runs, and writes/rebuilds reports. |
| [`report_template.dart`](../lib/src/report_template.dart) | Contains the standalone report interface. |
| [`mcp_server.dart`](../lib/src/mcp_server.dart) | Makes the shared operations available through MCP. |

The production dependencies also have specific jobs: `args` parses CLI arguments; `yaml` reads configuration; `path` handles filesystem paths; `vm_service` handles runtime communication; and `dart_mcp` handles MCP protocol plumbing. The package itself is pure Dart, while the separate example app uses Flutter.

[`lib/runalong.dart`](../lib/runalong.dart) exports shared models, the run service, and reporting functions for Dart callers. The CLI/MCP paths use the same underlying logic; they do not maintain different definitions of a slow frame. As a preview, the public API and data contracts still need careful versioning when they change.

## 24. What does doctor check?

`runalong doctor` checks the host Dart runtime, availability of the Flutter command, and whether saved configuration can be read. With an exact `--device-id`, it checks Flutter's device listing. With an explicit VM URL or URI file, it attempts a connection.

An item marked **not checked** is not a passing check. Merely reaching a VM Service also does not prove that a useful Flutter workload is rendering or that the capture will be verified profile mode. Doctor asks you to start a real capture for that evidence.

Runalong can attach to an already-reachable service even when Flutter's CLI is not available on the recorder's host. Flutter build and device setup may have happened elsewhere. Doctor therefore distinguishes unavailable tools from an explicitly failed connection or selected-device check.

## 25. How do we know the recorder and reports are correct?

There are several layers of evidence, each answering a different question:

| Check | What it establishes | What it does not establish |
| --- | --- | --- |
| Unit and fake-VM tests | Parsing, duplicates, malformed events, ordering, gates, and lifecycle behavior match expectations. | A real phone behaves identically. |
| Process tests | Command arguments, output handling, timeout, and cancellation work in the tested host conditions. | Every runner's process tree is identical. |
| Regeneration tests | The same saved evidence produces deterministic reports with the same implementation. | The original capture included the whole journey. |
| Python MCP smoke client | The actual server can negotiate and perform its tool workflow with a client in another language. | Every AI client supports that protocol path. |
| Flutter fixture reference | Collected samples can be compared against frame timings recorded inside the fixture. | The recorder adds zero overhead. |

The fixture has a normal workload and an intentionally slow build-work option. Its optional reference recorder registers a timing callback **only inside the validation fixture**. Your production app and existing ordinary test do not need that reference code.

Comparing matching frame numbers and timestamps checks whether Runalong preserved the same measurements. The saved desktop results matched the reference samples exactly while still being marked partial. Both facts matter: accurate samples and complete coverage are different properties.

Overhead requires a separate repeated experiment with and without collection. Physical-device support requires actual device runs. The [validation record](validation.md) states what has been executed and what is pending; a workflow file or example flow alone is not evidence that an integration has passed.

## 26. How would you use this to investigate a real problem?

Suppose users report that opening a product catalogue feels slow.

1. Pick an existing repeatable journey that opens and scrolls the catalogue. Keep its data and starting state consistent.
2. Run a profile build on the intended device and collect the journey. Use preattachment when you need the whole automation window.
3. Read capture quality first. Resolve unknown mode, missing refresh evidence, or connection gaps before using the run for a gate.
4. Inspect whether the observed spike is in build, raster, or both. Note the frame IDs and interval instead of claiming an exact action label that was never recorded.
5. Select the named screen or operation, then inspect Sampled code and Widgets & sources. Runtime source locations identify observed execution or widget creation; declared locations identify your context wrapper; local declaration matches remain candidates. A location or overlap is evidence to investigate, not proof of a cause.
6. Make one justified change, repeat under the same conditions, and compare suitable runs. Inspect repeated-run variation before concluding that a small difference is a real improvement.
7. Preserve the reports and explain the result with its limits: what changed, which measured value improved, and which device/workload was tested.

An AI agent can help with these steps. The evidence should remain understandable and useful if the agent is removed from the workflow.

## 27. Quick glossary

| Term | Plain meaning |
| --- | --- |
| Artifact | A saved output file from a run. |
| Attach | Connect to an app that is already running. |
| Baseline / candidate | The chosen reference run / the run being evaluated against it. |
| Build mode | How Flutter compiled the app: debug, profile, or release. |
| Cadence | The rhythm of observed frame timing intervals. |
| Capture coverage | How much of the intended observation window has usable evidence, including known gaps. |
| Collector | The code that receives and validates runtime events. |
| Endpoint | The address of the runtime inspection connection. |
| Gate | An explicitly enabled pass/fail rule for valid evidence. |
| Inconclusive | There is not enough suitable evidence to give a trustworthy pass/fail answer. |
| Isolate | A separate Dart execution context. |
| Jank | A visible stutter or uneven motion; a timing spike is a clue to investigate it. |
| Manifest | The saved description and lifecycle record of a run. |
| Percentile | A position in a sorted set of measurements. |
| Raster | The rendering stage measured on Flutter's raster thread. |
| Regression | A worsening relative to a chosen reference under comparable conditions. |
| Schema | The agreed structure and version of stored data. |
| Segment | A distinct observed connection/isolate lifetime within a capture. |
| VM Service | Dart's runtime inspection interface. |

[Back to the quickstart](../README.md) · [Configuration](configuration.md) · [Troubleshooting](troubleshooting.md) · [Validation status](validation.md)

## The journey view: putting the numbers in context

A test name gives the overall journey. A screen marker says where the user was. An operation marker says what the application was doing, such as verifying credentials or loading account data. Clicking one filters frames, memory and diagnostic evidence together. See [the setup guide](journey.md).

A function can spend most of its elapsed time waiting for a server or for a navigation route to close. That duration is separate from slow rendering. If the function never returns before recording ends, Runalong shows only its observed portion and labels completion unknown. Approximate runner timestamps show nearby evidence and never become precise tap attribution.

Memory snapshots show the first, highest observed and last retained value inside the selection. A spike between polls can be missed. GC notifications are placed at receipt time with that uncertainty visible. CPU self samples identify the executing top function; inclusive share counts every function on the sampled stack, so shares can overlap. Neither is whole-process CPU percentage.

Runalong joins build and raster timeline phases to Flutter frame IDs when both are available. It does not infer exact frame placement from unrelated engine and host clocks. Missing phases, ambiguous frame IDs and connection gaps remain missing evidence. Earlier recordings cannot acquire exact screen or widget attribution after the fact.
