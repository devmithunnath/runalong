# Configuration and exit codes

Run `runalong init` to create `runalong.yaml`. Review the generated command before running it. Commands are arrays of executable/arguments, not shell strings. Runalong does not expand shell variables in YAML.

```yaml
version: 1
profiles:
  smoke:
    command: [maestro, test, .maestro/smoke.yaml]
    working_directory: .
    vm_service_uri_file: .runalong/vm-service.txt
    device_id: local-device
    environment:
      id: pixel-lab
      workload: catalogue-v1
      physical: true
      model: Pixel
      osVersion: recorded-os-version
      appRevision: recorded-commit
    capture:
      connect_timeout_seconds: 30
      timeout_seconds: 300
      refresh_rate_hz: 60
      max_frames: 200000
    gates:
      enabled: false
      buildP95Ms: 12
      rasterP95Ms: 12
      overBudgetPercent: 5
```

The values are examples, not universal budgets. Record the actual device and refresh rate. Paths are relative to the configuration file. Omit `vm_service_uri_file` for command-output discovery; choose either it or `vm_service_uri`, never both.

```sh
runalong run --profile smoke
```

## Capture options

| CLI option | Meaning |
| --- | --- |
| `--vm-service-uri URL` | Explicit reachable endpoint |
| `--vm-service-uri-file PATH` | Endpoint written by the app launcher |
| `--connect-timeout SECONDS` | Maximum wait for an endpoint/connection |
| `--timeout SECONDS` | Overall run limit |
| `--duration SECONDS` | Bounded observation duration for `attach` |
| `--output DIRECTORY` | Artifact parent; each run gets a unique child directory |
| `--max-frames COUNT` | Bounded sample retention; truncation is reported |
| `--refresh-rate HZ` | Explicit frame-budget refresh rate |
| `--device-id ID` | Device metadata; does not select the runner's device |
| `--environment ID` | Comparable execution environment identifier |
| `--workload ID` | Comparable scenario identifier |
| `--json` | Machine-readable CLI result |
| `--capture-mode measure\|diagnose` | Normal capture or instrumented diagnosis; default `measure` |
| `--runner-adapter none\|dart-json` | Parse existing JSON reporter test boundaries; default `none` |
| `--journey-events-file PATH` | Fresh structured external-runner event input |
| `--source-root PATH` | Optional matching checkout for immutable source declaration candidates |

Use `runalong COMMAND --help` for authoritative command options.

Profiles use `capture.mode`, top-level `runner_adapter`, `journey_events_file`, and `source_root`. Paths are relative to the configuration. See the [journey guide](journey.md) for context integration, metrics, event format and attribution limits. Diagnostic captures are instrumented and cannot pass normal rendering gates.

## Explicit gates

```sh
runalong run --profile smoke --gate \
  --max-build-p95-ms 12 --max-raster-p95-ms 12 \
  --max-over-budget-percent 5
```

No default performance limits are applied. Setting a refresh rate defines the per-phase frame budget; it does not itself enable a CI gate. Debug/unknown build mode or incomplete measurement cannot establish a performance pass.

For a reviewed baseline:

```sh
runalong compare artifacts/baseline/BASELINE_RUN_ID artifacts/candidate/CANDIDATE_RUN_ID
runalong run --profile smoke --gate \
  --baseline artifacts/baseline/BASELINE_RUN_ID --regression-percent 10
```

Baseline gating requires matching workload and environment identifiers, a declared physical device, profile mode, matching refresh-rate evidence, and complete capture. A desktop capture is diagnostic and cannot serve as a validated mobile baseline. A comparison is inconclusive when required evidence is absent or incompatible. Baselines are inputs: Runalong never promotes a run or loosens a budget automatically.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Command completed with no applicable failure |
| 2 | Invalid command or configuration |
| 3 | Capture failure |
| 4 | Explicit performance budget failure |
| 5 | An enabled gate/comparison is inconclusive |
| 6 | Report processing failure |
| 124 | Run timeout |
| 130 | Cancellation |

The wrapped command's failure is preserved rather than overwritten with a performance success. Inspect the report's separate automation, capture, and budget states, especially when an automation tool uses a code from the same numeric range.
