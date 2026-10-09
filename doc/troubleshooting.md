# Troubleshooting

Start with `runalong doctor`. For a live app, add `--vm-service-uri 'YOUR_VM_SERVICE_URL'`. A successful connection check does not prove that the app is producing frames or that a capture is complete.

Use `runalong doctor --device-id DEVICE_ID` to check an exact device from `flutter devices`. It reports device availability separately from VM connectivity; it does not choose a device for your automation runner.

| Symptom | Check and next action |
| --- | --- |
| Tests pass, but no frames were captured | Confirm the endpoint belongs to the app under test, use a profile build, and perform an interaction that renders frames. Inspect capture status; zero samples are not a performance pass. |
| The collector cannot discover an endpoint | Some runners hide Flutter output. Supply the actual endpoint with `--vm-service-uri` or use a fresh `--vm-service-uri-file`. Do not reuse a stale file from a previous launch. |
| Connection works only on the device | Use a host-reachable forwarded VM/DDS endpoint, including its authentication path. Let Flutter manage forwarding where possible. |
| Capture is partial | Read its gap reasons. A runner-owned launch can start tests before attachment; a restart or app shutdown can close the VM connection. For complete command coverage, attach to a prestarted app and keep that process alive throughout the command. |
| Build mode is unknown or debug | A profile launch must be verified at runtime. Do not make a passing performance claim from a debug run or an unverified mode. |
| Refresh rate or over-budget percentage is unavailable | The runtime may not expose usable refresh evidence. If appropriate, provide the actual known rate with `--refresh-rate`; the report labels it as an override. Do not assume 60 Hz merely to fill a blank. |
| A comparison is inconclusive | Read its compatibility reasons. Check physical-device declaration, environment/workload identity, profile mode, refresh-rate evidence, and complete coverage. Do not change metadata to disguise a mismatch. |
| A tap or screen has no label | This release records approximate navigation hints, not every test action. Unnamed routes, tabs, and custom routing can lack useful labels. Inspect the timeline and runner evidence without inventing boundaries. |
| An iPhone build stops before the test | Resolve the actual signing/provisioning error in the developer account. A build failure is not a profiling result. Local validation encountered an unaccepted Apple Program License Agreement and a missing fixture provisioning profile. |
| MCP cannot find an old run | MCP reads runs under its configured project’s `.runalong/runs`. A CLI capture under a custom `--output` directory remains available through the CLI and saved HTML/JSON. |

Capture truncation, cancellation, and timeout preserve available evidence. Open the reported run directory even when the command exits nonzero. Keep automation failure separate from capture and budget failure.

[Runner setup](runners.md) · [Exit codes](configuration.md#exit-codes) · [Measurement rules](measurements.md)
