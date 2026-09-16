import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/domain/git/git_diff.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Renders a parsed unified diff.
///
/// Structured rather than colourised. The tempting shortcut is to run
/// `git diff --color=always` and put the ANSI on screen; that would make the
/// hue a subprocess's opinion about a terminal instead of a property of this
/// app's palette, and on a light background it would be a wall of pink on
/// white. Parsing the plain diff costs one pass and buys the theme, both light
/// and dark, and the monospace grid.
///
/// The two tints come from the theme's own semantics — `done` for added, `died`
/// for removed — at low alpha over the ground. Those hues already mean
/// "finished" and "gone" everywhere else in the app, so a diff row reuses a
/// vocabulary the reader has already learned instead of inventing a second one.
/// No gradients: a row is one flat colour, per the project rule.
class GitDiffView extends StatelessWidget {
  /// Renders [diff].
  const GitDiffView({
    required this.diff,
    required this.colors,
    this.textStyle,
    super.key,
  });

  final GitDiff diff;
  final HerdrColors colors;

  /// Base style for diff lines. Defaults to the machine voice at 12.5px —
  /// smaller than prose because a diff is dense and is read in blocks.
  final TextStyle? textStyle;

  /// Alpha for the added/removed row washes.
  ///
  /// Low on purpose: at 0.16 the tint reads as a row, not as a highlight, and
  /// the text on it keeps its contrast rather than becoming coloured-on-colour.
  static const _rowAlpha = 0.16;

  @override
  Widget build(BuildContext context) {
    final base = textStyle ??
        TextStyle(
          color: colors.text,
          fontSize: TextSize.note,
          height: 1.45,
          fontFamily: HerdrFonts.mono,
        );

    final rows = <Widget>[];
    for (final hunk in diff.hunks) {
      if (hunk.header.isNotEmpty) {
        rows.add(_HunkHeader(header: hunk.header, colors: colors, base: base));
      }
      for (final line in hunk.lines) {
        rows.add(_DiffLineRow(line: line, colors: colors, base: base));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// The `@@ … @@` line, plus the `diff --git` preamble folded in with it.
class _HunkHeader extends StatelessWidget {
  const _HunkHeader({
    required this.header,
    required this.colors,
    required this.base,
  });

  final String header;
  final HerdrColors colors;
  final TextStyle base;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.xs),
      color: colors.surfaceRaised,
      child: Text(header, style: base.copyWith(color: colors.textFaint)),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({
    required this.line,
    required this.colors,
    required this.base,
  });

  final GitDiffLine line;
  final HerdrColors colors;
  final TextStyle base;

  @override
  Widget build(BuildContext context) {
    final isAdded = line.type == GitDiffLineType.added;
    final isRemoved = line.type == GitDiffLineType.removed;

    final color = switch (line.type) {
      GitDiffLineType.added => colors.text,
      GitDiffLineType.removed => colors.text,
      GitDiffLineType.meta => colors.textFaint,
      GitDiffLineType.hunkHeader => colors.textFaint,
      GitDiffLineType.context => colors.textDim,
    };

    // The gutter exists so a reader can tell an added line from a removed one
    // in peripheral vision. Colour alone would fail anyone who cannot see the
    // tint, and the marker is also what `git diff` itself prints.
    final marker = switch (line.type) {
      GitDiffLineType.added => '+',
      GitDiffLineType.removed => '-',
      GitDiffLineType.meta => '',
      GitDiffLineType.hunkHeader => '',
      GitDiffLineType.context => ' ',
    };

    return Container(
      width: double.infinity,
      color: isAdded
          ? colors.done.withValues(alpha: GitDiffView._rowAlpha)
          : isRemoved
              ? colors.died.withValues(alpha: GitDiffView._rowAlpha)
              : null,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 10,
            child: Text(
              marker,
              style: base.copyWith(
                color: isAdded
                    ? colors.statusTextDone
                    : isRemoved
                        ? colors.statusTextDied
                        : colors.textFaint,
              ),
            ),
          ),
          Expanded(
            child: Text(line.text, style: base.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
