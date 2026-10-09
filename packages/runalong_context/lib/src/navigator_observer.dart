import 'package:flutter/widgets.dart';

import 'context.dart';

typedef RunalongRouteNameResolver = String? Function(Route<dynamic> route);

/// Tracks the top route in one Navigator. Use a separate instance per Navigator.
/// Route arguments are never read. Nested Navigators can declare [parentScreenId].
final class RunalongNavigatorObserver extends NavigatorObserver {
  RunalongNavigatorObserver({this.routeNameResolver, this.parentScreenId});

  final RunalongRouteNameResolver? routeNameResolver;
  final String? parentScreenId;
  Route<dynamic>? _activeRoute;
  RunalongScreenScope? _scope;

  void _activate(Route<dynamic>? route) {
    if (identical(_activeRoute, route)) return;
    _scope?.end();
    _scope = null;
    _activeRoute = route;
    if (route == null || !RunalongContext.isEnabled) return;
    final routeName = route.settings.name?.split(RegExp(r'[?#]')).first.trim();
    String? name;
    try {
      name = routeNameResolver?.call(route) ?? route.settings.name;
    } catch (_) {
      // A metadata resolver must not interrupt navigation.
    }
    name = name?.split(RegExp(r'[?#]')).first.trim();
    final label = name == null || name.isEmpty ? 'Unnamed route' : name;
    _scope = RunalongContext.startScreen(
      stableId:
          'route:${routeName == null || routeName.isEmpty ? label : routeName}',
      label: label,
      parentId: parentScreenId,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _activate(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, _activeRoute)) _activate(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, _activeRoute)) _activate(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, _activeRoute)) _activate(newRoute);
  }

  /// Ends this observer's interval when its Navigator is permanently removed.
  void close() => _activate(null);
}
