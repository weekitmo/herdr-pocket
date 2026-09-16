import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Measures a widget so [showHerdrMenu] can hang off it.
///
/// CALL THIS BEFORE ANY `await`. A `Rect` is a value, so the menu cannot be
/// positioned from a `BuildContext` that a route change has since disposed —
/// and a `GlobalKey` on the button is worse still: `CupertinoNavigationBar`
/// wraps its content in a Hero for the route transition, the flight builds the
/// child twice, and a GlobalKey cannot be in two places at once. That throws
/// "Multiple widgets used the same GlobalKey" inside the navbar it was added to.
Rect? menuAnchorRect(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject()
      as RenderBox?;
  final origin = overlay == null
      ? box.localToGlobal(Offset.zero)
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  return origin & box.size;
}

/// One row of a [showHerdrMenu].
///
/// THE SAME MENU IS ALSO THE APP'S DROPDOWN, which is why [icon] is optional
/// and [selected] exists. An action menu names things to DO and every row earns
/// a glyph; a picker names things to CHOOSE BETWEEN, where the only meaningful
/// mark is the one already chosen. Two widgets drawing the same card, the same
/// rules, the same type scale — differing only in whether there is a tick —
/// would be one rule with two implementations.
class HerdrMenuItem<T extends Object> {
  const HerdrMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.cupertinoIcon,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
    this.identifier,
  });

  final T value;
  final String label;

  /// The themed set's glyph. Null in a picker, where there is nothing to say
  /// with one.
  final UiIconName? icon;

  /// The platform glyph, for when the user is on the system icon set.
  final IconData? cupertinoIcon;

  /// Drawn in the `died` hue. Reserved for things that cannot be undone.
  final bool destructive;

  final bool enabled;

  /// The current choice, ticked. Only meaningful in a picker.
  final bool selected;

  /// A stable hook for automated checks — see [UiId]. Optional, because most
  /// menus are reached by tapping the thing that opens them and never need to
  /// be addressed row by row; a picker's rows do, because their labels are
  /// values that also appear on the row behind them.
  final String? identifier;

  /// Whether this row needs the glyph column at all.
  bool get _hasGlyph => selected || icon != null || cupertinoIcon != null;
}

/// A menu that hangs off the control that opened it.
///
/// WHY NOT `CupertinoActionSheet`, WHICH THE APP USED HERE. A sheet rises from
/// the bottom edge and belongs to the SCREEN; a menu drops from the button that
/// opened it and belongs to the BUTTON. Reaching to the bottom of a phone to
/// answer a question asked at the top of it is a journey for no reason, and it
/// loses the one thing a menu has over a sheet — you can see what you tapped
/// while you are choosing.
///
/// WHY NOT `showMenu`, WHICH IS THE ANCHORED ONE. It is Material: it brings the
/// Material ink, the Material elevation and the Material type ramp into an app
/// that has none of the three, and `no_material_test.dart` exists to keep that
/// from creeping in.
///
/// THE TYPE SIZE IS THE POINT, TOO. Every action sheet this app used drew its
/// rows with a bare `Text`, which inherits Cupertino's ~20-point action style —
/// against a body size of 13. That is a 1.5x type jump at exactly the moment
/// the user is reading options, and it made the sheets look like they came from
/// another app. Rows here are drawn on the app's own [TextSize] ladder like
/// everything else.
///
/// Positioning is measured once, at open time, from [anchor]. The alternative —
/// a [LayerLink] with a composited follower — tracks the anchor through scrolls
/// and rebuilds, which is what a menu attached to a scrolling row needs. Every
/// anchor in this app is in a navbar that does not move, so measuring once is
/// the same answer for less machinery.
Future<T?> showHerdrMenu<T extends Object>(
  BuildContext context, {
  required List<HerdrMenuItem<T>> items,
  Rect? anchorRect,
  bool themedIcons = true,
}) {
  final colors = HerdrTheme.of(context);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;

  const width = 232.0;
  const gap = Space.sm;

  // Right edges aligned, which is what an overflow button at the trailing edge
  // of a navbar implies. Falls back to the screen's own margin when there is no
  // anchor to measure, so a caller that has no button still gets a sane menu.
  final size = overlay?.size ?? MediaQuery.sizeOf(context);
  final anchor = anchorRect;
  // Right edges aligned, which is what an overflow button at the trailing edge
  // of a navbar implies. Falls back to the screen's own margin when there is no
  // anchor to measure, so a caller that has no button still gets a sane menu.
  final left = anchor == null
      ? size.width - width - Space.lg
      : (anchor.right - width).clamp(Space.lg, size.width - width - Space.lg);

  // WHICH SIDE IT OPENS ON IS DECIDED FROM AN ESTIMATE, and the exact placement
  // is decided from the real size a frame later. The estimate exists only to
  // pick the animation's origin — the card unfolds out of the corner it is
  // anchored to, and that corner is above the anchor when the menu opens
  // upward.
  final estimatedHeight = _estimatedHeight(items.length);
  final opensUpward = anchor != null &&
      anchor.bottom + gap + estimatedHeight > size.height - Space.lg &&
      anchor.top - gap - estimatedHeight >= Space.lg;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizationsStub.dismiss,
    // Faint. A menu is not a modal — the screen behind it is still the context
    // you are choosing from, and dimming it to grey says otherwise.
    barrierColor: const Color(0x1A000000),
    transitionDuration: Motion.press,
    pageBuilder: (context, _, _) => CustomSingleChildLayout(
      delegate: _MenuPlacement(
        anchor: anchor,
        left: left,
        top: Space.xxl,
        width: width,
        gap: gap,
        margin: Space.lg,
      ),
      child: _MenuCard<T>(
        items: items,
        colors: colors,
        themedIcons: themedIcons,
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          // Scales from the corner it is anchored to, so it reads as unfolding
          // out of the button rather than appearing over it.
          alignment: opensUpward ? Alignment.bottomRight : Alignment.topRight,
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Roughly what a menu of [rows] rows will measure, before it is built.
///
/// A row is the app's body size plus [Space.md] above and below, and the rules
/// between rows are a hairline each. Close enough to answer "is there room
/// below the anchor", which is all it is used for.
double _estimatedHeight(int rows) =>
    rows * (TextSize.body + Space.md * 2) + (rows - 1) + 2;

/// Places the menu, flipping it above the anchor when it would not fit below.
///
/// A [Stack] with a `Positioned` cannot do this: the menu's height is not known
/// until it has been laid out, and by then the position has already been
/// computed. This delegate is handed the child's real [Size] before it has to
/// answer, which is the whole reason it exists.
class _MenuPlacement extends SingleChildLayoutDelegate {
  const _MenuPlacement({
    required this.anchor,
    required this.left,
    required this.top,
    required this.width,
    required this.gap,
    required this.margin,
  });

  /// The control the menu hangs off, or null when there is none.
  final Rect? anchor;

  /// Where to put it when there is no anchor to measure.
  final double left;
  final double top;

  final double width;
  final double gap;
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: constraints.maxHeight - margin * 2,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final anchor = this.anchor;
    if (anchor == null) return Offset(left, top);

    // The clamp is the floor: if it fits on neither side, the menu is pinned
    // inside the screen rather than let off the edge. A menu that runs off the
    // bottom is a menu whose last option cannot be picked — which is exactly
    // how the third option of a three-option dropdown became unreachable.
    final below = anchor.bottom + gap;
    final above = anchor.top - gap - childSize.height;
    final fitsBelow = below + childSize.height <= size.height - margin;
    final fitsAbove = above >= margin;
    final resolvedTop = switch ((fitsBelow, fitsAbove)) {
      // Below, because that is where a menu hung off a control belongs.
      (true, _) => below,
      // Flipped, because the room is on the other side.
      (false, true) => above,
      // Neither fits — a menu taller than the screen. Pinned inside the screen
      // and clipped rather than let off the edge: a menu that runs off the
      // bottom is one whose last option cannot be picked, which is how the
      // third option of a three-option dropdown became unreachable.
      (false, false) => (size.height - margin - childSize.height)
          .clamp(margin, size.height - margin),
    };

    return Offset(
      left.clamp(margin, size.width - width - margin),
      resolvedTop,
    );
  }

  @override
  bool shouldRelayout(_MenuPlacement old) =>
      old.anchor != anchor ||
      old.left != left ||
      old.top != top ||
      old.width != width ||
      old.gap != gap ||
      old.margin != margin;
}

class _MenuCard<T extends Object> extends StatelessWidget {
  const _MenuCard({
    required this.items,
    required this.colors,
    required this.themedIcons,
  });

  final List<HerdrMenuItem<T>> items;
  final HerdrColors colors;
  final bool themedIcons;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: Border.all(color: colors.hairline),
        boxShadow: Elevation.card(colors),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0)
              // Inset to where the label starts, so the rule reads as a list
              // rather than as a box — the same rule the settings rows use.
              Padding(
                padding: EdgeInsets.only(left: _labelInset),
                child: SizedBox(
                  height: 1,
                  width: double.infinity,
                  child: ColoredBox(color: colors.hairlineQuiet),
                ),
              ),
            _MenuRow<T>(
              item: item,
              colors: colors,
              themedIcons: themedIcons,
              showGlyphColumn: showGlyphColumn,
            ),
          ],
        ],
      ),
    );
  }

  /// Icon column plus its gap plus the row's own left padding — or just the
  /// row's padding when there is no column to line up with.
  double get _labelInset =>
      showGlyphColumn ? Space.md + 18 + Space.md : Space.md;

  /// Whether any row in this card carries a glyph, which decides whether the
  /// whole card reserves the column. A picker whose labels start at a different
  /// x from each other looks broken.
  bool get showGlyphColumn => items.any((i) => i._hasGlyph);
}

class _MenuRow<T extends Object> extends StatelessWidget {
  const _MenuRow({
    required this.item,
    required this.colors,
    required this.themedIcons,
    required this.showGlyphColumn,
  });

  final HerdrMenuItem<T> item;
  final HerdrColors colors;
  final bool themedIcons;

  /// True when ANY row in the card has a glyph, so the labels all start at the
  /// same x. A picker where only the chosen row is indented looks broken.
  final bool showGlyphColumn;

  @override
  Widget build(BuildContext context) {
    final tint = !item.enabled
        ? colors.textFaint
        : item.destructive
        ? colors.died
        : colors.text;

    final row = GestureDetector(
      onTap: item.enabled ? () => Navigator.of(context).pop(item.value) : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            if (showGlyphColumn)
              SizedBox(
                width: 18,
                child: Center(child: _glyph(tint)),
              ),
            if (showGlyphColumn) const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tint, fontSize: TextSize.body),
              ),
            ),
          ],
        ),
      ),
    );

    final identifier = item.identifier;
    if (identifier == null) return row;
    // The identifier sits OUTSIDE the gesture detector, so the node a check
    // taps is the whole row rather than the text inside it: the centre of the
    // row is the same point for every row, which is what makes a script that
    // taps two of them in sequence readable.
    return Semantics(identifier: identifier, button: true, child: row);
  }

  /// The tick, the themed glyph, or nothing at all.
  Widget _glyph(Color tint) {
    if (item.selected) {
      // The CHECKMARK is the platform's own in both icon sets, deliberately:
      // "this one is chosen" is a statement about the list, not part of the
      // app's iconography, and the themed set has no tick to offer.
      return Icon(CupertinoIcons.check_mark, size: 15, color: colors.accent);
    }
    if (item.icon == null && item.cupertinoIcon == null) {
      return const SizedBox.shrink();
    }
    if (themedIcons) {
      return UiIcon(
        item.icon!,
        size: 18,
        variant: UiIconVariant.themed,
        color: tint,
        background: colors.surfaceRaised,
      );
    }
    return Icon(
      item.cupertinoIcon ?? CupertinoIcons.circle,
      size: 17,
      color: tint,
    );
  }
}

/// A row label for a `CupertinoActionSheetAction`, at the app's own type size.
///
/// THE SIZE IS THE WHOLE FUNCTION. `CupertinoActionSheetAction` draws whatever
/// child it is given, and a bare `Text` inherits Cupertino's action style —
/// about 20 points. This app's body size is 13, so every action sheet it has
/// ever shown has been a 1.5x type jump at exactly the moment the user is
/// reading options, and it made them look like they came from another app.
///
/// No colour is set, because `isDestructiveAction` colours the text itself and
/// overriding it would quietly turn the delete row back to normal.
Text actionSheetLabel(String text) =>
    Text(text, style: const TextStyle(fontSize: TextSize.body));

/// One string, and it is here rather than in the l10n files because it is never
/// shown: it is the label a screen reader announces when a barrier with no
/// visible text is tapped to dismiss.
abstract final class MaterialLocalizationsStub {
  static const String dismiss = 'Dismiss';
}
