import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Brightness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/domain/theme/theme_definition.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';

/// The colour schemes this build ships.
///
/// Read from the bundled JSON rather than declared as Dart constants, so adding
/// a theme is editing a data file and not a code change — and so the file can
/// be replaced wholesale with a gallery export.
final themeCatalogueProvider = FutureProvider<List<ThemeDefinition>>((ref) async {
  final raw = await rootBundle.loadString('assets/themes/builtin.json');
  return parseThemeCatalogue(raw);
});

/// The theme the user picked, or null for the built-in palette.
///
/// NULL MEANS BUILT-IN, and the built-in is the app's own design — the one this
/// project started with. A theme is an opt-in overlay on top of it, not the
/// only way to have colours, which is what makes "reset to default" mean
/// something.
final selectedThemeProvider = Provider<ThemeDefinition?>((ref) {
  final id = ref.watch(settingsProvider.select((s) => s.themeId));
  if (id == null || id.isEmpty) return null;
  final catalogue = ref.watch(themeCatalogueProvider).value ?? const [];
  for (final theme in catalogue) {
    if (theme.id == id) return theme;
  }
  // An id that is no longer in the catalogue (the file was replaced, or the
  // theme was removed) falls back to the built-in rather than to a blank app.
  return null;
});

/// The app's colours, theme or no theme.
///
/// One function so the answer to "which colours is this screen using" cannot
/// differ between the app shell and anything else that asks.
HerdrColors resolveColors({
  required ThemeDefinition? theme,
  required Brightness platformBrightness,
}) {
  if (theme == null) {
    return platformBrightness == Brightness.dark
        ? HerdrColors.dark
        : HerdrColors.light;
  }
  return HerdrColors.fromChrome(theme.chrome, brightness: themeBrightness(theme));
}

/// The brightness a scheme implies.
///
/// A scheme IS its mode: its twenty colours only work one way round, and
/// pairing a dark scheme with light chrome is a combination nobody designed.
/// This is why selecting a theme overrides the light/dark setting rather than
/// being merely tinted by it.
Brightness themeBrightness(ThemeDefinition theme) =>
    theme.isDark ? Brightness.dark : Brightness.light;

/// The terminal's colours, from the selected scheme.
///
/// The terminal is the surface a colour scheme is FOR — its 20 colours were
/// chosen to work together in a terminal — so when a theme is selected the
/// terminal uses the scheme verbatim rather than anything derived. The built-in
/// default stays `TerminalColors.dark`, which is this app's own tuning of the
/// xterm 16 against herdr's near-black ground.
TerminalColors resolveTerminalColors(ThemeDefinition? theme) {
  if (theme == null) return TerminalColors.dark;
  return TerminalColors.fromScheme(theme.palette);
}
