# Add Runalong to CI

**Add performance evidence to the pipeline without adding a recorder to the app.** Install Runalong on the CI host and wrap the existing automation command. App dependencies and test source stay unchanged; the app's launch configuration must still provide a reachable VM Service for a profile build.

Teams can pin and upgrade the reporting tool independently across projects. Aggregation, HTML generation, baseline comparisons, and MCP processing happen on the host, and records already written there can survive a target-app crash. Service communication still has overhead; validate it for your workload. Read [why the recorder is external](architecture.md#why-the-recorder-is-external).

Start by collecting reports alongside the existing test command. Keep performance gates disabled while verifying endpoint discovery, frame fidelity, coverage, and repeatability.

```sh
runalong run --profile smoke --output artifacts/performance
```

The profile still runs your existing automation. Runalong returns automation/capture failures even without a performance gate; “report first” does not mean swallowing all failures. A late attachment can yield a useful partial report, but cannot establish a whole-test performance pass.

## Preserve evidence on every outcome

Configure both artifact upload and job-summary generation with `if: always()`. Upload the entire artifact parent because each run has a unique child directory. Publish each child’s `summary.md` to the CI summary and keep its HTML, JSON, manifest, and raw events together.

```yaml
- name: Preserve performance evidence
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: performance-evidence
    path: artifacts/performance/
    if-no-files-found: warn
```

The repository’s [workflow](../.github/workflows/ci.yml) includes working summary collection, upload, and fixture-reference comparison steps. Its hosted Linux/Windows matrix is configured but was not executed during local development.

Do not put service authentication URLs or personal device identifiers in published artifacts. Runalong does not save the VM endpoint in its reports; review runner logs independently.

## Enable explicit gates

After obtaining complete, repeatable profile captures, choose and review limits for the workload:

```sh
runalong run --profile smoke --gate \
  --max-build-p95-ms 12 \
  --max-raster-p95-ms 12 \
  --max-over-budget-percent 5
```

These numbers illustrate syntax, not recommended universal thresholds. Baseline gates additionally require compatible physical-device/environment metadata, workload, refresh-rate evidence, and coverage:

```sh
runalong run --profile smoke --gate \
  --baseline artifacts/baseline/BASELINE_RUN_ID \
  --regression-percent 10
```

Store a reviewed baseline as an immutable artifact. Do not automatically promote every successful run or relax limits after a failure. Preserve an inconclusive result as inconclusive.

The macOS fixture job validates the collector and retains diagnostic evidence. Its runner-owned startup is partial and it intentionally does not enforce a mobile performance gate.

[Configuration](configuration.md) · [Troubleshooting](troubleshooting.md) · [Validation status](validation.md)
