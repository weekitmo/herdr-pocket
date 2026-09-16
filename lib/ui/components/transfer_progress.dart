import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The pieces both transfer panels are made of.
///
/// EXTRACTED, NOT COPIED. The SSH download sheet and the update sheet report
/// the same three things — a label over a bar over a line of bytes — and the
/// second one was written by lifting these widgets out of the first rather than
/// by writing them again. The rules encoded here (the full-width requirement on
/// the bar, the indeterminate fallback, the app's own accent rather than
/// Cupertino's blue) are the reason: a second hand-written copy would drift,
/// and the way it would drift is invisible until someone looks at two screens
/// side by side.
///
/// This file is deliberately dumb: no state, no providers, no assumptions about
/// what is being transferred. What a transfer IS stays with its owner.

/// The progress bar: two boxes and a clip.
///
/// Hand-drawn because a Material `LinearProgressIndicator` is out of the
/// question, and because `CupertinoActivityIndicator` is a spinner, not a bar.
class TransferBar extends StatelessWidget {
  /// Draws a bar at [value] (0..1).
  const TransferBar({required this.colors, required this.value, super.key});

  /// The active palette.
  final HerdrColors colors;

  /// How far along, 0..1.
  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.uniform),
      child: SizedBox(
        height: 6,
        // The full-width requirement from `AGENTS.md`: inside a Column a bare
        // ColoredBox gets a loose cross-axis constraint and resolves to zero
        // width, which draws nothing at all and looks like the transfer is
        // stuck before it started.
        width: double.infinity,
        child: Stack(
          children: [
            Container(color: colors.surfaceRaised),
            FractionallySizedBox(
              widthFactor: value,
              child: Container(color: colors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// A bar, a caption and a cancel button.
class TransferProgress extends StatelessWidget {
  /// Holds one in-flight transfer's presentation.
  const TransferProgress({
    required this.colors,
    required this.label,
    required this.text,
    required this.fraction,
    required this.cancelLabel,
    required this.onCancel,
    super.key,
  });

  /// The active palette.
  final HerdrColors colors;

  /// The one-word state, e.g. "下载中".
  final String label;

  /// The detail line: how many bytes, and of what.
  final String text;

  /// 0..1, or null when nothing knows how large the thing is.
  final double? fraction;

  /// The cancel button's text.
  final String cancelLabel;

  /// What cancel does.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final value = fraction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
        ),
        const SizedBox(height: Space.sm),
        if (value != null)
          TransferBar(colors: colors, value: value)
        else
          // An indeterminate sweep rather than a stuck-at-zero bar: a bar that
          // does not move is indistinguishable from a hang, and the far end not
          // reporting a size is common enough to deserve an honest answer.
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoActivityIndicator(color: colors.textDim),
          ),
        const SizedBox(height: Space.sm),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.textDim,
            fontSize: TextSize.meta,
            fontFamily: HerdrFonts.mono,
            fontFamilyFallback: HerdrFonts.monoFallback,
          ),
        ),
        const SizedBox(height: Space.md),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          onPressed: onCancel,
          child: Text(
            cancelLabel,
            style: TextStyle(color: colors.accent, fontSize: TextSize.body),
          ),
        ),
      ],
    );
  }
}

/// An icon over a sentence: how a transfer ended.
class TransferOutcome extends StatelessWidget {
  /// Holds one finished transfer.
  const TransferOutcome({
    required this.colors,
    required this.icon,
    required this.tint,
    required this.text,
    super.key,
  });

  /// The active palette.
  final HerdrColors colors;

  /// The glyph. Cupertino's, never Material's.
  final IconData icon;

  /// Usually a status colour — success or failure is what a status colour is
  /// for, and this is one of the few places in the app where it is apt.
  final Color tint;

  /// What happened, in one sentence.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 28, color: tint),
        const SizedBox(height: Space.sm),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.text,
            fontSize: TextSize.body,
            height: 1.4,
            fontFamily: HerdrFonts.mono,
            fontFamilyFallback: HerdrFonts.monoFallback,
          ),
        ),
      ],
    );
  }
}

/// One line of text, optionally dimmed.
class TransferLine extends StatelessWidget {
  /// Holds the line.
  const TransferLine({
    required this.colors,
    required this.text,
    this.dim = false,
    super.key,
  });

  /// The active palette.
  final HerdrColors colors;

  /// The sentence.
  final String text;

  /// Whether this is secondary text.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: dim ? colors.textDim : colors.text,
        fontSize: TextSize.body,
      ),
    );
  }
}
