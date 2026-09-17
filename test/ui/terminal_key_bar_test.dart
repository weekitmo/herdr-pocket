import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/key_strip.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the terminal's key bar offers, and how the expanded panel behaves.
///
/// The bar is the ONLY way to type on a phone and it is deliberately wider than
/// the screen, so the two properties worth pinning down are both about reach:
/// the two pinned controls stay reachable at every scroll position, and the
/// panel carries the whole catalogue rather than the subset the bar shows.
///
/// Pumps the page against an offline connection on purpose. Nothing here sends
/// a byte — what is under test is the bar's own shape, and a live session would
/// make the test depend on a daemon to ask a question about a widget.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpTerminal(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectionProvider.overrideWith(_OfflineConnection.new),
        ],
        child: const HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: TerminalPage(paneId: 'pane-1', title: 'agent'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A cap inside the expanded panel, never the one on the bar behind it.
  Finder inFan(String label) => find.descendant(
    of: find.byKey(keyFanKey),
    matching: find.text(label),
  );

  Future<void> openFan(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('All keys'));
    await tester.pumpAndSettle();
    expect(find.byKey(keyFanKey), findsOneWidget);
  }

  testWidgets('the keyboard and expand buttons are pinned outside the scroller',
      (tester) async {
    await pumpTerminal(tester);

    expect(find.bySemanticsLabel('Show keyboard'), findsOneWidget);
    expect(find.bySemanticsLabel('All keys'), findsOneWidget);

    final keyboard = tester.getCenter(find.bySemanticsLabel('Show keyboard'));
    await tester.drag(find.text('esc'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.bySemanticsLabel('Show keyboard')),
      keyboard,
      reason: 'the pinned controls must not move when the keys scroll',
    );
    expect(find.bySemanticsLabel('All keys'), findsOneWidget);
  });

  testWidgets('the expand button opens the whole catalogue', (tester) async {
    await pumpTerminal(tester);

    // A key the default bar does not show, so its presence proves the panel is
    // the catalogue rather than a copy of the bar.
    expect(find.text('pgdn'), findsNothing);
    await openFan(tester);

    for (final key in keyBarCatalogue) {
      if (key.isAction) continue; // drawn as an icon, not as a word
      expect(
        inFan(key.label),
        findsOneWidget,
        reason: '${key.id} is missing from the expanded panel',
      );
    }

    // AND THEY SHARE ROWS. Asserting only that the labels exist passed while
    // every cap was a full-width pill one per row — the panel looked like a
    // column of bars. The caps have to be laid out side by side, which is what
    // "shrink-wrap the chip" was for.
    expect(
      tester.getTopLeft(inFan('Ctrl')).dy,
      tester.getTopLeft(inFan('Alt')).dy,
      reason: 'the first two caps belong on the same row',
    );
    expect(
      tester.getSize(find.byKey(keyFanKey)).height,
      lessThan(tester.getSize(find.byKey(keyFanKey)).width * 2),
      reason: 'twenty-four keys in a grid are wider than they are tall',
    );
  });

  testWidgets('the expand button closes the panel it opened', (tester) async {
    await pumpTerminal(tester);
    await openFan(tester);

    await tester.tap(find.bySemanticsLabel('All keys'));
    await tester.pumpAndSettle();
    expect(find.byKey(keyFanKey), findsNothing);
  });

  testWidgets('tapping outside the panel puts it away', (tester) async {
    await pumpTerminal(tester);
    await openFan(tester);

    // The top of the terminal, well away from the panel.
    await tester.tapAt(const Offset(40, 60));
    await tester.pumpAndSettle();
    expect(find.byKey(keyFanKey), findsNothing);
  });
}

class _OfflineConnection extends ConnectionNotifier {
  @override
  Future<ConnectionStatus> build() async => const Disconnected();
}
