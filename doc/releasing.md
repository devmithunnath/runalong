# Releasing

The current 0.1.0 implementation is a local preview and has not been published. Version labels must match the evidence recorded in [validation status](validation.md).

## Preview support

A preview may expose the generic command/VM-service integration while naming the tested Flutter version, host, and runner. Describe other combinations as unverified. Preserve incomplete-capture and unavailable-metric behavior; a preview label does not justify returning false performance passes.

Before a preview publication:

- Run formatting, analysis, Dart tests, the cross-language MCP smoke test, and archive inspection.
- Exercise a real profile build and preserve independent frame-reference comparisons.
- Review docs, package metadata, configuration compatibility, and report schema changes.
- Inspect the archive for build products, captures, personal identifiers, signing settings, and credentials.
- Verify the repository and issue-tracker URLs in `pubspec.yaml`.

Run the strict archive check, which rejects publication warnings and errors:

```sh
python3 tool/check_package.py
```

Publishing itself requires a separate explicit decision; none of these checks publish the package.

## Stable platform support

Claim stable support for a platform/runner combination only after documented real-device evidence for that combination. At minimum, record:

- Device, OS, Flutter version, renderer, profile mode, workload, and refresh-rate evidence.
- Frame fidelity against an independent reference, including captured overlap and any gaps.
- Smooth and intentionally slow workloads, plus startup, disconnect/restart, and teardown behavior.
- Repeated-run variation under controlled conditions.
- Collector overhead measured against an independent reference workload with and without collection; report the method and observed effect rather than claiming zero overhead.
- Gate behavior on complete captures, incompatible baselines, missing samples, and failures.

Physical Android and iOS validation remains pending; local macOS evidence does not establish either. Stable “Android and iOS” support requires evidence on both. Presentation FPS requires a native presentation-time backend and separate validation; this release measures Flutter frame work and cadence.

Keep release notes specific about what became verified. If a Flutter protocol change invalidates prior evidence, narrow the support claim until that version is tested.

[Contributing](../CONTRIBUTING.md) · [CI adoption](ci.md)
