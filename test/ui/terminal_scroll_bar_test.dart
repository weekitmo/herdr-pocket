import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_harness.dart';

/// The "N lines back" bar, and the thing it used to get wrong.
///
/// WHAT WENT WRONG, because the test only makes sense with it in view: the bar
/// was drawn from a number this client advanced by whatever it had ASKED the
/// daemon for. Swiping back on a pane with no history, or past the top of one
/// with history, asked for a move the daemon refuses — and the mirror kept
/// counting, so the screen announced "已回看 3 行" over a screen that never moved.
/// No frame can show the difference (a rendered frame of history and one of the
/// present are identical), so the only thing that knows is the daemon's own
/// `offset_from_bottom` / `max_offset_from_bottom`.
///
/// The daemon was measured first — see `test/integration/scroll_probe_test.dart`
/// — and these are the same facts against a scripted one.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  /// The terminal grid, which is what the finger scrolls.
  final surface = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is TerminalPainter,
  );

  /// Drags DOWN, which pulls older lines into view.
  Future<void> dragBack(WidgetTester tester, {double dy = 80}) async {
    await tester.drag(surface, Offset(0, dy));
    await tester.pump();
  }

  /// Every scroll command the page sent on the terminal channel.
  List<Map<String, Object?>> scrolls(FakeTerminalDaemon daemon) => daemon
      .sentOnTerminal()
      .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
      .where((m) => m['type'] == 'terminal.scroll')
      .toList();

  testWidgets('a pane with no history shows no bar, however hard you swipe',
      (tester) async {
    // The exact complaint: the bar appeared on a pane that could not scroll.
    final daemon = await pumpTerminalPage(
      tester,
      prefs: prefs,
      daemon: FakeTerminalDaemon(paneRows: 46, scrollMax: 0),
    );
    daemon.emitFrame(data: 'live\r\n');
    await tester.pump();

    await dragBack(tester);
    await dragBack(tester, dy: 200);

    expect(
      find.textContaining('lines back'),
      findsNothing,
      reason: 'the pane has nothing to scroll back to',
    );
    // And the daemon was not poked for a move it would refuse. One request per
    // drag frame is what this guard is for as much as the honesty is.
    expect(scrolls(daemon), isEmpty);
  });

  testWidgets('a pane with history shows the offset the daemon reports',
      (tester) async {
    final daemon = await pumpTerminalPage(
      tester,
      prefs: prefs,
      daemon: FakeTerminalDaemon(paneRows: 46, scrollMax: 385),
    );
    daemon.emitFrame(data: 'live\r\n');
    await tester.pump();

    await dragBack(tester);
    expect(find.textContaining('lines back'), findsOneWidget);
    expect(scrolls(daemon), isNotEmpty);

    // AND IT REALLY IS WATCHING. Without this line the test above would pass on
    // a page whose subscription silently failed and whose mirror happened to be
    // right — which is the whole failure mode, wearing the fix's clothes.
    final kinds = daemon.subscriptions
        .expand((params) => params['subscriptions']! as List)
        .cast<Map<Object?, Object?>>();
    expect(
      kinds.any(
        (s) => s['type'] == 'pane.scroll_changed' && s['pane_id'] == kTestPaneId,
      ),
      isTrue,
      reason: "the page must ask for this pane's scroll events, with the pane "
          'id the daemon requires: $kinds',
    );

    // THE DAEMON'S ANSWER WINS. Whatever the mirror guessed while the finger was
    // moving, the number on screen is the one the pane is actually at — which is
    // also how a scroll this client never asked for (another client, or output
    // arriving while the reader is parked) reaches the screen.
    daemon.emitScroll(offset: 120, max: 385);
    // TWO HOPS, NOT ONE: the event crosses the subscription stream, a stream
    // controller and a `setState` before a frame can draw it, and a single pump
    // can land between them.
    await tester.pumpAndSettle();
    expect(find.textContaining('120 lines back'), findsOneWidget);
  });

  testWidgets('the count stops at the end of the buffer instead of climbing',
      (tester) async {
    final daemon = await pumpTerminalPage(
      tester,
      prefs: prefs,
      daemon: FakeTerminalDaemon(paneRows: 46, scrollMax: 20),
    );
    daemon.emitFrame(data: 'live\r\n');
    await tester.pump();

    // Far more gesture than there is history: 20 lines is a quarter of a screen.
    for (var i = 0; i < 6; i++) {
      await dragBack(tester, dy: 300);
    }

    expect(find.textContaining('lines back'), findsOneWidget);
    // Read the number off the bar rather than out of the widget's state: the bar
    // is what the reader believes.
    final text = tester
        .widgetList<Text>(find.textContaining('lines back'))
        .first
        .data!;
    final shown = int.parse(RegExp(r'(\d+)').firstMatch(text)!.group(1)!);
    expect(shown, lessThanOrEqualTo(20));
  });

  testWidgets('at the oldest line the bar says so, because the number cannot',
      (tester) async {
    final daemon = await pumpTerminalPage(
      tester,
      prefs: prefs,
      daemon: FakeTerminalDaemon(paneRows: 46, scrollMax: 385),
    );
    daemon.emitFrame(data: 'live\r\n');
    await tester.pump();

    await dragBack(tester);
    expect(find.textContaining('at the oldest'), findsNothing);

    daemon.emitScroll(offset: 385, max: 385);
    await tester.pumpAndSettle();
    // 385 and 385 do not look different; the words are the only way to know the
    // reader has hit the top and can stop swiping.
    expect(find.textContaining('at the oldest'), findsOneWidget);
    expect(find.textContaining('385 lines back'), findsOneWidget);
  });

  testWidgets('tapping the bar goes back to live and the bar goes away',
      (tester) async {
    final daemon = await pumpTerminalPage(
      tester,
      prefs: prefs,
      daemon: FakeTerminalDaemon(paneRows: 46, scrollMax: 385, scrollOffset: 40),
    );
    daemon.emitFrame(data: 'live\r\n');
    await tester.pump();

    // The pane was already scrolled when this screen opened — a mirror seeded
    // from `pane.list`, which is the only place the daemon says so.
    expect(find.textContaining('40 lines back'), findsOneWidget);

    await tester.tap(find.textContaining('lines back'));
    await tester.pump();

    final down = scrolls(daemon).where((m) => m['direction'] == 'down');
    expect(down, isNotEmpty);
    expect(find.textContaining('lines back'), findsNothing);
  });

  testWidgets('the clamp still works when the daemon refuses the subscription',
      (tester) async {
    // The degrade path: an older protocol, or a daemon that says no. The maximum
    // still arrives once, from `pane.list`, so the bar still cannot count past
    // the end of the buffer — and the terminal still opens.
    final daemon = await pumpTerminalPage(
      tester,
      prefs: prefs,
      daemon: FakeTerminalDaemon(
        paneRows: 46,
        scrollMax: 20,
        scrollEvents: false,
      ),
    );
    daemon.emitFrame(data: 'live\r\n');
    await tester.pump();

    for (var i = 0; i < 6; i++) {
      await dragBack(tester, dy: 300);
    }

    final text = tester
        .widgetList<Text>(find.textContaining('lines back'))
        .first
        .data!;
    final shown = int.parse(RegExp(r'(\d+)').firstMatch(text)!.group(1)!);
    expect(shown, lessThanOrEqualTo(20));
  });
}
