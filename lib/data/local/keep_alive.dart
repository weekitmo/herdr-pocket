import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/frame_phase.dart';
import 'package:herdr_pocket/data/providers/connection.dart';

/// Holds this app's process alive while it is in the background.
///
/// ## Why the policy is here and the mechanism is not
///
/// Android freezes a backgrounded app's process, and a frozen process writes no
/// Dart — which means no SSH keepalive, and a connection that dies in the
/// middle (a NAT table, a cellular handover, an overlay network re-routing)
/// with neither end told. A foreground service is the only Android mechanism
/// for that, and it is a PLATFORM thing: `KeepAliveService.kt` starts and stops
/// it, `MethodChannel` carries the two calls.
///
/// What is decided here is *when* — and that is a question about connection
/// state, which lives in this app's own providers. So the split is: this file
/// says yes or no, Kotlin does it.
/// NOT CALLED `KeepAlive`: Flutter's own widget library exports a
/// `KeepAlive` widget, and the two would collide as an ambiguous import in
/// every file that needs both — the same trap `SoftKey` was named around.
abstract interface class ProcessKeeper {
  /// Whether this platform can hold a process awake at all.
  ///
  /// ASKED BEFORE THE SWITCH IS DRAWN, not after it is flipped. This is the
  /// difference between a control and a decoration: on a platform whose answer
  /// is no, there is nothing the user can decide, and a switch that changes a
  /// stored boolean without changing anything about the connection is the app
  /// telling them something untrue about their own phone.
  ///
  /// True on Android, where a foreground service exists for exactly this.
  /// False on iOS, where the background modes are a closed list (audio,
  /// location, voip, fetch, processing, accessory) and none of them means
  /// "hold an arbitrary TCP connection open". `beginBackgroundTask` is the
  /// nearest thing and buys about thirty seconds, which is a different feature
  /// with a different promise, not a weaker version of this one.
  bool get isSupported;

  /// Holds the process alive, with a notification saying [title] / [text].
  ///
  /// Returns false when the platform refused — a missing notification
  /// permission, or an OEM that forbids starting a foreground service from the
  /// background. False is not an error: the app works exactly as it did before
  /// this feature, which is the fallback the caller reports.
  Future<bool> start({required String title, required String text});

  Future<void> stop();
}

/// The real one: a MethodChannel to `KeepAliveService`.
///
/// Everywhere that is not Android this is a no-op that reports "not held" — a
/// desktop build has no process freezer to fight, and pretending otherwise
/// would put a platform channel in the way of every test on the laptop.
class PlatformKeepAlive implements ProcessKeeper {
  const PlatformKeepAlive();

  static const MethodChannel channel =
      MethodChannel('dev.maddax.herdrpocket/keep_alive');

  /// Android only — see the interface.
  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<bool> start({required String title, required String text}) async {
    if (!Platform.isAndroid) return false;
    try {
      await channel.invokeMethod<void>('start', {
        'title': title,
        'text': text,
      });
      return true;
    } on Object {
      // A platform that says no (no notification permission, an OEM that blocks
      // background starts) is not a failure of this app: the connection still
      // works while the app is in the foreground, and the resume-time health
      // check still recovers it afterwards.
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>('stop');
    } on Object {
      // Nothing to do: the service either is not running or is about to be
      // killed with this process anyway.
    }
  }
}

/// Whether the process should be held alive for this connection state.
///
/// THE ONE RULE, and it is about what the user asked for rather than about what
/// is convenient:
///
///   * **Online** — yes, if the switch is on. This is the feature: leave the app
///     and the connection stays.
///   * **A recovery** — yes. This is the case that makes the difference between
///     a feature and a half-feature. A frozen app runs no timers, so the slow
///     retry rounds for a machine that is asleep would never fire while the user
///     is in another app; holding the process is what lets the app come back by
///     itself instead of on the next tap.
///   * **A failure that will not be retried** — no. Nothing is scheduled, so a
///     notification saying the connection is being kept would be false.
///   * **Disconnected, or a first dial** — no. Nobody has a connection to keep.
bool keepAliveWanted({
  required bool enabled,
  required ConnectionStatus? status,
  bool sessionOpen = false,
}) {
  if (!enabled) return false;
  // A page holding its own live session — the SSH shell page — is reason
  // enough on its own. That page is the one a user reaches for on a machine
  // with no herdr at all, so "the herdr connection is down" says nothing about
  // whether there is a connection worth keeping.
  if (sessionOpen) return true;
  return switch (status) {
    Online() => true,
    Connecting(afterLoss: true) => true,
    ConnectionFailed(afterLoss: true, willRetry: true) => true,
    _ => false,
  };
}

/// Pages that are holding a connection of their own, by id.
///
/// The herdr connection is the one this app owns globally, but it is not the
/// only long-lived thing here: `ui/pages/shell/` dials a plain SSH session and
/// keeps it for as long as the page is open. That session belongs to the page,
/// so the page registers it here rather than the policy reaching into a widget.
///
/// Ids rather than a counter: two pages holding the same id (a rebuild, a
/// re-open) must not add up to two holds that only one close can release.
class KeepAliveHolders extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void hold(String id) => _update(
        (held) => held.contains(id) ? null : {...held, id},
      );

  void release(String id) => _update(
        (held) => held.contains(id) ? ({...held}..remove(id)) : null,
      );

  /// Writes the set, but never from inside a frame's callback phases.
  ///
  /// THE PAGE THAT HOLDS A SESSION RELEASES IT FROM `dispose`, and that runs in
  /// the unmount pass at the end of a frame — see [runOutsideFrame]. Writing
  /// this state from there does not merely do nothing: it sets the build
  /// owner's "a frame is already scheduled" flag without asking for one, and
  /// from then on nothing in the process can schedule a frame again. The app
  /// still takes taps, still runs their callbacks, still changes its state, and
  /// never repaints — found on the phone as "after closing the shell page the
  /// board is dead to the touch".
  ///
  /// [next] returns null for "no change", which has to be decided at the
  /// moment of the write rather than before it: the deferred write runs a frame
  /// later, by which time the set may have moved on.
  void _update(Set<String>? Function(Set<String> held) next) {
    runOutsideFrame(() {
      // The deferred write can outlive its container: a test tears the scope
      // down the moment the page is gone, and a write to a provider that no
      // longer exists is not a missing hold — it is nothing left to say.
      if (!ref.mounted) return;
      final updated = next(state);
      if (updated == null) return;
      state = updated;
    });
  }
}

final keepAliveHoldersProvider =
    NotifierProvider<KeepAliveHolders, Set<String>>(KeepAliveHolders.new);

/// The seam, swappable in tests.
final processKeeperProvider =
    Provider<ProcessKeeper>((ref) => const PlatformKeepAlive());

/// The one controller this process uses.
///
/// A provider rather than a field on a widget: the "already held" state has to
/// outlive every rebuild, and two controllers would each believe they were the
/// only one talking to the service.
final keepAliveControllerProvider = Provider<KeepAliveController>(
  (ref) => KeepAliveController(ref.watch(processKeeperProvider)),
);

/// Starts or stops the service to match [status].
///
/// Idempotent and cheap from the caller's side: the platform call is only made
/// when the ANSWER changes, which is what keeps a reconnect (several status
/// writes) from restarting the service several times.
class KeepAliveController {
  KeepAliveController(this._keeper);

  final ProcessKeeper _keeper;

  bool? _held;

  /// True when the platform is currently holding the process for us.
  ///
  /// Read by the settings row: "on" and "actually held" are different facts,
  /// and a row that shows only the first is a row that lies on a phone whose
  /// notification permission is off.
  bool get isHeld => _held ?? false;

  /// Reconciles the service with [status].
  ///
  /// Returns true when the platform is holding the process afterwards.
  Future<bool> sync({
    required bool enabled,
    required ConnectionStatus? status,
    required String title,
    required String text,
    bool sessionOpen = false,
  }) async {
    final wanted = keepAliveWanted(
      enabled: enabled,
      status: status,
      sessionOpen: sessionOpen,
    );
    // NEVER ASKED IS THE SAME AS NOT HELD, for the purpose of deciding whether
    // the platform has to be called. The first status a dial publishes is
    // `Connecting`, where nothing should be held — and treating "we have no
    // opinion yet" as a change would fire a `stop` at the platform before a
    // single connection existed. Harmless on the phone, noise on the wire, and
    // it makes "one start, one stop" untestable.
    if (wanted == (_held ?? false)) return isHeld;

    if (wanted) {
      // Recorded BEFORE the await, so two syncs racing (a reconnect writes
      // several states) cannot both decide to start.
      _held = true;
      final ok = await _keeper.start(title: title, text: text);
      if (!ok) _held = false;
      return isHeld;
    }

    _held = false;
    await _keeper.stop();
    return false;
  }
}
