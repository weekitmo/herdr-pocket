import 'dart:async';

import 'package:herdr_pocket/data/herdr_client.dart';

/// Keeps the board current without polling.
///
/// THE ORDERING IS THE WHOLE POINT. Subscribe first, then read. Doing it the
/// other way round leaves a gap: a change that lands after the read and before
/// the subscription is never seen, and because it was never seen there is
/// nothing to retry — the board is simply wrong until the next unrelated
/// change happens to correct it. Subscribing first means such a change arrives
/// as an event, and the worst case becomes a redundant refresh rather than a
/// silent one.
///
/// WHAT WE SUBSCRIBE TO, AND WHY IT IS ONLY GLOBAL KINDS: the three pane-scoped
/// kinds (`pane.agent_status_changed`, `pane.scroll_changed`,
/// `pane.output_matched`) each require an explicit `pane_id` and there is no
/// wildcard — watching N panes means N entries plus a re-subscribe every time a
/// pane appears. But status changes also arrive GLOBALLY as `pane.updated`, so
/// the board needs none of that bookkeeping. The subscription list is fixed for
/// the life of the connection, which removes a whole class of bug where a newly
/// created agent is invisible because nobody remembered to subscribe to it.
class BoardSync {
  BoardSync._(this._subscription, this._changes);

  /// Event kinds that mean the board's contents may have changed.
  ///
  /// Deliberately NOT `pane.output_changed`: an agent printing to its terminal
  /// does not change the roster, and re-reading the whole board on every
  /// character of output would be a polling loop wearing an event's clothes.
  static const watchedKinds = <String>[
    'pane.created',
    'pane.closed',
    'pane.updated',
    'pane.exited',
    'pane.moved',
    'pane.agent_detected',
    'pane.focused',
    'tab.created',
    'tab.closed',
    'workspace.created',
    'workspace.closed',
  ];

  final StreamSubscription<String> _subscription;
  final StreamController<void> _changes;

  /// Fires when the board should be re-read. Already debounced.
  Stream<void> get changes => _changes.stream;

  /// Subscribes, waits for the acknowledgement, and returns.
  ///
  /// Awaiting the ack is what makes the subsequent read safe: once the daemon
  /// has confirmed the subscription exists, every later change is queued for us
  /// rather than missed. Reading before this returns would reintroduce exactly
  /// the gap this class exists to close.
  static Future<BoardSync> start(HerdrClient client) async {
    final sub = await client.subscribe([
      for (final kind in watchedKinds) <String, Object?>{'type': kind},
    ]);

    // One notification per burst. A single agent transition can produce several
    // events (status, then focus, then layout), and each one would otherwise be
    // a separate round trip that the daemon has to answer.
    final changes = StreamController<void>.broadcast();
    Timer? debounce;
    void notify() {
      if (changes.isClosed) return;
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 220), () {
        if (!changes.isClosed) changes.add(null);
      });
    }

    final subscription = sub.events.listen(
      (line) {
        final event = parseEventEnvelope(line);
        if (event == null) return;
        if (!watchedKinds.contains(event.kind)) return;
        notify();
      },
      onError: (Object _) {},
      onDone: () {
        debounce?.cancel();
        unawaited(changes.close());
      },
    );

    return BoardSync._(subscription, changes);
  }

  Future<void> close() async {
    await _subscription.cancel();
    if (!_changes.isClosed) await _changes.close();
  }
}
