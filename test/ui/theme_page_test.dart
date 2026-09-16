import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/domain/theme/theme_definition.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/theme_swatch.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/settings/theme_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The scheme picker.
///
/// WHAT CAN GO WRONG HERE IS NOT "does it draw". It is that the picker and the
/// app disagree about which scheme is selected, or that a scheme exists in the
/// data file and is unreachable in the UI. Both are silent — the page looks
/// fine either way, and the only symptom is a user who never sees the theme
/// they picked. So these tests drive the REAL bundled catalogue and assert on
/// what actually reached the settings, not on what was drawn.
///
/// The catalogue is read through [WidgetTester.runAsync] rather than left to
/// the provider. That is not a shortcut around the code under test: the
/// provider loads the asset over the platform channel, which needs the real
/// event loop, and a test body awaiting real I/O inside `flutter_test`'s
/// fake-async zone hangs the WHOLE run — not just the one test — with no
/// failure report. Reading it in `runAsync` keeps the assertion that matters
/// (a data file that fails to parse ships as an empty picker) without the
/// deadlock.
void main() {
  late ProviderContainer container;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  /// The shipped schemes, freshly parsed from the shipped file.
  ///
  /// Re-read per test rather than cached in a `setUpAll`: a cached list would
  /// hide the case where the asset only loads once, which is the shape of the
  /// bug this file was written after hitting.
  Future<List<ThemeDefinition>> loadCatalogue(WidgetTester tester) async {
    final raw = await tester.runAsync(
      () => rootBundle.loadString('assets/themes/builtin.json'),
    );
    return parseThemeCatalogue(raw!);
  }

  /// Pumps the picker over the real catalogue, and wires [container] so a test
  /// can observe the settings as well as the pixels.
  Future<List<ThemeDefinition>> pumpPicker(
    WidgetTester tester, {
    HerdrColors? colors,
  }) async {
    final themes = await loadCatalogue(tester);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        themeCatalogueProvider.overrideWith((ref) => themes),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: HerdrTheme(
          colors: colors ?? HerdrColors.dark,
          child: const CupertinoApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: ThemePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return themes;
  }

  testWidgets('the bundled catalogue loads, and every scheme is listed',
      (tester) async {
    final themes = await pumpPicker(tester);

    // A data file that fails to parse ships as an empty picker, which reads to
    // the user as "this build has no themes" rather than as a broken asset.
    expect(themes, isNotEmpty);
    expect(
      themes.map((t) => t.id).toSet().length,
      themes.length,
      reason: 'duplicate ids would make one scheme unreachable',
    );
    // Both modes have to be represented, or the page renders a section heading
    // over nothing.
    expect(themes.where((t) => t.isDark), isNotEmpty);
    expect(themes.where((t) => !t.isDark), isNotEmpty);

    for (final theme in themes) {
      expect(
        find.text(theme.name),
        findsOneWidget,
        reason: '${theme.id} is in the catalogue but not in the picker',
      );
    }
    // Every scheme plus the built-in row.
    expect(find.byType(ThemeSwatch), findsNWidgets(themes.length + 1));
  });

  testWidgets('tapping a scheme selects it, and tapping the built-in clears it',
      (tester) async {
    final themes = await pumpPicker(tester);
    final target = themes.firstWhere((t) => t.id == 'nord');

    // A fresh install opens on Nord — the app's own palette is a choice in
    // the picker, not the thing you start from. See `defaultThemeId`.
    expect(container.read(settingsProvider).themeId, defaultThemeId);

    await tester.tap(find.text(target.name));
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).themeId, 'nord');
    // The provider the app root reads has to agree with the setting, or the
    // picker ticks one scheme while the app runs another.
    expect(container.read(selectedThemeProvider)?.id, 'nord');
    expect(
      resolveTerminalColors(container.read(selectedThemeProvider)).background,
      HerdrColors.colorFromHex(target.palette.background),
      reason: 'the terminal must use the scheme it was selected from',
    );

    // Back to the app's own design. Null is a real choice here, not "unset":
    // it is the only way back to the palette the app shipped with.
    await tester.tap(find.text('Herdr Pocket default'));
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).themeId, isNull);
    expect(container.read(selectedThemeProvider), isNull);
    expect(
      container.read(settingsProvider).themeId,
      isNot(defaultThemeId),
      reason: 'choosing the built-in must not read back as "never chose", or '
          'the next launch would overrule the user',
    );
    expect(
      resolveTerminalColors(container.read(selectedThemeProvider)).background,
      TerminalColors.dark.background,
    );
  });

  testWidgets('a light scheme previews legibly on a light card',
      (tester) async {
    // The swatches are drawn from each scheme's own colours, so a light scheme
    // is a light chip — on the light theme, where the card is nearly white and
    // a chip with no edge is invisible. A test cannot assert the pixel here, so
    // this asserts the two facts that make it true: the chip carries the
    // scheme's ground rather than the card's, and it carries an edge.
    final themes = await pumpPicker(tester, colors: HerdrColors.light);

    final swatches = tester
        .widgetList<ThemeSwatch>(find.byType(ThemeSwatch))
        .toList();
    expect(swatches, hasLength(themes.length + 1));

    final light = swatches.where((s) => s.ground.computeLuminance() > 0.5);
    expect(light, isNotEmpty, reason: 'no light scheme rendered a light chip');
    expect(
      light.every((s) => s.edge != null),
      isTrue,
      reason: 'a light chip with no edge disappears into a light card',
    );
  });
}
