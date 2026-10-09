# runalong_context

Optional Flutter context for Runalong. The recorder still works without this
package; this helper adds explicit screen intervals, named operations and declared
source locations. It supports Dart 3.7+ and Flutter 3.29+.

It is disabled by default. Enable a debug or profile capture with
`--dart-define=RUNALONG_CONTEXT=true`. Release builds never emit context events.

```dart
import 'package:runalong_context/runalong_context.dart';

// Keep one observer instance for the lifetime of each Navigator.
final observer = RunalongNavigatorObserver();
MaterialApp(navigatorObservers: [observer]);

// Preserve RouteSettings when constructing routes.
MaterialPageRoute(settings: settings, builder: (_) => const CatalogueScreen());

final products = await RunalongContext.operation(
  stableId: 'catalogue.load',
  label: 'Load catalogue',
  source: const RunalongSource(uri: 'lib/catalogue/controller.dart', line: 42),
  body: () => repository.loadProducts(),
);
```

Use `operationSync` for synchronous work. Nested operations inherit parent IDs
through asynchronous Dart Zones. Values, synchronous throws and asynchronous
errors are propagated; event-transport errors are ignored. Every invocation gets
a distinct occurrence ID; reuse stable IDs across runs to compare the same work.
An operation's duration includes waits: it is a declared interval, **not CPU time**.
An `error` end means an exception escaped the wrapper. A handled business failure
can end with `success`; the helper does not inspect return values.

For tabs or nested screen areas, explicitly start and end visible scopes:

```dart
final shell = RunalongContext.startScreen(stableId: 'shell', label: 'App shell');
final tab = RunalongContext.startScreen(
  stableId: 'catalogue.tab', label: 'Catalogue tab', parentId: shell.id,
);
await tab.run(() => RunalongContext.operation(
  stableId: 'catalogue.refresh', label: 'Refresh catalogue',
  body: () => repository.refresh(),
));
tab.end(); // On hide/dispose. Idempotent; children must be ended explicitly.
shell.end();
```

Observers mark the top route in their own Navigator, ending a covered route and
starting a new occurrence when it becomes top again. Dialogs and unnamed routes
are intervals too; unnamed routes are labelled “Unnamed route”. For nested
Navigators pass `parentScreenId` and use a separate observer. Call `close()` when
permanently removing that Navigator. An optional `routeNameResolver` can supply a
static human-readable label; a named route retains its original route name as its
stable identity. These intervals mark navigation callbacks, not exact
pixel visibility or transition completion.

Use only static developer-authored IDs and labels. Route arguments are never read;
route query strings/fragments are removed. Do not put user input, identifiers,
tokens, responses or exception messages in a label or route path. Source locations
accept relative paths and `package:` URIs, and are labelled `provenance: declared`;
they identify the chosen annotation, not a profiler-proven cause.

The helper emits `dart:developer.postEvent('Runalong.Context', …)` with `version: 1`,
`event`, occurrence `id`, `stableId`, `label`, `vmMicros: Timeline.now`, optional
`parentId`, `screenId`, `source`, and `status` on end events. The event names are
`screen_start`, `screen_end`, `operation_start`, `operation_end`. Operation end
statuses are `success` or `error`; screen end status is `ended`. IDs are scoped to
the emitting isolate by the recorder. IDs are capped at 128 characters, labels at
200, and source URIs at 512. No arguments, results or error payloads are emitted.

When enabled, the first context interval also registers the read-only service
extension `ext.runalong.context`. It returns `{version: 1, screens: [...],
operations: [...]}` containing only currently open start records, preserving their
original occurrence IDs and VM timestamps. A recorder that attaches late can
recover active context, but cannot recover intervals that already ended.

Run tests with `flutter test`. The test-only `debugConfigure` hook captures events
without a VM connection; it cannot activate a release build.
