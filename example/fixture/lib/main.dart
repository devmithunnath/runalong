import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:runalong_context/runalong_context.dart';
import 'reference_frames.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FixtureFrameReference.install();
  runApp(const FixtureApp());
}

class FixtureApp extends StatelessWidget {
  const FixtureApp({super.key});
  static final _contextObserver = RunalongNavigatorObserver();
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Runalong fixture',
    navigatorObservers: [if (RunalongContext.isEnabled) _contextObserver],
    theme: ThemeData(colorSchemeSeed: const Color(0xff006b5e)),
    home: const FixtureHome(),
  );
}

class FixtureHome extends StatefulWidget {
  const FixtureHome({super.key});
  @override
  State<FixtureHome> createState() => _FixtureHomeState();
}

class _FixtureHomeState extends State<FixtureHome> {
  bool _jank = const bool.fromEnvironment('FIXTURE_JANK');
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Runalong fixture')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.speed, size: 64),
              const SizedBox(height: 24),
              const Text(
                'One journey. Two rendering workloads.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Open the catalogue and run its animation. The switch adds '
                'deliberate CPU work to each animation frame.',
                textAlign: TextAlign.center,
              ),
              SwitchListTile(
                key: const ValueKey('jank-toggle'),
                title: const Text('Intentional jank'),
                value: _jank,
                onChanged: (value) => setState(() => _jank = value),
              ),
              FilledButton(
                key: const ValueKey('open-catalogue'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    settings: const RouteSettings(name: '/catalogue'),
                    builder: (_) => CatalogueScreen(jank: _jank),
                  ),
                ),
                child: const Text('Open catalogue'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({required this.jank, super.key});
  final bool jank;
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Catalogue')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            key: const ValueKey('run-animation'),
            onPressed: () => RunalongContext.operation<void>(
              stableId: 'catalogue.animate',
              label: 'Run catalogue animation',
              source: const RunalongSource(uri: 'lib/main.dart', line: 109),
              body: () => _controller.forward(from: 0),
            ),
            child: const Text('Run animation'),
          ),
        ),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            if (widget.jank && _controller.isAnimating) {
              // Deliberate benchmark fixture: never copy this into an app.
              final work = Stopwatch()..start();
              while (work.elapsedMicroseconds < 35000) {
                // Busy waiting makes this fixture predictably CPU-bound.
              }
            }
            return SizedBox(
              height: 100,
              child: Column(
                children: [
                  Transform.translate(
                    offset: Offset(
                      math.sin(_controller.value * math.pi * 8) * 90,
                      0,
                    ),
                    child: const Icon(Icons.shopping_bag, size: 48),
                  ),
                  Text(
                    _controller.isCompleted ? 'Animation complete' : 'Ready',
                    key: const ValueKey('animation-status'),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('catalogue-list'),
            itemCount: 100,
            itemBuilder: (context, index) => ListTile(
              leading: CircleAvatar(child: Text('${index + 1}')),
              title: Text('Product ${index + 1}'),
              subtitle: const Text('A deterministic local fixture'),
            ),
          ),
        ),
      ],
    ),
  );
}
