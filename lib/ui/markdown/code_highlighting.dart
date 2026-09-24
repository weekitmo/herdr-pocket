/// The COLOURS of syntax highlighting, and the bridge from tokens to spans.
///
/// The tokens themselves — which grammar a name gets, and what role each of its
/// classes plays — are computed in `lib/domain/highlight/syntax.dart`, because
/// the file preview tokenises whole files off the UI thread and has to carry the
/// result in a form that knows nothing about Flutter. This file is the other
/// half of that seam: the only place that decides what a `keyword` or a
/// `comment` LOOKS like.
///
/// Both the Markdown renderer and the source-file viewer go through
/// [highlightedSpans], so one token cannot be two colours depending on which
/// screen it was found on.
library;

import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/domain/highlight/syntax.dart';

// Re-exported so this file stays the one place the rest of the UI imports:
// `languageId` and `highlightLanguageId` are asked by the Markdown renderer
// (does this fence mean "draw me a diagram"?) and by the file preview (which
// grammar does this name get?), and both of them mean the same thing.
export 'package:herdr_pocket/domain/highlight/syntax.dart';

/// The colours one code block uses, by token role.
///
/// ## Why this palette may use hues the app's own palette reserves
///
/// `tokens.dart`'s rule — colour is MEANING, the four status hues are the only
/// colour in the product — is a rule about the app's CHROME. A fenced code
/// block is not chrome: it is machine content, the same kind of thing the
/// terminal already renders with a full 16-colour palette behind it, and a
/// syntax highlighter that renders every token in one ink is a wall of text
/// rather than a preview. What the rule does forbid is a status hue being read
/// AS a status, and none of these is: they never leave the code block's
/// surface, and nothing in the block is a status.
///
/// These are NOT the terminal theme's colours, deliberately. Highlight.js
/// classifies tokens (`keyword`, `string`, `comment`), the terminal has no idea
/// what a token is, and borrowing its palette would make one token's colour
/// depend on which terminal theme the user picked — a README that changes
/// colour when the theme changes is a preview that cannot be trusted.
///
/// EVERY VALUE IS MEASURED, and the measurements are enforced by
/// `test/ui/code_palette_test.dart`: each role clears 4.5:1 against the code
/// block's own surface, in both brightnesses. Tuning these by eye is how one
/// comment colour ends up at 3.1:1 — legible on a laptop, invisible in
/// sunlight.
class CodePalette {
  /// Holds one brightness's roles.
  const CodePalette({
    required this.plain,
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.function,
    required this.type,
    required this.attribute,
    required this.punctuation,
    required this.inserted,
    required this.deleted,
  });

  /// Tokens with no class, and anything this palette has no role for.
  final Color plain;

  /// Control flow and structure: `if`, `return`, a markdown heading.
  final Color keyword;

  /// String-ish literals, including a markdown link and inline code.
  final Color string;

  /// Numeric and named constants (`true`, `null`, YAML `yes`).
  final Color number;

  /// Comments and quoted text — faded rather than coloured.
  final Color comment;

  /// Function and method names.
  final Color function;

  /// Types, classes and built-ins.
  final Color type;

  /// Keys, attributes, parameters, variables.
  final Color attribute;

  /// Punctuation and operators, at the dimmest legible step.
  final Color punctuation;

  /// An added line in a diff.
  final Color inserted;

  /// A removed line in a diff.
  final Color deleted;

  /// The roles for one brightness.
  static CodePalette of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static const _dark = CodePalette(
    // The code block's own surface is `surfaceRaised` (#262A45 dark). Ratios
    // against it, measured: 11.5, 5.8, 8.0, 7.7, 4.6, 6.5, 8.0, 8.1, 4.7, 7.2, 4.8.
    plain: Color(0xFFEEF0F7),
    keyword: Color(0xFFC792EA),
    string: Color(0xFF8FD3A5),
    number: Color(0xFFE9B86C),
    comment: Color(0xFF8A92B2),
    function: Color(0xFF7FB4F0),
    type: Color(0xFF6FD3D3),
    attribute: Color(0xFFE5C07B),
    punctuation: Color(0xFF9BA3C4),
    inserted: Color(0xFF7FC99B),
    deleted: Color(0xFFF0705F),
  );

  static const _light = CodePalette(
    // Against the light code surface (#E8EAF4): 13.6, 4.8, 5.0, 5.0, 4.7,
    // 4.8, 5.0, 4.9, 5.2, 5.0, 5.4. The two tightest are the keyword and the
    // green: both were darkened once after the first measurement, which is
    // exactly why the numbers are asserted rather than eyeballed.
    plain: Color(0xFF171A2E),
    keyword: Color(0xFF7C3AED),
    string: Color(0xFF2A7047),
    number: Color(0xFF955200),
    comment: Color(0xFF5F6780),
    function: Color(0xFF2568AE),
    type: Color(0xFF0E6E7A),
    attribute: Color(0xFF8A5A00),
    punctuation: Color(0xFF4A5069),
    inserted: Color(0xFF23754A),
    deleted: Color(0xFFB02B23),
  );
}

/// The spans for one fenced block, or a single plain span when the language is
/// unknown.
///
/// [base] carries the font and size; the roles supply colour only, so a code
/// block can never re-introduce a font the app does not use.
List<InlineSpan> highlightedSpans(
  String source,
  String? info, {
  required TextStyle base,
  required CodePalette palette,
}) {
  final runs = highlightRuns(source, info);
  return [for (final run in runs) TextSpan(text: run.text, style: codeStyle(run, base, palette))];
}

/// One token's text style: the base (font, size, family) plus its role's ink.
///
/// Emphasis comes from the RUN rather than from its role, because the two
/// compose: a `@param` inside a doc comment is a keyword in an italic comment,
/// and a role-only mapping would drop the italic on the way in.
TextStyle codeStyle(CodeRun run, TextStyle base, CodePalette palette) =>
    base.copyWith(
      color: codeInk(run.role, palette),
      fontStyle: run.italic ? FontStyle.italic : null,
      fontWeight: run.bold ? FontWeight.w600 : null,
    );

/// The ink for one role, in one theme.
Color codeInk(CodeRole role, CodePalette palette) => switch (role) {
      CodeRole.plain => palette.plain,
      CodeRole.keyword => palette.keyword,
      CodeRole.string => palette.string,
      CodeRole.number => palette.number,
      CodeRole.comment => palette.comment,
      CodeRole.function => palette.function,
      CodeRole.type => palette.type,
      CodeRole.attribute => palette.attribute,
      CodeRole.punctuation => palette.punctuation,
      CodeRole.inserted => palette.inserted,
      CodeRole.deleted => palette.deleted,
    };
