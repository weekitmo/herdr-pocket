import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/settings/key_bar_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The screen where the keys are chosen.
///
/// THE BUG THIS FILE EXISTS FOR IS A READING PROBLEM, not a drawing one. The bar
/// labels the ready-made control codes `C-c`, `C-d`, `C-z` — the notation every
/// man page has used since Emacs, and unreadable to anybody who has not met it.
/// The bar is a horizontal scroller on a phone, so it keeps the short spelling;
/// the long spelling is supposed to appear here, on the row that picks the key.
/// If it stops appearing, nothing looks broken: the page still renders, the
/// ticks still tick, and the only symptom is a user who cannot tell what a key
/// does. So the assertion is on the line under the label, not on the layout.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // A PHONE'S WIDTH, not the 800-point default. The row now carries a longer
    // line of text than it used to, and the only failure that would matter is a
    // layout one — and that one only exists at a width a phone actually has.
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: KeyBarPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a shorthand label keeps the shorthand, and gains the keys it '
      'stands for', (tester) async {
    await pumpPage(tester);

    // Both halves, deliberately. The label is what the button on the bar says
    // and the two have to keep matching; the note is the only place the long
    // spelling is allowed to live.
    expect(find.text('C-c'), findsOneWidget);
    expect(find.text('Ctrl+C · Interrupt (SIGINT)'), findsOneWidget);
    expect(find.text('Ctrl+D · End of input (EOF)'), findsOneWidget);
    expect(find.text('Ctrl+Z · Suspend (SIGTSTP)'), findsOneWidget);
  });

  testWidgets('a label that is already a word is not glossed', (tester) async {
    await pumpPage(tester);

    // `esc` needs an explanation (`Escape`), not a translation into a notation
    // it was never written in. A `Ctrl+esc` on this row would be a worse lie
    // than saying nothing.
    expect(find.text('Escape'), findsOneWidget);
    expect(find.textContaining('Ctrl+esc'), findsNothing);
    expect(find.textContaining('Ctrl+tab'), findsNothing);
  });
}
