import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/terminal/terminal_control.dart';
import 'package:herdr_pocket/data/transport/unix_socket_transport.dart';
import 'package:herdr_pocket/domain/workspace/pane_scroll_event.dart';

/// WHAT THE DAEMON ACTUALLY DOES WHEN YOU SCROLL, measured — not guessed.
///
/// The terminal screen keeps a client-side mirror of "how far back the reader
/// is" (`offset_from_bottom`), and it advances that mirror by whatever it ASKED
/// for rather than by what the far end DID. That is why the "already scrolled
/// back N lines" bar can appear on a pane that has no history at all: the
/// question "is there anything behind me?" is not answerable from a rendered
/// frame, and the client was not asking anyone.
///
/// `pane.list` reports a `scroll` object with `offset_from_bottom` AND
/// `max_offset_from_bottom`, and `pane.scroll_changed` is a real subscription
/// kind. This file measures what those mean in practice so the fix is built on
/// facts:
///
///   1. does an in-session `terminal.scroll` move the pane-level offset?
///   2. does the daemon clamp a request past the end, or accept a lie?
///   3. does a pane with no history refuse to move at all?
///   4. does `pane.scroll_changed` fire for a scroll the session asked for?
///
/// WRITES, SO IT IS GATED. It creates its own workspace (unfocused), fills it
/// with `seq`, and closes it in `tearDown` — the same discipline as
/// `live_writes_test.dart`, whose comment explains why anything that touches a
/// live daemon has to be opt-in:
///
/// ```sh
/// HERDR_POCKET_LIVE_WRITES=1 flutter test test/integration/scroll_probe_test.dart
/// ```
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final socketPath = '$home/.config/herdr/herdr.sock';
  final socketExists = File(socketPath).existsSync();
  final requested = Platform.environment['HERDR_POCKET_LIVE_WRITES'] == '1';
  final skipReason = !socketExists
      ? 'no herdr socket at $socketPath'
      : !requested
          ? 'set HERDR_POCKET_LIVE_WRITES=1 to run the scroll probe'
          : null;

  /// The number the app's "jump to live" asks for, copied from
  /// `_jumpToBottomLines` — the largest value `terminal.scroll` accepts.
  const jumpDownLines = 65535;

  UnixSocketTransport transport() =>
      UnixSocketTransport(socketPath: socketPath);

  /// Waits until the daemon reports a condition, or gives up.
  ///
  /// Polling rather than sleeping a fixed amount: the renderer is asynchronous,
  /// and a probe whose timing is baked in reports the machine's load rather
  /// than the daemon's behaviour.
  Future<({int? offset, int? max, int? rows})> scrollOf(
    HerdrClient client,
    String paneId, {
    bool Function(({int? offset, int? max, int? rows}) state)? until,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    ({int? offset, int? max, int? rows}) last = (offset: null, max: null, rows: null);
    while (DateTime.now().isBefore(deadline)) {
      final panes = await client.paneList();
      final mine = panes.where((p) => p.paneId == paneId);
      if (mine.isNotEmpty) {
        final p = mine.first;
        last = (
          offset: p.scrollOffsetFromBottom,
          max: p.scrollMaxOffsetFromBottom,
          rows: p.viewportRows,
        );
        if (until == null || until(last)) return last;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return last;
  }

  /// Waits until the pane stops producing output.
  ///
  /// THIS IS NOT FUSSINESS. Measured: the daemon ANCHORS a scrolled view — as
  /// lines arrive below, it grows `offset_from_bottom` so the reader keeps
  /// looking at the same text. A measurement taken while a command is still
  /// printing therefore reports the anchoring on top of the scroll, and the
  /// assertion reads "asked for 15, got 18". Waiting for the maximum to stop
  /// moving separates the two effects.
  Future<({int? offset, int? max, int? rows})> settle(
    HerdrClient client,
    String paneId,
  ) async {
    var previous = -1;
    var state = await scrollOf(client, paneId);
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      state = await scrollOf(client, paneId);
      if (state.max == previous) return state;
      previous = state.max ?? -1;
    }
    return state;
  }

  group('live probe: what scrolling does to a real pane', () {
    late HerdrClient client;
    late String workspaceId;
    late String paneId;
    late Directory dir;

    setUp(() async {
      if (skipReason != null) return;
      client = HerdrClient(transport());
      dir = Directory.systemTemp.createTempSync('herdr-pocket-scroll-');
      final created = await client.workspaceCreate(
        cwd: dir.path,
        label: 'pocket scroll probe',
      );
      workspaceId = created.workspaceId!;
      paneId = created.paneId!;
    });

    tearDown(() async {
      if (skipReason != null) return;
      try {
        await client.transport.roundTrip(
          '{"id":"cleanup","method":"workspace.close",'
          '"params":{"workspace_id":"$workspaceId"}}',
        );
      } on Object {
        // Best effort; the assertions that matter have already run.
      }
      await client.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('a pane with no history cannot be scrolled, and says so', () async {
      // A brand-new pane: the shell has printed its prompt and nothing else.
      final before = await scrollOf(client, paneId);
      print('  fresh pane: $before');
      final max = before.max;
      expect(max, isNotNull, reason: 'the daemon reports max_offset_from_bottom');

      final session = await TerminalControl.open(
        transport(),
        paneId: paneId,
        cols: 80,
        rows: 24,
      );
      addTearDown(session.close);
      await session.frames.first.timeout(const Duration(seconds: 15));

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final freshMax = (await scrollOf(client, paneId)).max!;
      print('  fresh pane after attach: max=$freshMax');

      // The question the client could not answer before this probe: with no
      // history, does an up-scroll move the pane at all?
      session.scroll(20);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final after = await scrollOf(client, paneId);
      print('  after scroll(20) on a pane with max=$freshMax: $after');

      expect(
        after.offset,
        lessThanOrEqualTo(freshMax),
        reason: 'the daemon must not report being further back than it can go',
      );
    }, skip: skipReason);

    test('the offset the daemon reports is the one the session asked for',
        () async {
      final session = await TerminalControl.open(
        transport(),
        paneId: paneId,
        cols: 80,
        rows: 24,
      );
      addTearDown(session.close);
      await session.frames.first.timeout(const Duration(seconds: 15));

      // Build real history: 400 lines through a real shell, then let it stop.
      session.sendText('seq 1 400\r');
      final grown = await settle(client, paneId);
      print('  after seq: $grown');
      expect(grown.max, greaterThan(100), reason: 'seq should create scrollback');

      // 1. DOES AN IN-SESSION SCROLL MOVE THE PANE-LEVEL OFFSET? Everything the
      // app does about the scroll bar depends on the answer being yes: the
      // daemon's `pane.list` and its `pane.scroll_changed` events are the only
      // place the true position is ever written down.
      session.scroll(15);
      final asked = await scrollOf(
        client,
        paneId,
        until: (s) => (s.offset ?? 0) != 0,
        timeout: const Duration(seconds: 3),
      );
      print('  after scroll(15): $asked');
      expect(
        asked.offset,
        15,
        reason: 'terminal.scroll is mirrored in pane.list',
      );

      // 2. PAST THE END IT CLAMPS. This is the measurement the fix rests on: the
      // far end refuses to go further, so a client that counts what it ASKED for
      // counts to a place that does not exist.
      session.scroll(1000);
      final clamped = await scrollOf(
        client,
        paneId,
        until: (s) => (s.offset ?? 0) >= (s.max ?? 0),
        timeout: const Duration(seconds: 5),
      );
      print('  after scroll(1000): $clamped');
      expect(
        clamped.offset,
        clamped.max,
        reason: 'the far end clamps at the top of the buffer',
      );

      // Asking again from the top must not move it — which is also why a
      // refusal produces no event, and why an event can be trusted to mean
      // "something moved" rather than "something was attempted".
      session.scroll(500);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final still = await scrollOf(client, paneId);
      print('  after another scroll at the top: $still');
      expect(still.offset, clamped.max);

      // 3. And back down. A 5-line nudge first, because this is the step that
      // proves the direction encoding rather than the clamp.
      session.scroll(-5);
      final down = await scrollOf(
        client,
        paneId,
        until: (s) => (s.offset ?? 0) < (s.max ?? 0),
        timeout: const Duration(seconds: 3),
      );
      print('  after scroll(-5): $down');
      expect(down.offset, clamped.max! - 5);

      // ...then the number the app's "jump to live" actually sends, which has to
      // reach the live bottom: it is a u16, so it is the largest value that is
      // not rejected outright.
      session.scroll(-jumpDownLines);
      final bottom = await scrollOf(
        client,
        paneId,
        until: (s) => s.offset == 0,
        timeout: const Duration(seconds: 5),
      );
      print('  after scroll(-$jumpDownLines): $bottom');
      expect(
        bottom.offset,
        0,
        reason: 'the number the app jumps down with must reach the bottom',
      );

      // 4. AND THE CEILING IS THE PROTOCOL'S, not a preference: anything larger
      // than a u16 is rejected outright and the viewport does not move, which is
      // why "jump to live" is a constant and not "as far as we think we are".
      session.scroll(-(jumpDownLines + 1));
      session.scroll(30);
      final moved = await scrollOf(
        client,
        paneId,
        until: (s) => (s.offset ?? 0) != 0,
        timeout: const Duration(seconds: 3),
      );
      // The rejected request moved nothing; the one after it still works, so a
      // refused value is not a broken session.
      expect(moved.offset, 30);
    }, skip: skipReason);

    test('pane.scroll_changed fires for a scroll the session asked for',
        () async {
      final session = await TerminalControl.open(
        transport(),
        paneId: paneId,
        cols: 80,
        rows: 24,
      );
      addTearDown(session.close);
      await session.frames.first.timeout(const Duration(seconds: 15));

      session.sendText('seq 1 400\r');
      await scrollOf(
        client,
        paneId,
        until: (s) => (s.max ?? 0) > 100,
        timeout: const Duration(seconds: 10),
      );

      // A SUBSCRIPTION OF OUR OWN, carrying payloads the board's signal does
      // not: `pane.scroll_changed` carries the whole scroll object.
      final events = <String>[];
      // THE PANE ID IS REQUIRED BY THIS SUBSCRIPTION KIND — the daemon rejects
      // the same request without it ("missing field `pane_id`", measured), which
      // is useful rather than annoying: it is what lets one screen watch one
      // pane's scrolling without receiving every pane's.
      final sub = await client.subscribe([
        {'type': 'pane.scroll_changed', 'pane_id': paneId},
      ]);
      final listen = sub.events.listen(events.add);
      addTearDown(listen.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      session.scroll(7);
      await Future<void>.delayed(const Duration(milliseconds: 900));

      print('  events: ${events.length}');
      for (final e in events) {
        print('    $e');
      }
      final observed = events
          .map(PaneScrollEvent.tryParse)
          .whereType<PaneScrollEvent>()
          .where((e) => e.paneId == paneId)
          .toList();
      expect(
        observed,
        isNotEmpty,
        reason: 'pane.scroll_changed must announce a scroll the SESSION asked '
            'for — the app scrolls through the session, not through pane.scroll',
      );
      expect(observed.last.offset, 7);
      expect(observed.last.max, greaterThan(0));
      // And the payload carries the maximum, which is the number the app could
      // not otherwise have: how much history there is to scroll back through.
    }, skip: skipReason);

    test('pane.scroll sets the offset absolutely', () async {
      final session = await TerminalControl.open(
        transport(),
        paneId: paneId,
        cols: 80,
        rows: 24,
      );
      addTearDown(session.close);
      await session.frames.first.timeout(const Duration(seconds: 15));

      session.sendText('seq 1 400\r');
      // Settled first, for the reason [settle] documents: the daemon anchors a
      // scrolled view while output arrives, so an unsettled pane reports the
      // anchoring added to whatever was asked for.
      await settle(client, paneId);

      await client.transport.roundTrip(
        '{"id":"scroll","method":"pane.scroll",'
        '"params":{"pane_id":"$paneId","offset_from_bottom":50}}',
      );
      final scrolled = await scrollOf(
        client,
        paneId,
        until: (s) => s.offset == 50,
        timeout: const Duration(seconds: 3),
      );
      print('  after pane.scroll(50): $scrolled');
      expect(scrolled.offset, 50);

      await client.transport.roundTrip(
        '{"id":"scroll","method":"pane.scroll",'
        '"params":{"pane_id":"$paneId","offset_from_bottom":0}}',
      );
      final back = await scrollOf(
        client,
        paneId,
        until: (s) => s.offset == 0,
        timeout: const Duration(seconds: 3),
      );
      expect(back.offset, 0);
    }, skip: skipReason);
  });
}
