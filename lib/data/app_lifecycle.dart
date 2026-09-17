import 'package:flutter/widgets.dart';

/// Calls back when the app comes back to the foreground.
///
/// WHY THE CONNECTION NEEDS TO KNOW. A phone that goes to the background is a
/// phone whose process the OS may freeze, and a frozen process runs no Dart:
/// the SSH keepalive stops being written, and the link dies quietly on whatever
/// is in the middle — a NAT table, a cellular handover, or the virtual overlay
/// network this app is often reached through. Nothing on this side is told. The
/// socket still looks open to the code holding it, because as far as the local
/// kernel is concerned nothing has happened yet.
///
/// So "the user is back" is the one moment where a health check is both cheap
/// and worth doing: the answer is needed now, and getting it wrong is the
/// difference between a screen that works and a screen that says "connected"
/// while every request fails.
///
/// A class rather than an inline observer so the connection notifier can own
/// exactly one, start it when it dials and remove it when it is disposed —
/// a leaked observer outlives the provider that added it.
class AppResumeWatcher with WidgetsBindingObserver {
  AppResumeWatcher(this.onResumed);

  final void Function() onResumed;

  bool _watching = false;

  /// Whether there is a binding to observe at all.
  ///
  /// A plain `test()` under `flutter_test` has no widget tree and no binding,
  /// and `WidgetsBinding.instance` THROWS rather than returning null. The
  /// connection provider is exercised by unit tests like that, so the check is
  /// here rather than at every call site — and being inert is the honest
  /// answer: with no app there is nothing that can come back to the foreground.
  static bool get _hasBinding {
    try {
      WidgetsBinding.instance;
      return true;
    } on Object {
      return false;
    }
  }

  void start() {
    if (_watching || !_hasBinding) return;
    _watching = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    if (!_watching) return;
    _watching = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}
