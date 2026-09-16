import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The icon set, drawn three ways on the surfaces it would replace.
///
/// A COMPARISON PAGE, NOT A FEATURE, and it says so at the top. The question it
/// exists to answer cannot be answered in prose: whether a coloured icon looks
/// like this app or like a different app is a judgement about pixels, and the
/// two candidate palettes differ in a way only the eye resolves.
///
/// The three variants are:
///
///   * **Mono** — what ships today. One tint, `CupertinoIcons`, everything else
///     in the app unchanged.
///   * **Themed** — the IconPark set with all four colour slots taken from the
///     active colour scheme. Twelve schemes, twelve answers, and none of them
///     introduces a hue the app does not already have.
///   * **Fixed** — the set's own palette as published. Brightest, and the only
///     one of the three that argues with the scheme it is sitting in.
///
/// Each row is drawn at the size and on the ground the real surface uses, so
/// the optical weight is comparable: an icon judged at 40 points on a white
/// preview background tells you nothing about a 22-point one on a card.
class IconsPage extends ConsumerWidget {
  const IconsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final terminal = resolveTerminalColors(ref.watch(selectedThemeProvider));

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: ScrollConfiguration(
        behavior: settingsScrollBehavior(context),
        child: CustomScrollView(
          slivers: [
            HerdrSliverTopBar(
              title: l10n.iconsTitle,
              leading: HerdrBackButton(label: l10n.navBack),
            ),
            SliverToBoxAdapter(child: SettingsNote(text: l10n.iconsNote)),

            _Section(
              title: l10n.iconsDock,
              colors: colors,
              rows: [
                for (final variant in UiIconVariant.values)
                  _Row(
                    variant: variant,
                    colors: colors,
                    label: labelFor(variant, l10n),
                    // 22 is what the dock draws, on the dock's own surface.
                    child: _DockPreview(variant: variant, colors: colors),
                  ),
              ],
            ),

            _Section(
              title: l10n.iconsToolbar,
              colors: colors,
              rows: [
                for (final variant in UiIconVariant.values)
                  _Row(
                    variant: variant,
                    colors: colors,
                    label: labelFor(variant, l10n),
                    // On the terminal's own ground, because that is where the
                    // toolbar actually lives and the terminal is not the app's
                    // card colour.
                    ground: terminal.background,
                    child: _ToolbarPreview(
                      variant: variant,
                      colors: colors,
                      cursor: terminal.cursor,
                      background: terminal.background,
                    ),
                  ),
              ],
            ),

            _Section(
              title: l10n.iconsMachine,
              colors: colors,
              rows: [
                for (final variant in UiIconVariant.values)
                  _Row(
                    variant: variant,
                    colors: colors,
                    label: labelFor(variant, l10n),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      child: UiIcon(
                        UiIconName.machine,
                        size: 24,
                        variant: variant,
                        color: colors.textFaint,
                      ),
                    ),
                  ),
              ],
            ),

            SliverToBoxAdapter(child: SettingsNote(text: l10n.iconsUnavailable)),
            const SliverToBoxAdapter(child: SizedBox(height: Space.xl)),
          ],
        ),
      ),
    );
  }
}

String labelFor(UiIconVariant variant, AppLocalizations l10n) => switch (variant) {
  UiIconVariant.mono => l10n.iconsVariantMono,
  UiIconVariant.themed => l10n.iconsVariantThemed,
  UiIconVariant.showcase => l10n.iconsVariantShowcase,
};

/// The dock's three destinations, at the dock's size.
///
/// The labels are part of the drawing rather than decoration: the dock shows a
/// word under each icon, and a coloured icon beside a 9-point label is a
/// different balance from a coloured icon alone — which is the whole question.
class _DockPreview extends StatelessWidget {
  const _DockPreview({required this.variant, required this.colors});

  final UiIconVariant variant;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (icon, label) in [
          (UiIconName.board, 'Board'),
          (UiIconName.workspaces, 'Workspaces'),
          (UiIconName.settings, 'Settings'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UiIcon(
                  icon,
                  size: 22,
                  variant: variant,
                  color: colors.text,
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: TextSize.tiny,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The terminal's four toolbar buttons.
class _ToolbarPreview extends StatelessWidget {
  const _ToolbarPreview({
    required this.variant,
    required this.colors,
    required this.cursor,
    required this.background,
  });

  final UiIconVariant variant;
  final HerdrColors colors;
  final Color cursor;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final icon in const [
          UiIconName.attach,
          UiIconName.panes,
          UiIconName.split,
          UiIconName.more,
        ])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            child: UiIcon(
              icon,
              variant: variant,
              color: cursor,
              background: background,
            ),
          ),
      ],
    );
  }
}

/// One labelled specimen, on an optional ground.
class _Row extends StatelessWidget {
  const _Row({
    required this.variant,
    required this.colors,
    required this.label,
    required this.child,
    this.ground,
  });

  final UiIconVariant variant;
  final HerdrColors colors;
  final String label;
  final Widget child;
  final Color? ground;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sectionTitle(context, label),
            style: TextStyle(
              color: colors.textFaint,
              fontSize: TextSize.micro,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: Space.sm),
          Center(
            child: Container(
              padding: const EdgeInsets.all(Space.sm),
              decoration: ground == null
                  ? null
                  : BoxDecoration(
                      color: ground,
                      borderRadius: BorderRadius.circular(Radii.uniform),
                    ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled card of specimens.
///
/// Hand-built rather than `SettingsGroup`, because a group's rows are settings
/// rows and these are pictures: they need a ground of their own and a caption
/// per specimen, which is a different shape from "one setting, one control".
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.colors,
    required this.rows,
  });

  final String title;
  final HerdrColors colors;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
            child: Text(
              sectionTitle(context, title),
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.micro,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(Radii.uniform),
              ),
              child: Column(children: rows),
            ),
          ),
        ],
      ),
    );
  }
}
