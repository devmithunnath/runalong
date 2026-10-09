# Keep the tests; configure the runner

Runalong needs two things: an existing automation command and a reachable VM Service for the app being tested. It does not need your test to import a profiling package.

## Mode A: the app is already running

Launch a profile build on a physical phone or supported desktop:

```sh
flutter run --profile -d DEVICE_ID
```

Keep that process alive. Copy the VM Service URL printed by Flutter into a second terminal:

```sh
runalong run --vm-service-uri 'YOUR_VM_SERVICE_URL' \
  --output artifacts/smoke -- maestro test .maestro/smoke.yaml
```

The same pattern can wrap `appium`, a test executable, or a script. Supply the real command your project already uses. Runalong connects before starting it.

Make the automation interact with the existing app process. A launch/reinstall/reset step may invalidate the endpoint. If the process is replaced or capture disconnects, inspect the report's coverage status rather than assuming continuous capture.

## Mode B: the command launches the app

```sh
runalong run --connect-timeout 180 --timeout 300 \
  -- flutter drive --profile --no-dds \
     --driver=test_driver/integration_test.dart \
     --target=integration_test/journey_test.dart -d DEVICE_ID
```

Runalong discovers a VM Service URL in the wrapped command's output. If the runner hides the URL, use a URI file or an explicitly supplied endpoint instead. Do not assume every runner prints a discoverable URL.

A service connection established after app startup misses the preceding frames. This is useful diagnostic data but incomplete whole-journey measurement. A host driver that merely calls `FlutterDriver.connect()` does not eliminate that race: the driver can resume the app before returning.

## Mode C: endpoint file

`--vm-service-uri-file PATH` waits for a file containing the endpoint. Your launcher can write the actual service URL there. Use a fresh file for each launch and delete stale files before a run. Supply an HTTP(S) VM Service URL or its WebSocket equivalent.

Endpoint paths, authentication tokens, and forwarded ports may change between launches. Do not commit a live endpoint into a profile. When output discovery sees multiple distinct endpoints, capture stops instead of choosing an app; automation continues. Use an explicit endpoint or a dedicated URI file for runs that restart the app or print multiple service URLs.

## Runner expectations

| Runner | Integration boundary | Validation status |
| --- | --- | --- |
| Flutter `integration_test` through `flutter drive --profile` | Wrap the existing drive command; no test-source edits | Desktop fixture provided; consult validation log |
| Patrol | Wrap a command that exposes a profile-mode app endpoint, or attach to its app | Physical-device integration pending |
| Maestro | Start a Flutter profile app, attach, then run an existing flow against that process | Example flow provided; device run pending |
| Appium / custom runner | Attach to the profile app, then wrap the existing executable | Runner-specific validation pending |
| Flutter widget tests | No production engine/device rendering workload | Not supported for app performance conclusions |
| Release build | Dart VM Service unavailable | Not supported by this backend |
| Flutter web | Uses a different profiling backend | Not supported by this backend |

The executable boundary works independently of test syntax. Platform support, native permissions, device selection, and app lifecycle remain the runner's responsibility.

On Windows, Runalong resolves launchers through `PATH` and `PATHEXT`, including `flutter.bat` and `.cmd` tools. Native executable arguments are forwarded unchanged. Batch files use `cmd.exe`, so arguments or launcher paths containing shell metacharacters (`"`, `&`, `|`, `<`, `>`, `^`, `%`, `!`, parentheses, or newlines) are rejected explicitly; use a native executable or a reviewed launcher with fixed arguments in that case. This follows the [Dart process API's batch-file caveat](https://api.dart.dev/dart-io/Process/start.html). Native Windows execution remains pending the CI matrix.

## Connectivity

Use the service endpoint exposed by Flutter, including its authentication path. If DDS is enabled, use its reachable endpoint; it proxies VM Service requests. Do not disable authentication to simplify connection.

For physical devices, Flutter's tooling ordinarily manages forwarding. A service URL visible only on the device must be forwarded to the host. `--device-id` is capture metadata; include the runner's own device option in its command too.

## Passive observation only

```sh
runalong attach --vm-service-uri 'YOUR_VM_SERVICE_URL' \
  --duration 30 --output artifacts/manual
```

This records a bounded observation window without running an automation command. It cannot assert a functional test result or certify actions outside that window.
