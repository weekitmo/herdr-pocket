import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';

/// Every colour a rendered Markdown document uses, in one object.
///
/// Gathered here rather than read from [HerdrTheme] at each widget because the
/// document needs a few colours the app's chrome does not have a name for — the
/// surface an inline `code` run sits on, the head of a table — and because
/// deciding them one widget at a time is how a preview ends up with three
/// slightly different greys. [HerdrColors] remains the source of every value;
/// this type only says which token means what in a document.
class MarkdownPalette {
  /// Holds the app's colours and the code palette derived from them.
  const MarkdownPalette({required this.colors, required this.code});

  /// The palette for the current theme.
  factory MarkdownPalette.of(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return MarkdownPalette(
      colors: colors,
      code: CodePalette.of(colors.brightness),
    );
  }

  /// The app's own tokens.
  final HerdrColors colors;

  /// Token colours for fenced code and inline `code`.
  final CodePalette code;

  /// Body text.
  Color get ink => colors.text;

  /// Supporting text: table cells in a body row, quoted prose.
  Color get mutedInk => colors.textDim;

  /// The hairline under an `h1`/`h2`, and the bar beside a blockquote.
  Color get rule => colors.hairline;

  /// The rule between table rows — the quiet one, so a table reads as a table
  /// rather than as a grid of boxes.
  Color get tableRule => colors.hairlineQuiet;

  /// The head of a table, and the surface a code block sits on.
  ///
  /// One step up from the page's ground, which is the same move the app's cards
  /// make: content that belongs to a different thing sits on a different
  /// surface rather than behind a border.
  Color get surface => colors.surfaceRaised;

  /// Inline `code` — the same surface, which is what makes a command inside a
  /// sentence read as machine text without changing the font.
  Color get codeBackground => colors.surfaceRaised;

  /// Inline `code`'s ink. The app's normal text colour, so a document never
  /// looks like it has a syntax highlight inside a sentence.
  Color get codeInk => colors.text;

  /// A link.
  Color get link => colors.accent;

  /// The background of the image placeholder chip.
  Color get chipBackground => colors.surfaceRaised;

  /// The chip's ink and glyph.
  Color get chipInk => colors.textFaint;

  /// The horizontal rule under a `---`, and under a heading.
  Color get hairline => colors.hairlineQuiet;
}
