import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/board_sync.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/transport/unix_socket_transport.dart';

/// Verifies the board's event subscription against a real daemon.
///
/// The important thing this proves is not that the code runs — it is that the
/// subscription LIST is one the daemon accepts. herdr has no wildcard and no
/// version negotiation, so a kind that does not exist is rejected as an
/// ordinary error, and a board built on a rejected subscription would quietly
/// fall back to its safety net and look like it was working.
///
/// READ-ONLY: it subscribes, reads nothing, and closes.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final socketPath = '$home/.config/herdr/herdr.sock';
  final ready = File(socketPath).existsSync();
  final skipReason = ready ? null : 'no herdr socket at $socketPath';

  group('board event subscription', () {
    test('the daemon accepts every kind we watch', () async {
      final client = HerdrClient(UnixSocketTransport(socketPath: socketPath));
      addTearDown(client.close);

      // If any kind in `watchedKinds` were wrong, this would throw rather than
      // return — which is exactly the failure a fallback would hide.
      final sync = await BoardSync.start(client);
      addTearDown(sync.close);

      expect(BoardSync.watchedKinds, isNotEmpty);
      print('  subscribed to ${BoardSync.watchedKinds.length} event kinds');
    }, skip: skipReason);

    test('the subscription opens and closes cleanly', () async {
      final client = HerdrClient(UnixSocketTransport(socketPath: socketPath));
      addTearDown(client.close);

      final sync = await BoardSync.start(client);

      // Deliberately NOT awaiting an event: an idle machine produces none, and
      // a test that waits for one would hang rather than fail. What matters is
      // that the channel is live (start() returned, which required the ack) and
      // that tearing it down does not throw.
      expect(sync.changes, isA<Stream<void>>());
      await sync.close();
      // Closing twice must be safe: a page disposed mid-reconnect can easily
      // call it twice.
      await sync.close();
    }, skip: skipReason);

    test('we do NOT watch pane.output_changed', () {
      // An agent printing to its terminal does not change the roster. Watching
      // output would turn the event stream back into a poll — one that fires on
      // every character instead of every three seconds.
      expect(BoardSync.watchedKinds, isNot(contains('pane.output_changed')));
    });

    test('we watch no pane-scoped kind, so no per-pane bookkeeping is needed',
        () {
      // Pane-scoped kinds require an explicit pane_id and offer no wildcard, so
      // watching one would mean re-subscribing every time a pane appears — and
      // a newly created agent would be invisible until someone remembered to.
      // Status changes arrive globally as pane.updated instead.
      const paneScoped = {
        'pane.agent_status_changed',
        'pane.scroll_changed',
        'pane.output_matched',
      };
      for (final kind in paneScoped) {
        expect(
          BoardSync.watchedKinds,
          isNot(contains(kind)),
          reason: '$kind would need a per-pane subscription',
        );
      }
    });
  });
}
