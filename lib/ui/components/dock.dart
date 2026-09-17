import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/glass.dart';
import 'package:herdr_pocket/ui/design/safety_inset.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';

/// Where the dock's items navigate to.
///
/// A root is a whole view, not a pushed page: switching roots must not grow the
/// navigation stack, or "back" would walk through every tab the user ever
/// tapped instead of leaving the screen they are on.
enum RootView {
  board,
  workspaces,
  settings,
}

/// The floating navigation bar.
///
/// Floating rather than edge-to-edge, and that is a decision about the
/// content, not about taste. The board and the workspace tree are both long
/// scrolling lists; a bar welded to the bottom edge crops the last row and
/// makes "is there more?" unanswerable. Lifting it off the edge leaves the list
/// visibly continuing underneath, so the shape of the page is never a mystery.
///
/// The glass is the same [HerdrGlass] the rest of the chrome uses, so the dock
/// is a material the app already has rather than a second one. It follows the
/// same switch as every other chrome surface, which is ON unless the user turned
/// it off — and the cost that switch exists for is not the blur itself but the
/// number of surfaces paying for it, so there is exactly one here.
class HerdrDock extends ConsumerWidget {
  const HerdrDock({
    required this.views,
    required this.selected,
    required this.onSelect,
    required this.glass,
    this.labels = const {},
    super.key,
  });

  final List<RootView> views;
  final RootView selected;
  final ValueChanged<RootView> onSelect;
  final bool glass;

  /// Localized labels, keyed by view. An empty map falls back to the icon
  /// alone, which is what the accessibility label below still makes usable.
  final Map<RootView, String> labels;

  /// How much vertical room the dock occupies, including its margins.
  ///
  /// Exported because every scrolling page under it has to reserve this much
  /// bottom padding. A magic number duplicated in five places is how a dock
  /// ends up covering the last agent on one screen and not another.
  static const double height = 62;
  static const double bottomMargin = Space.lg;

  /// Total space a page must leave at the bottom for the dock to float over
  /// it, NOT counting the system's own inset.
  static const double reserve = height + bottomMargin + Space.lg;

  /// [reserve], plus whatever the system reserves at the bottom of the window.
  ///
  /// THE HALF THAT ONLY MATTERS ON SOME PHONES. The dock is positioned off the
  /// WINDOW's bottom edge, and on an edge-to-edge device that edge is under the
  /// navigation bar — so the reserve has to grow by the same amount the dock
  /// moved up, or the last row of a list ends up behind it. On a device whose
  /// window already excludes the bar this is `reserve` exactly, which is why
  /// the old constant was right on the machine it was written on.
  static double reserveOf(BuildContext context) =>
      reserve + bottomChromeInset(context);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final iconSet = ref.watch(settingsProvider.select((s) => s.iconSet));

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final view in views)
          _DockItem(
            view: view,
            label: labels[view],
            selected: view == selected,
            colors: colors,
            iconSet: iconSet,
            onTap: () => onSelect(view),
          ),
      ],
    );

    // Positioned off the window edge by the caller, so the system's own inset
    // (and the user's safety margin, which the root folded into it) is added
    // here rather than assumed away. Without this the dock sits UNDER the
    // gesture bar on any edge-to-edge device.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Space.lg,
        0,
        Space.lg,
        bottomMargin + bottomChromeInset(context),
      ),
      child: SizedBox(
        height: height,
        child: Center(
          child: glass
              ? HerdrGlass(
                  colors: colors,
                  tintAlpha: 0.55,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                    child: row,
                  ),
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(Radii.uniform),
                    border: Border.all(color: colors.hairline),
                    boxShadow: Elevation.card(colors),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                    child: row,
                  ),
                ),
        ),
      ),
    );
  }
}

/// One dock item.
///
/// Selection is shown with the ink colour plus a filled glyph, NOT with a pill
/// behind the icon. A pill is a second shape in a design that has exactly one
/// radius and one card shape; carrying selection in weight alone keeps the bar
/// reading as a single sheet rather than a row of buttons.
class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.view,
    required this.label,
    required this.selected,
    required this.colors,
    required this.iconSet,
    required this.onTap,
  });

  final RootView view;
  final String? label;
  final bool selected;
  final HerdrColors colors;
  final AppIconSet iconSet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? colors.text : colors.textFaint;
    final glyph = _glyph(colors, color);

    return Semantics(
      // The identifier is what a device check taps; the label is what a screen
      // reader says. They are different jobs and both are wanted.
      identifier: switch (view) {
        RootView.board => UiId.dockBoard,
        RootView.workspaces => UiId.dockWorkspaces,
        RootView.settings => UiId.dockSettings,
      },
      button: true,
      selected: selected,
      label: label ?? view.name,
      // BOTH, and for the same reason as the board's navbar entries: without
      // `onTap` the node is a button with no action, and without
      // `excludeSemantics` the visible label is merged in ON TOP of the label
      // above it — TalkBack read every dock item twice ("看板 看板").
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              glyph,
              if (label != null) ...[
                const SizedBox(height: 3),
                Text(
                  label!,
                  maxLines: 1,
                  style: TextStyle(
                    color: color,
                    fontSize: TextSize.tiny,
                    // The selected item carries the app's normal weight; the
                    // other does not. Weight, not opacity, is what survives
                    // being read at 10px on a phone outdoors.
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    height: 1,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The icon, in whichever set the user chose.
  ///
  /// Selected-ness is carried the same way in both sets — a heavier ink and a
  /// FILLED glyph — because that is a decision about this bar, not about which
  /// artwork is inside it. The themed set gets there from one asset: slot 1 is
  /// the body, so [UiIcon.filled] false leaves the same drawing as an outline.
  Widget _glyph(HerdrColors colors, Color color) {
    if (iconSet == AppIconSet.themed) {
      return UiIcon(
        switch (view) {
          RootView.board => UiIconName.board,
          RootView.workspaces => UiIconName.workspaces,
          RootView.settings => UiIconName.settings,
        },
        size: 22,
        variant: UiIconVariant.themed,
        color: color,
        // The dock floats over a card-coloured surface; the outline version
        // needs to know that so its body reads as empty rather than as ink.
        background: colors.surface,
        filled: selected,
      );
    }
    final (IconData icon, IconData selectedIcon) = switch (view) {
      RootView.board => (
          CupertinoIcons.square_list,
          CupertinoIcons.square_list_fill,
        ),
      RootView.workspaces => (
          CupertinoIcons.rectangle_stack,
          CupertinoIcons.rectangle_stack_fill,
        ),
      RootView.settings => (
          CupertinoIcons.gear_alt,
          CupertinoIcons.gear_alt_fill,
        ),
    };
    return Icon(selected ? selectedIcon : icon, size: 22, color: color);
  }
}
