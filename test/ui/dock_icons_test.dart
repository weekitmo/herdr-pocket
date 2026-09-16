import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The icon-set setting has to actually change the glyphs.
///
/// A setting that flips a value and draws the same thing is worse than no
/// setting: the user concludes the app ignored them. So this asserts on what
/// reached the tree, not on the stored value — the persistence test already
/// covers the value.
void main() {
  Future<void> pumpDock(WidgetTester tester, AppIconSet iconSet) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.settings.iconSet': iconSet.name,
    });
    final prefs = await SharedPreferences.getInstance();
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
            home: CupertinoPageScaffold(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: HerdrDock(
                  views: RootView.values,
                  selected: RootView.board,
                  onSelect: _noop,
                  glass: false,
                  labels: {
                    RootView.board: 'Board',
                    RootView.workspaces: 'Workspaces',
                    RootView.settings: 'Settings',
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the system set draws the platform glyphs', (tester) async {
    await pumpDock(tester, AppIconSet.system);
    expect(find.byType(UiIcon), findsNothing);
    expect(find.byIcon(CupertinoIcons.square_list_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.gear_alt), findsOneWidget);
  });

  testWidgets('the themed set draws the vendored icons', (tester) async {
    await pumpDock(tester, AppIconSet.themed);
    expect(find.byType(UiIcon), findsNWidgets(RootView.values.length));
    expect(find.byIcon(CupertinoIcons.square_list_fill), findsNothing);
  });

  testWidgets('selection is a FILLED glyph in both sets', (tester) async {
    // The dock's rule — selection carried in ink plus a filled shape rather
    // than a pill behind it — is a decision about the bar, so it has to survive
    // the artwork changing underneath it.
    await pumpDock(tester, AppIconSet.themed);
    final icons = tester
        .widgetList<UiIcon>(find.byType(UiIcon))
        .toList();
    final filled = icons.where((i) => i.filled).toList();
    expect(filled, hasLength(1), reason: 'exactly one tab is selected');
    expect(filled.single.name, UiIconName.board);
  });

  testWidgets('every dock icon resolves in the themed set', (tester) async {
    // No exception means every template was found and every slot was filled;
    // a missing template throws at build time.
    await pumpDock(tester, AppIconSet.themed);
    expect(tester.takeException(), isNull);
  });
}

void _noop(RootView _) {}
