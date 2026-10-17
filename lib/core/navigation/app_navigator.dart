import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/router/router.dart';

/// The one seam non-widget code (providers, services, utils) is allowed to
/// use to reach the widget tree for navigation.
///
/// Providers and services should never import [navigatorKey] or `BuildContext`
/// directly — going through here keeps that coupling in one place instead of
/// scattered across the codebase, and gives it a spot to become
/// injectable/mockable later if a call site needs to be unit tested.
class AppNavigator {
  const AppNavigator._();

  /// Navigates to [location] from outside the widget tree. A no-op if there
  /// is currently no active navigator context (e.g. during startup).
  static void push(String location, {Object? extra}) {
    navigatorKey.currentContext?.push(location, extra: extra);
  }

  /// Shows a dialog above the current route from outside the widget tree,
  /// for example from a toast action. A no-op without a navigator context.
  static Future<T?> showAppDialog<T>(WidgetBuilder builder) async {
    final context = navigatorKey.currentContext;
    if (context == null) return null;
    return showDialog<T>(context: context, builder: builder);
  }
}
