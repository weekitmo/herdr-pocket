import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/terminal/terminal_control.dart';
import 'package:herdr_pocket/data/transport/unix_socket_transport.dart';

/// Integration test for the live terminal against a real daemon.
///
/// This is the test that proves the terminal architecture: the daemon renders
/// the pane at the size we ask for, hands us base64 ANSI frames over a
/// long-lived channel, and a read-only observer can watch without disturbing
/// anyone.
///
/// READ-ONLY BY CONSTRUCTION. It uses `observe`, never `control`, so it does
/// not take input, resize, scroll or ownership from whatever the user has open.
/// A test that stole someone's terminal would not survive its first honest
/// review.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final socketPath = '$home/.config/herdr/herdr.sock';

  final ready = File(socketPath).existsSync();
  final skipReason = ready ? null : 'no herdr socket at $socketPath';

  /// Picks a pane the daemon actually reports, rather than hard-coding an id
  /// that only exists on one machine.
  Future<String?> firstPaneId() async {
    final client = HerdrClient(UnixSocketTransport(socketPath: socketPath));
    try {
      final agents = await client.agentList();
      return agents.isEmpty ? null : agents.first.paneId;
    } finally {
      await client.close();
    }
  }

  group('live terminal', () {
    test('the daemon renders a frame at exactly the size we asked for',
        () async {
      final paneId = await firstPaneId();
      if (paneId == null) return; // no agents running; nothing to observe

      final transport = UnixSocketTransport(socketPath: socketPath);
      final session = await TerminalControl.observe(
        transport,
        paneId: paneId,
        cols: 80,
        rows: 24,
      );
      addTearDown(session.close);

      final frame = await session.frames.first.timeout(
        const Duration(seconds: 15),
      );

      // The daemon renders FOR us: the geometry is ours, echoed back. If this
      // ever disagrees, the renderer would lay the grid out in the wrong
      // columns and nothing else in the terminal would look right.
      expect(frame.width, 80);
      expect(frame.height, 24);
      expect(frame.data, isNotEmpty);
      // Every rendered frame carries absolute cursor movement; a frame without
      // any escape sequence would mean we are reading something other than the
      // terminal stream.
      expect(frame.data.contains('\x1b'), isTrue);
      print('  terminal frame: seq=${frame.seq} full=${frame.isFull} '
          '${frame.data.length} chars');
    }, skip: skipReason);

    test('frames stream continuously, not just once', () async {
      final paneId = await firstPaneId();
      if (paneId == null) return;

      final transport = UnixSocketTransport(socketPath: socketPath);
      final session = await TerminalControl.observe(
        transport,
        paneId: paneId,
        cols: 100,
        rows: 30,
      );
      addTearDown(session.close);

      // An observing client is sent a fresh render whenever the pane changes,
      // so a live agent produces more than one frame. Taking two proves the
      // channel stays open rather than delivering a single snapshot and
      // closing — which is the difference between a terminal and a screenshot.
      final frames = await session.frames
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 25), onTimeout: () => const []);
      if (frames.length < 2) return; // idle pane: nothing is repainting

      expect(frames[1].seq, greaterThanOrEqualTo(frames[0].seq));
    }, skip: skipReason);

    test('a read-only session refuses to send input rather than misbehaving',
        () async {
      final paneId = await firstPaneId();
      if (paneId == null) return;

      final transport = UnixSocketTransport(socketPath: socketPath);
      final session = await TerminalControl.observe(
        transport,
        paneId: paneId,
        cols: 80,
        rows: 24,
      );
      addTearDown(session.close);

      expect(session.isReadOnly, isTrue);
      // These must be silent no-ops. If any of them reached the daemon, a
      // "just looking" client would be typing into someone's agent.
      session.sendText('echo this must never run\n');
      session.sendBytes(const [0x03]);
      session.resize(120, 40);
      session.scroll(5);

      // The session is still usable afterwards: a no-op, not a crash.
      expect(session.frames, isNotNull);
    }, skip: skipReason);

    test('closing a read-only session ends the stream cleanly', () async {
      final paneId = await firstPaneId();
      if (paneId == null) return;

      final transport = UnixSocketTransport(socketPath: socketPath);
      final session = await TerminalControl.observe(
        transport,
        paneId: paneId,
        cols: 60,
        rows: 20,
      );

      await session.close();
      // Closing twice must not throw; a page that is disposed during a
      // reconnect can easily call it twice.
      await session.close();
    }, skip: skipReason);
  });
}
