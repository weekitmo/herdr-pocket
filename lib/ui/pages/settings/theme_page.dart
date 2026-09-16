import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/theme_swatch.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Picks the colour scheme the whole app runs on.
///
/// WHY A SWATCH AND NOT JUST A NAME. A scheme's name tells you nothing unless
/// you already know it — "Gruvbox" is not a colour. The swatch is drawn from
/// the scheme's OWN terminal palette rather than from a hand-painted preview,
/// so it cannot drift from what the app will look like: change the data file
/// and the thumbnail changes with it.
///
/// The schemes are grouped by their own light/dark rather than listed in file
/// order, because a scheme decides its mode (see [themeBrightness]) and the
/// only useful question a picker can ask is "dark or light" — which is exactly
/// the question the two groups answer.
class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final selected = ref.watch(settingsProvider.select((s) => s.themeId));
    final catalogue = ref.watch(themeCatalogueProvider);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: ScrollConfiguration(
        behavior: settingsScrollBehavior(context),
        child: CustomScrollView(
          slivers: [
            HerdrSliverTopBar(
              title: l10n.themesTitle,
              leading: HerdrBackButton(label: l10n.navBack),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                rows: [
                  _ThemeChoice(
                    name: l10n.themesBuiltIn,
                    note: l10n.themesBuiltInNote,
                    colors: colors,
                    // The built-in's own preview: its two grounds and the four
                    // status hues. That IS what "Herdr Pocket" looks like, and
                    // a preview built from anything else would be a picture of
                    // a theme that does not exist.
                    swatch: ThemeSwatch.builtIn(edge: colors.hairline),
                    selected: selected == null,
                    onTap: () =>
                        ref.read(settingsProvider.notifier).setThemeId(null),
                  ),
                ],
              ),
            ),

            // The catalogue is a bundled asset, so it is loaded rather than
            // awaited. An empty list here is "not yet", not "no themes", and
            // showing an error for a state the user is not in would be
            // inventing a problem.
            ...catalogue.when(
              data: (themes) => [
                for (final (isDark, title) in [
                  (true, l10n.themesSectionDark),
                  (false, l10n.themesSectionLight),
                ])
                  if (themes.any((t) => t.isDark == isDark))
                    SliverToBoxAdapter(
                      child: SettingsGroup(
                        title: title,
                        rows: [
                          for (final theme in themes)
                            if (theme.isDark == isDark)
                              _ThemeChoice(
                                name: theme.name,
                                colors: colors,
                                swatch: ThemeSwatch.fromPalette(
                                  theme.palette,
                                  edge: colors.hairline,
                                ),
                                selected: selected == theme.id,
                                onTap: () => ref
                                    .read(settingsProvider.notifier)
                                    .setThemeId(theme.id),
                              ),
                        ],
                      ),
                    ),
              ],
              loading: () => const [],
              error: (_, _) => [
                SliverToBoxAdapter(
                  child: SettingsNote(
                    text: l10n.themesUnavailable,
                    isError: true,
                  ),
                ),
              ],
            ),

            SliverToBoxAdapter(child: SettingsNote(text: l10n.themesFooter)),

            const SliverToBoxAdapter(child: SizedBox(height: Space.xl)),
          ],
        ),
      ),
    );
  }
}

/// One scheme in the list: its preview, its name, and whether it is on.
class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.name,
    required this.swatch,
    required this.colors,
    required this.selected,
    required this.onTap,
    this.note,
  });

  final String name;
  final String? note;
  final Widget swatch;
  final HerdrColors colors;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SettingsRow(
        label: name,
        note: note,
        labelColor: selected ? colors.text : colors.textDim,
        // The preview is on the RIGHT, next to the tick, and that is not a
        // style choice: the row's hairline is inset to where the label starts,
        // so a chip on the left would sit in the gutter the rule is drawn
        // through.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            swatch,
            const SizedBox(width: Space.md),
            Icon(
              selected
                  ? CupertinoIcons.check_mark_circled_solid
                  : CupertinoIcons.circle,
              size: 20,
              color: selected ? colors.accent : colors.hairline,
            ),
          ],
        ),
      ),
    );
  }
}
