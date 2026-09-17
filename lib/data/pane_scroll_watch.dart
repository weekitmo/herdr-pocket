import 'dart:async';

import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/domain/workspace/pane_scroll_event.dart';

/// Live scroll state for ONE pane, as the daemon sees it.
///
/// WHY A SUBSCRIPTION RATHER THAN A RE-READ. The terminal screen has to correct
/// its own optimistic mirror, and there are three moments where only the daemon
/// knows the answer: the reader hit the top of the buffer, the pane had no
/// history to begin with, and new output arrived while the reader was parked in
/// history (the daemon anchors a scrolled view by growing its own offset). A
/// re-read on a timer would answer all three late and pay a round trip per
/// gesture; `pane.scroll_changed` is a per-pane event the daemon already emits,
/// and it carries the whole `{offset, max, viewport_rows}` object.
///
/// IT IS CHEAP AND IT IS RARE. The event fires when the scroll state CHANGES and
/// at no other time — measured against a live daemon: six scroll requests that
/// moved the viewport produced five events, and the one request that was refused
/// (past the end) produced none.
///
/// ONE SUBSCRIPTION, ONE PANE. The daemon's schema makes `pane_id` a required
/// field of this subscription kind, which is what allows a client to watch a pane
/// without receiving the scroll traffic of every pane on the machine.
///
/// [start] returns NULL rather than throwing when the daemon will not open it —
/// an older protocol, a refused kind, a machine that answers nothing. Degrading
/// to the client's own mirror is the old behaviour and is still correct for a
/// pane that is only being scrolled by this phone; a page that refused to open a
/// terminal because an optional correction channel was unavailable would be
/// trading a working screen for a pristine one.
class PaneScrollWatch {
  PaneScrollWatch._(this._subscription, this._states);

  /// Subscribes to [paneId]'s scroll changes.
  ///
  /// [client] is the caller's existing client, and the caller owns its lifetime;
  /// this opens a channel, not a connection.
  static Future<PaneScrollWatch?> start(
    HerdrClient client, {
    required String paneId,
  }) async {
    try {
      final sub = await client.subscribe([
        {'type': 'pane.scroll_changed', 'pane_id': paneId},
      ]);
      final states = StreamController<PaneScrollEvent>.broadcast();
      // The events for OTHER panes are dropped here rather than by the caller:
      // the subscription is per-pane, but a page that switched panes must never
      // see the pane it left move its mirror.
      final mine = sub.events
          .map(PaneScrollEvent.tryParse)
          .where((event) => event != null && event.paneId == paneId)
          .cast<PaneScrollEvent>();
      // Cancelled by [close], which is the object that owns it — the lint asks
      // for the cancel in the function that subscribes, and cannot see through
      // the constructor that hands it to the field.
      // ignore: cancel_subscriptions
      final listen = mine.listen(
        states.add,
        // A stream that errors here must not take the terminal with it: the
        // subscription is a correction channel, and losing it means the screen
        // keeps its own mirror, which is what it did before.
        onError: (Object _) {},
        onDone: () {
          if (!states.isClosed) unawaited(states.close());
        },
      );
      return PaneScrollWatch._(listen, states);
    } on Object {
      return null;
    }
  }

  final StreamSubscription<PaneScrollEvent> _subscription;
  final StreamController<PaneScrollEvent> _states;

  /// Authoritative scroll states, newest last.
  Stream<PaneScrollEvent> get states => _states.stream;

  /// Closes the channel. Safe to call twice: a page torn down mid-reconnect can
  /// easily do it twice, and the second call must not throw.
  Future<void> close() async {
    await _subscription.cancel();
    if (!_states.isClosed) await _states.close();
  }
}
