# Read a rendering review

Start with the report's written conclusion. It identifies whether the captured UI/build work, raster work, or both deserve investigation. It explains missing evidence when a conclusion is unavailable.

For example, the commercial-app pilot captured a UI build spike of 93.87 ms at 18.70 seconds after the first captured frame. Its refresh budget was 16.67 ms. The report can explain that this build work exceeded the budget and show frame 711. It cannot truthfully turn that into “the login button caused 10 FPS”: widget identity and display presentation timing were not recorded.

## Follow a finding

Each finding contains three parts:

1. **Observed:** counts and durations measured in its captured samples.
2. **What this suggests:** the rendering phase worth investigating, without declaring an unobserved cause.
3. **Try next:** a concrete verification step, such as reproducing the interaction in profile mode and inspecting UI-thread CPU/build/layout work in DevTools.

Use **Show these frames** to open that finding's segment and select its frame range. Use **Inspect the slowest frame** for the single largest phase duration. The table initially sorts by the slowest phase; switch to time order to follow the sequence. Chart marks represent samples without connecting activity across idle gaps.

**Copy investigation brief** copies the same observations, suggestions, frame references, and capture limits for an issue or coding-agent conversation. It does not send data anywhere. If browser clipboard access is unavailable, a selectable text field appears. The report remains usable offline, without an AI model or service.

## What “a moment” means

Moments are groups for investigation, not inferred taps or screens. Build and raster are assessed separately. A group stays within one segment/isolate, lasts at most one second between frame starts, allows at most two intervening within-budget samples, and splits when adjacent captured starts are over 250 ms apart. These are grouping choices, not evidence that the app was animating throughout the interval.

The report ranks groups by accumulated measured phase time above the refresh budget, then worst phase duration and stable tie-breakers. It displays the strongest five. A cluster of moderate delays can rank above a single larger spike. **Inspect the slowest frame** remains available separately.

Times are relative to the first captured frame in each segment and isolate. A restarted app starts a new segment; its clock is not joined to an earlier one. Gaps in sample numbers or arrival times are not counted as dropped display frames.

## Screen, widget, and FPS limits

When Flutter supplies a named route, a finding may include an **approximate route hint** based on preceding navigation receipts. Explicit isolate IDs scope the hint. Mixed routes, unnamed intervening events, ambiguous isolates, and restarts suppress an uncertain hint. Batched frame delivery prevents exact screen attribution even when a hint is present.

If screen names were not captured, the report says so and uses time/frame references. It does not invent a screen, widget, loading state, user action, CPU function, or root cause. Exact action labels need a runner event source and clock alignment; widget diagnoses need additional traces. Neither is silently enabled by this report.

The headline does not convert cadence into FPS. Flutter renders on demand, and captures can omit samples. Actual display FPS needs presentation-time evidence from another measurement source.

## Quality and CI results stay separate

Debug, incomplete, failed-automation, and unknown-budget runs retain their limitations alongside the findings. No slow samples is not a guarantee that every interaction was smooth. A functional pass does not establish a performance pass, and findings do not override configured gate results.

`report.json` includes the additive `insights` field with its own version, headline, summary, limitations, and findings. Each finding contains a phase, observation, interpretation, next step, and evidence coordinates. HTML, Markdown, and MCP report access share those findings.

Regenerate a saved run with `runalong report RUN_DIRECTORY`. This uses its manifest and sanitized events; no app launch, test rerun, extra tracing, model call, or network access is needed. The underlying capture files remain unchanged.
