import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Scroll behaviour for a settings-shaped screen: no bounce, no glow.
///
/// WHY THIS IS DELIBERATE. A settings list is usually SHORTER than the screen,
/// so a drag has nothing to reveal — the rubber band pulls the whole page down
/// and lets it snap back, which reads as a bug rather than as a gesture. On the
/// board and the workspace tree the bounce is worth keeping: those lists really
/// do continue, and the resist-and-return is how the platform says "that is the
/// end". Here it is a gesture with no meaning attached.
///
/// Both flags are needed. `ClampingScrollPhysics` removes the bounce; the
/// `overscroll: false` flag removes Android's glow, which would otherwise be
/// the same meaningless feedback in a different shape. `overscroll: false`
/// CANNOT be applied app-wide — the board and the workspace tree depend on
/// overscroll for pull-to-refresh, and turning it off there would silently
/// break the gesture.
ScrollBehavior settingsScrollBehavior(BuildContext context) =>
    ScrollConfiguration.of(context)
        .copyWith(physics: const ClampingScrollPhysics(), overscroll: false);

/// The grouped-list vocabulary the settings-shaped screens are built from.
///
/// Extracted because two screens need exactly the same four rules, and the
/// second one (the host form) was already drifting: the same "label, then
/// control, then a paragraph" arrangement that made the settings page read as a
/// form rather than a list. A design system with one user is a coincidence; a
/// design system with two is a decision.
///
/// The four rules, all of them the platform's rather than this project's
/// invention:
///
///   1. ONE ROW PER SETTING, label left and control right, on the same line.
///   2. A HAIRLINE BETWEEN ROWS, inset to where the label starts. The inset is
///      the point: a rule spanning the whole card draws a box, and a rule
///      starting where the text starts draws a list.
///   3. EXPLANATION IS A SECOND LINE OF ITS OWN ROW, smaller and fainter —
///      never a paragraph floating between rows, where which row it belongs to
///      is a guess.
///   4. TITLES ABOVE THE CARD, footnotes below it.

/// A titled card of rows.
///
/// The rules between rows are drawn HERE rather than by each row. Interleaving
/// in one place is what makes them impossible to forget: a row cannot opt out
/// of the list, and adding a setting cannot silently produce two rows with
/// nothing between them.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({required this.rows, this.title, super.key});

  final String? title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) children.add(const SettingsRule());
      children.add(rows[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The gap above a card belongs to the GROUP, not to its title. Tying it
        // to the title left untitled groups butted directly against the card
        // above them, which reads as one card that changed colour halfway.
        Padding(
          padding: EdgeInsets.fromLTRB(
            Space.lg + Space.xs,
            Space.xl,
            Space.lg,
            title == null ? 0 : Space.sm,
          ),
          child: title == null
              ? null
              : Text(
                  sectionTitle(context, title!),
                  style: TextStyle(
                    color: colors.textFaint,
                    fontSize: TextSize.note,
                    fontWeight: FontWeight.w500,
                  ),
                ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: Space.lg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(Radii.uniform),
            // No outline, same as every other card: the surface step and the
            // shadow already say "this is a card", and a hairline on top of
            // both is a third way of saying it. The rules BETWEEN rows stay —
            // they are what makes it read as a list rather than a paragraph.
            boxShadow: Elevation.card(colors),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.uniform),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

/// The rule between two rows.
///
/// `width: double.infinity` is not decoration. A `SizedBox` with only a HEIGHT,
/// wrapping a `ColoredBox` with no child, resolves to the smallest size its
/// constraints allow — and a `Column` hands its children loose cross-axis
/// constraints, so "smallest" is ZERO WIDE. The first version of this rule
/// painted nothing at all, and the cards it was written to separate still read
/// as unseparated paragraphs.
class SettingsRule extends StatelessWidget {
  const SettingsRule({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: Space.lg),
    child: SizedBox(
      height: 0.5,
      width: double.infinity,
      child: ColoredBox(color: HerdrTheme.of(context).hairline),
    ),
  );
}

/// One row: what it is on the left, what it does on the right.
///
/// The trailing widget is aligned to the FIRST line, which is what keeps a
/// two-line row looking like one setting rather than a label with a stray
/// switch beside its explanation.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.label,
    this.note,
    this.trailing,
    this.expandTrailing = false,
    this.below,
    this.labelFontSize = TextSize.strong,
    this.labelColor,
    super.key,
  });

  final String label;

  /// One sentence under the label, in the row it explains.
  final String? note;

  final Widget? trailing;

  /// Gives the trailing widget the remaining width instead of its intrinsic
  /// width. For text fields: a hostname field that shrink-wraps to its
  /// placeholder is a field that grows as you type.
  final bool expandTrailing;

  /// A full-width control beneath the label line — a slider, a tall text area.
  final Widget? below;

  final double labelFontSize;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    final explanation = note == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note!,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.note,
                height: 1.3,
              ),
            ),
          );

    final heading = Text(
      label,
      // ONE LINE, ALWAYS. A settings label that wraps turns its row into a
      // paragraph with a control beside the first half of it, and the two-line
      // row is taller than every other row on the screen — so the one setting
      // with a slightly long name is also the one that looks broken. The fix
      // for a label that no longer fits is a shorter label, not a second line;
      // this is the guard that keeps the failure visible (an ellipsis at 1.0
      // scale is a bug report) rather than silent.
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: labelColor ?? colors.text,
        fontSize: labelFontSize,
        height: 1.25,
      ),
    );

    // `width: double.infinity` for the same reason [SettingsRule] needs it: a
    // Column hands its children loose cross-axis constraints, and both
    // `CupertinoSlider` and a bare `TextField` resolve those to a fraction of
    // the available width rather than to all of it. Without this a slider's
    // track stops two-thirds of the way across the card.
    // The gap ABOVE a full-width control, and it is not decoration: without it
    // the control's own rounded top edge sits flush against the label's text,
    // which reads as the label being part of the control rather than naming it.
    // The complaint that produced this was concrete — the segmented control and
    // the private-key area both felt cramped — and both go through this slot,
    // so this is the one place it has to be fixed.
    final bottom = below == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: SizedBox(width: double.infinity, child: below),
          );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.lg,
        below == null ? Space.md : Space.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (expandTrailing)
                SizedBox(width: _labelColumnWidth, child: heading)
              else
                Expanded(child: heading),
              if (trailing != null) ...[
                if (!expandTrailing) const SizedBox(width: Space.md),
                if (expandTrailing) Expanded(child: trailing!) else trailing!,
              ],
            ],
          ),
          // The explanation spans the WHOLE card, not just the label's column.
          // The control only occupies the first line, so constraining the note
          // to the label's width wasted the right third of every card — which
          // mattered the moment the app moved to a monospace face, where the
          // same sentence is measurably wider and two lines became three.
          ?explanation,
          ?bottom,
        ],
      ),
    );
  }
}

/// A switch, with the reason it exists spelled out underneath when there is one.
///
/// ONE WIDGET, BECAUSE THE SIZE IS THE POINT. Three screens used to draw their
/// own `CupertinoSwitch`, all at Flutter's natural **59x39 points** — measured,
/// not remembered, after this file guessed 51x31 and a test proved otherwise.
/// That is not wrong in isolation; it is wrong HERE, where the rows are tighter
/// than iOS's and the label beside it is 12-point monospace. The switch ended
/// up the heaviest object on a page made almost entirely of text, and it read
/// as the most important thing in every row it appeared in.
///
/// SO IT IS DRAWN AT [switchScale] OF ITS NATURAL SIZE, and the row around it
/// became the target instead. Shrinking a control without replacing the touch
/// area is how you make something hard to hit; the row tap is what pays for the
/// reduction, and it is also what iOS Settings does — the whole line toggles.
/// The switch keeps its own gestures, so it can still be dragged.
///
/// The scale is applied with `Transform`, which paints smaller without claiming
/// less layout. The row's height and the column the control sits in are
/// unchanged, so nothing about the page reflows when this gets smaller.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.note,
    super.key,
  });

  final String label;

  /// One sentence under the label, in the row it explains.
  final String? note;

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    void toggle() {
      unawaited(HapticFeedback.selectionClick());
      onChanged(!value);
    }

    return GestureDetector(
      onTap: toggle,
      // Opaque, so the gaps between the label and the control are part of the
      // target too. Without it the row only responds where it has painted text.
      behavior: HitTestBehavior.opaque,
      child: SettingsRow(
        label: label,
        note: note,
        trailing: Transform.scale(
          scale: switchScale,
          // Anchored right, because the switch's column is sized for the
          // UNSCALED switch: scaling about the centre would pull it away from
          // the card's trailing edge by half the difference.
          alignment: Alignment.centerRight,
          child: CupertinoSwitch(
            value: value,
            // ACCENT, not the status green. `colors.done` means "this agent
            // finished" everywhere else in the app, and a switch that borrowed
            // it would be saying a status word while meaning a setting — the one
            // thing the palette is not allowed to do.
            activeTrackColor: colors.accent,
            onChanged: (v) {
              unawaited(HapticFeedback.selectionClick());
              onChanged(v);
            },
          ),
        ),
      ),
    );
  }
}

/// How much of its natural size the settings switch is drawn at.
///
/// 0.8 turns 59x39 into roughly 47x31 — which is where Apple's own switch sits,
/// so this is not "a small switch", it is the platform's switch at the size
/// people already know. Enough to stop dominating a row without turning the
/// knob into a dot, and a constant rather than a literal at each call site so
/// the screens that use it cannot drift apart.
const double switchScale = 0.8;

/// Wide enough for the longest label these forms use, narrow enough to leave a
/// hostname room to breathe. A fixed column rather than a flexible one because
/// a label column that resizes per row makes the fields ragged.
const double _labelColumnWidth = 104;

/// Section headers are upper-cased only where upper-casing means something.
///
/// `toUpperCase()` is a NO-OP on Han characters — 字号 stays 字号 — so a
/// Chinese header would render in the same casing as the Latin one and the two
/// locales would look like they came from different systems. The rule is
/// therefore about the script, not about the string, and it cannot be expressed
/// as a style. (Same finding as the board's section headings; see ADR-007.)
String sectionTitle(BuildContext context, String text) {
  final locale = Localizations.localeOf(context).languageCode;
  return locale == 'zh' ? text : text.toUpperCase();
}

/// A footnote below a card, at the same left inset as the card's own text.
class SettingsNote extends StatelessWidget {
  const SettingsNote({required this.text, this.isError = false, super.key});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg + Space.xs,
        Space.sm,
        Space.lg + Space.xs,
        0,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? colors.statusTextDied : colors.textFaint,
          fontSize: TextSize.note,
          height: 1.35,
        ),
      ),
    );
  }
}
