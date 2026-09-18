/// Syntax highlighting for fenced code blocks in a Markdown preview.
///
/// The grammars are highlight.js's, ported to Dart by the `highlight` package
/// and used here through its CORE entry point rather than its default one: the
/// default registers all 190 grammars at import time, and a phone that reads a
/// README does not need a Verilog tokenizer in its APK. The curated list below
/// is the languages a repository's README actually fences; anything else
/// renders as plain monospace text, which is what a wrong guess would look like
/// anyway.
library;

import 'package:flutter/widgets.dart';
import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/cs.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/diff.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/makefile.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

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

/// The grammars this app can colour.
///
/// Curated, tiny, and registered once at first use. `registerLanguage` also
/// registers each mode's own aliases, so ` ```sh `, ` ```yml ` and ` ```py `
/// resolve without a second table — the alias list is the grammar's own.
final Map<String, Mode> _languages = {
  'bash': bash,
  'cpp': cpp,
  'cs': cs,
  'css': css,
  'dart': dart,
  'diff': diff,
  'dockerfile': dockerfile,
  'go': go,
  'ini': ini,
  'java': java,
  'javascript': javascript,
  'json': json,
  'kotlin': kotlin,
  'makefile': makefile,
  'markdown': markdown,
  'php': php,
  'python': python,
  'ruby': ruby,
  'rust': rust,
  'sql': sql,
  'swift': swift,
  'typescript': typescript,
  'xml': xml,
  'yaml': yaml,
};

/// The parser, built once.
final Highlight _highlighter = () {
  final highlighter = Highlight();
  _languages.forEach(highlighter.registerLanguage);
  return highlighter;
}();

/// Every name a fence may spell, mapped to the grammar's canonical name.
///
/// Both halves, lower-cased: `bash` → `bash`, but also `sh` → `bash`, `py` →
/// `python` and `yml` → `yaml`. The aliases are the GRAMMAR's own, so a fence
/// written in any of them colours without a second table — and mapping them to
/// the canonical name is what lets the block's label say `bash` for a fence that
/// said `sh`, which is the difference between a label and a copy of the input.
final Map<String, String> _canonicalNames = () {
  final names = <String, String>{};
  _languages.forEach((name, mode) {
    names[name.toLowerCase()] = name;
    for (final alias in mode.aliases ?? const <String>[]) {
      names[alias.toLowerCase()] = name;
    }
  });
  return names;
}();

/// The language id a fence's info string names, in canonical form, or null.
///
/// Markdown hands the info string through as written, and every project spells
/// it its own way: `dart`, `Dart`, `language-dart`, `lang-dart`, `dart linenums`.
/// Only the FIRST token is a language — the rest is options for other renderers
/// (`linenums`, `title=…`) — and the `language-` prefix is a class name from
/// the HTML world that leaks into fences because that is what a highlighter on
/// the web consumes.
///
/// This is the SPELLING normaliser: `mermaid` comes back as `mermaid` even
/// though no grammar is registered for it, because the caller that wants to
/// know whether a fence means "draw me" is not the caller that wants to know
/// whether a grammar exists. See [highlightLanguageId] for the second question.
String? languageId(String? info) {
  if (info == null) return null;
  final first = info.trim().split(RegExp(r'\s+')).first;
  if (first.isEmpty) return null;
  var id = first.toLowerCase();
  if (id.startsWith('language-')) id = id.substring('language-'.length);
  if (id.startsWith('lang-')) id = id.substring('lang-'.length);
  return id.isEmpty ? null : id;
}

/// The id of the grammar this fence names, or null when it names none we
/// colour.
String? highlightLanguageId(String? info) {
  final id = languageId(info);
  return id == null ? null : _canonicalNames[id];
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
  final id = highlightLanguageId(info);
  if (id == null) return [TextSpan(text: source, style: base)];

  final nodes = _highlighter.parse(source, language: id).nodes;
  if (nodes == null || nodes.isEmpty) return [TextSpan(text: source, style: base)];

  final spans = <InlineSpan>[];
  _walk(nodes, base, palette, spans);
  return spans;
}

void _walk(
  List<Node> nodes,
  TextStyle current,
  CodePalette palette,
  List<InlineSpan> out,
) {
  for (final node in nodes) {
    final style = _styleFor(node, current, palette);
    if (node.value != null && node.value!.isNotEmpty) {
      out.add(TextSpan(text: node.value, style: style));
    } else if (node.children != null) {
      _walk(node.children!, style, palette, out);
    }
  }
}

/// The style for one node.
///
/// A class name can carry SEVERAL classes — highlight.js emits `title
/// function_` for a call, and `title class_` for a type — so the first name
/// this table knows wins, and a name built by suffixing an underscore is
/// stripped first. A node with no class inherits whatever the enclosing token
/// established; that is what makes a nested `string` inside a `meta` keep the
/// string colour.
TextStyle _styleFor(Node node, TextStyle inherited, CodePalette palette) {
  final className = node.className;
  if (className == null || className.isEmpty) return inherited;

  var style = inherited;
  for (final name in className.split(' ')) {
    final role = _roleFor(name);
    if (role == null) continue;
    style = _applyRole(role, style, palette);
    break;
  }
  return style;
}

/// The colour and weight a role paints with.
TextStyle _applyRole(_CodeRole role, TextStyle style, CodePalette palette) =>
    switch (role) {
      _CodeRole.keyword => style.copyWith(color: palette.keyword),
      _CodeRole.string => style.copyWith(color: palette.string),
      _CodeRole.number => style.copyWith(color: palette.number),
      _CodeRole.comment => style.copyWith(
        color: palette.comment,
        fontStyle: FontStyle.italic,
      ),
      _CodeRole.function => style.copyWith(color: palette.function),
      _CodeRole.type => style.copyWith(color: palette.type),
      _CodeRole.attribute => style.copyWith(color: palette.attribute),
      _CodeRole.punctuation => style.copyWith(color: palette.punctuation),
      _CodeRole.inserted => style.copyWith(color: palette.inserted),
      _CodeRole.deleted => style.copyWith(color: palette.deleted),
      _CodeRole.strong => style.copyWith(fontWeight: FontWeight.w600),
      _CodeRole.emphasis => style.copyWith(fontStyle: FontStyle.italic),
    };

/// The roles the palette paints.
enum _CodeRole {
  keyword,
  string,
  number,
  comment,
  function,
  type,
  attribute,
  punctuation,
  inserted,
  deleted,
  strong,
  emphasis,
}

/// Which class names map to which role.
///
/// The list was taken from what the port actually emits, measured by running
/// every curated grammar over a representative snippet and collecting the class
/// names, rather than from highlight.js's documentation — the two differ, and
/// an unmapped class silently renders as plain text.
_CodeRole? _roleFor(String className) {
  // highlight.js suffixes some classes with `_` in the Dart port (`title
  // function_` arrives as `function_` in some grammars).
  final name = className.endsWith('_')
      ? className.substring(0, className.length - 1)
      : className;

  return switch (name) {
    'keyword' ||
    'selector-tag' ||
    'meta' ||
    'meta-keyword' ||
    'doctag' ||
    'section' => _CodeRole.keyword,
    'string' ||
    'char' ||
    'regexp' ||
    'symbol' ||
    'link' ||
    'code' ||
    'meta-string' ||
    'subst' => _CodeRole.string,
    'number' || 'literal' => _CodeRole.number,
    'comment' || 'quote' => _CodeRole.comment,
    'title' || 'function' => _CodeRole.function,
    'type' || 'class' || 'built_in' => _CodeRole.type,
    'attr' ||
    'attribute' ||
    'variable' ||
    'template-variable' ||
    'params' ||
    'property' ||
    'name' ||
    'tag' ||
    'selector-id' ||
    'selector-class' ||
    'selector-attr' ||
    'bullet' => _CodeRole.attribute,
    'punctuation' || 'operator' => _CodeRole.punctuation,
    'addition' => _CodeRole.inserted,
    'deletion' => _CodeRole.deleted,
    'strong' => _CodeRole.strong,
    'emphasis' => _CodeRole.emphasis,
    _ => null,
  };
}
