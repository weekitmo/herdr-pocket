import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/lock/lock_page.dart';

/// The lock screen, when there is one.
///
/// ## It is an overlay, not a route
///
/// The app root puts this in a `Stack` ABOVE the navigator (see
/// `herdr_pocket_app.dart`). A lock that lives inside the navigator — as its
/// `home`, which is where this started — is covered by whatever the app pushes
/// over it, and the app pushes routes from outside its own UI: a notification
/// tap opens a terminal directly. Putting the lock above the navigator means
/// there is nothing the app can navigate to that the user can see without the
/// PIN, while the route itself still arrives underneath and is simply waiting
/// once they are in.
///
/// ## The three states, and why the first one paints only the ground
///
/// Reading the keystore is asynchronous, so for a few milliseconds the app does
/// not know whether it is locked. Painting the app during that window would show
/// whatever is behind the lock — the board, with the user's projects on it — for
/// a frame or two on every cold start. So the gate paints the ground and nothing
/// else until it has an answer.
///
/// ## What counts as leaving
///
/// `paused` and `hidden`, not `inactive`. On Android the system's own biometric
/// prompt pauses this activity, and treating that as "the user left the app"
/// would relock the app in the middle of unlocking it. The grace period covers
/// the rest: a prompt that takes a minute is still well inside five.
///
/// ## A keystore that cannot be read does not brick the app
///
/// The error branch gets out of the way. It is a real trade-off and it is
/// written down rather than hidden: failing closed would mean a corrupt keystore
/// locks the user out of their own app with no way back — and the same
/// corruption that makes the record unreadable also exposes the SSH keys it
/// protects, so it is not a threat the lock screen was ever going to stop.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  /// When the app went to the background, if it is there now.
  DateTime? _awaySince;

  @override
  void initState() {
    super.initState();
    // INSTALLED FOR THE LIFE OF THE APP, and the widget is never removed from
    // the tree even while the app is unlocked — a watcher that only existed
    // while the lock was up would have nothing to measure the absence with.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _awaySince ??= DateTime.now();
      case AppLifecycleState.resumed:
        final away = _awaySince;
        _awaySince = null;
        if (away == null) return;
        // THE DECISION LIVES IN THE NOTIFIER; this only measures. That is what
        // makes the five minutes testable without waiting five minutes.
        ref
            .read(appLockProvider.notifier)
            .resumeAfter(DateTime.now().difference(away));
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    return ref
        .watch(appLockProvider)
        .when(
          loading: () => ColoredBox(
            color: colors.ground,
            child: const SizedBox.expand(),
          ),
          // See the class comment: a lock that cannot read its own record gets
          // out of the way.
          error: (_, _) => const SizedBox.shrink(),
          data: (state) =>
              state.locked ? const LockPage() : const SizedBox.shrink(),
        );
  }
}
