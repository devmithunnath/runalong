---
name: runalong
description: Run reviewed Runalong profiles or interpret Flutter Runalong capture reports, compare compatible runs, and investigate rendering regressions from measured evidence.
---

Use Runalong to observe existing Flutter automation without editing its tests. Read the project's `runalong.yaml` before running a named profile; profile commands are executable configuration.

Prefer the available Runalong MCP tools for configured profiles and report retrieval. Otherwise use the installed `runalong` CLI. Consult `runalong --help` and the relevant command help before inventing flags. Do not install a new app dependency to perform external capture.

For each report, distinguish automation result, capture completeness, and budget result. Check build mode, sample count, startup coverage, disconnects, refresh-rate evidence, and the device/workload metadata before interpreting percentiles. Missing data stays unavailable.

Use the raw measurements to support claims. Frame cadence is not confirmed presentation FPS; route hints are not precise action boundaries; build/raster timings alone do not identify the responsible source line. Label explanations as hypotheses until a trace or controlled change supports them.

Compare only compatible runs. Preserve the user's selected baseline and explicit thresholds. Do not change budgets, promote a baseline, or rerun tests automatically to obtain a passing result. If a capture is incomplete, report the limitation and propose the smallest targeted experiment; run it only within the user's existing authorization.

Summarize the observed regression, its evidence, and the next useful check. Link the saved report. Do not claim a runner/device combination is validated merely because the CLI accepts its command.
