import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/pages/files/file_tree_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_harness.dart';

/// The `...` menu: it answers the tap, not the machine.
///
/// THE REPORT was that tapping it on a bad link felt broken — nothing appeared
/// for as long as the pane census took. The menu needs exactly ONE thing from
/// that census (the pane's directory) and it does not need it until a row is
/// picked, so this file pins the shape of the fix: with the census deliberately
/// held open, the rows are on screen anyway.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  /// One frame, without settling: the point is that nothing is being waited on.
  Future<void> tapMore(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
  }

  testWidgets('the rows are there before the census answers', (tester) async {
    final daemon = FakeTerminalDaemon(paneRows: 46);
    await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);

    // Let the page settle, then HOLD the census. A read that is never allowed
    // to finish is the worst case of the slow link, and it is also the only way
    // to tell "the menu did not wait" from "the menu waited and it was fast".
    await tester.pump(const Duration(seconds: 1));
    daemon.treeGate = Completer<void>();

    await tapMore(tester);

    for (final row in ['Files', 'Git changes', 'Move focus here']) {
      expect(
        find.text(row),
        findsOneWidget,
        reason: 'the menu is a question about the pane, not a request to it',
      );
    }
  });

  testWidgets('picking a row resolves the directory, then opens the screen',
      (tester) async {
    // The wait MOVED, rather than disappearing: it now happens behind the tap,
    // where the destination screen shows its own loading state — which is
    // exactly where the user asked for it.
    final daemon = FakeTerminalDaemon(paneRows: 46);
    await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);

    await tester.pump(const Duration(seconds: 1));
    daemon.treeGate = Completer<void>();
    await tapMore(tester);

    await tester.tap(find.text('Files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The census is still held, so the screen has not opened — and the menu is
    // gone, which is the tap being answered.
    expect(find.text('Files'), findsNothing);
    expect(find.byType(FileTreePage), findsNothing);

    daemon.treeGate!.complete();
    await tester.pumpAndSettle();

    // And now the browser is up, on the directory the census reported.
    expect(find.byType(FileTreePage), findsOneWidget);
  });
}
