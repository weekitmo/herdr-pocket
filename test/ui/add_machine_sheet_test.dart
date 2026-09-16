import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/herdr_sheet.dart';

import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/hosts/hosts_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for how a machine gets added: the floating button, the sheet it opens,
/// and the spacing inside that sheet.
///
/// The screen had no coverage at all before this, which is exactly how a
/// redesign lands with the old affordance still in it. Everything asserted here
/// is something the change was asked for specifically — the button moved, the
/// page became a sheet, and two controls stopped being cramped — so a
/// regression is a change nobody intended rather than a matter of taste.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> pumpHosts(WidgetTester tester) async {
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
            locale: Locale('en'),
            home: HostsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the machines page', () {
    testWidgets('adds a machine from a floating button, not the top bar',
        (tester) async {
      await pumpHosts(tester);

      expect(
        find.byType(HerdrFloatingButton),
        findsOneWidget,
        reason: 'the action moved out of the top-right corner, which is the '
            'hardest part of a phone to reach one-handed',
      );
      expect(find.bySemanticsIdentifier('add-machine'), findsOneWidget);
    });

    testWidgets('the button sits at the bottom right', (tester) async {
      await pumpHosts(tester);

      final screen = tester.getSize(find.byType(HostsPage));
      final button = tester.getRect(find.byType(HerdrFloatingButton));

      expect(
        button.right,
        greaterThan(screen.width * 0.75),
        reason: 'bottom-RIGHT: a floating button on the left is a different '
            'gesture than the one asked for',
      );
      expect(button.bottom, greaterThan(screen.height * 0.6));
      // And clear of the gesture area rather than sitting inside it.
      expect(screen.height - button.bottom, greaterThanOrEqualTo(Space.lg));
    });
  });

  group('the add-machine sheet', () {
    Future<void> open(WidgetTester tester) async {
      await pumpHosts(tester);
      await tester.tap(find.byType(HerdrFloatingButton));
      await tester.pumpAndSettle();
    }

    testWidgets('rises from the bottom as a sheet', (tester) async {
      await open(tester);

      // `HerdrSheet` is the ROUTE — an Align that fills the screen — so it is
      // the SURFACE that has to be measured. Asserting against the route would
      // pass on a widget that spans the full height no matter where the panel
      // actually is.
      expect(find.byType(HerdrSheetSurface), findsOneWidget);
      expect(find.text('Add machine'), findsOneWidget);

      final panel = tester.getRect(find.byType(HerdrSheetSurface));
      final screen = tester.getSize(find.byType(HostsPage));
      expect(panel.bottom, closeTo(screen.height, 1.0));
      expect(
        panel.top,
        greaterThan(0),
        reason: 'the panel is shorter than the screen — a sheet that fills it '
            'is a page with extra steps',
      );
    });

    testWidgets('opens in pairing mode, because that is the short path',
        (tester) async {
      await open(tester);

      // The switch is there, and it starts on the option that asks for the
      // least: running `hdp pair` answers the address, the port, the user and
      // the key at once.
      expect(find.text('Pair by QR code (recommended)'), findsOneWidget);
      expect(find.text('Add manually'), findsOneWidget);
      expect(
        find.textContaining('Run hdp pair'),
        findsOneWidget,
        reason: 'the pairing body should be the one showing',
      );
    });

    testWidgets('carries 完成 in the top right, not a save button at the bottom',
        (tester) async {
      await open(tester);

      // The header button is there before anything is filled in — it is the
      // sheet's own chrome, not a form control — and it is a WORD on a rounded
      // surface rather than the bare checkmark that used to sit here.
      expect(find.byType(HerdrSheetAction), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);

      await tester.tap(find.text('Add manually'));
      await tester.pumpAndSettle();

      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Authentication'), findsOneWidget);
      expect(
        find.text('Save'),
        findsNothing,
        reason: 'the same action was in two places at once when this sheet had '
            'both a header button and a bottom one, and they read as two '
            'different things that happen to share a word',
      );
      // And the pairing body is gone rather than stacked underneath.
      expect(find.textContaining('Run hdp pair'), findsNothing);
    });

    testWidgets('完成 sits in the top right corner of the panel', (tester) async {
      await open(tester);

      final panel = tester.getRect(find.byType(HerdrSheetSurface));
      final action = tester.getRect(find.byType(HerdrSheetAction));

      // Top RIGHT, measured against the PANEL: the whole point of the change
      // was the position, and a button that drifted to the left or down into
      // the body would still pass a `findsOneWidget`.
      expect(
        action.center.dy,
        lessThan(panel.top + 48),
        reason: 'the button should be in the header band, not below it',
      );
      expect(action.right, closeTo(panel.right - Space.md, 2));
      expect(
        action.left,
        greaterThan(panel.center.dx),
        reason: 'right half of the header',
      );
    });

    testWidgets('there is air between a label and the control under it',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Add manually'));
      await tester.pumpAndSettle();

      // THE COMPLAINT THIS ENCODES: the segmented control and the private-key
      // area both sat flush against their labels. Both go through
      // `SettingsRow.below`, so the assertion is written against the label
      // bottom and the control top rather than against a padding constant —
      // a test that pins `Space.sm` would pass after someone moved the padding
      // somewhere that does not touch this row.
      final label = tester.getRect(find.text('Authentication'));
      final segmented = tester.getRect(find.byType(CupertinoSlidingSegmentedControl<bool>));
      expect(
        segmented.top - label.bottom,
        greaterThanOrEqualTo(Space.sm),
        reason: 'the authentication control is still tight against its label',
      );
    });
  });
}
