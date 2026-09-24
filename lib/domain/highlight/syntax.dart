/// Syntax highlighting: which grammar a file gets, and what its tokens are.
///
/// Pure Dart, and that is a requirement rather than a preference. The file
/// preview computes the tokens for a whole file in one go, and does it off the
/// UI thread ([FilePreviewPage] hands this to an isolate) — so the result has to
/// be plain data: no `TextStyle`, no `Color`, nothing from Flutter. The layer
/// that knows what a token LOOKS like is `ui/markdown/code_highlighting.dart`,
/// which turns [CodeRun]s into spans with the app's measured palette.
///
/// The grammars are highlight.js's, ported to Dart by the `highlight` package
/// and used here through its CORE entry point rather than its default one: the
/// default registers all 190 grammars at import time, and a phone that reads a
/// README does not need a Verilog tokenizer in its APK. The list below is the
/// languages this project's own machines actually hold — a repository, a
/// Dockerfile, the usual suspects of a polyglot project — and anything else
/// renders as plain monospace text, which is what a wrong guess would look
/// like anyway.
library;

import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/clojure.dart';
import 'package:highlight/languages/cmake.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/cs.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/diff.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/elixir.dart';
import 'package:highlight/languages/erlang.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/gradle.dart';
import 'package:highlight/languages/graphql.dart';
import 'package:highlight/languages/groovy.dart';
import 'package:highlight/languages/haskell.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/julia.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/less.dart';
import 'package:highlight/languages/lua.dart';
import 'package:highlight/languages/makefile.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/nginx.dart';
import 'package:highlight/languages/objectivec.dart';
import 'package:highlight/languages/ocaml.dart';
import 'package:highlight/languages/perl.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/powershell.dart';
import 'package:highlight/languages/properties.dart';
import 'package:highlight/languages/protobuf.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/r.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/scala.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/vbnet.dart';
import 'package:highlight/languages/vim.dart';
import 'package:highlight/languages/vue.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

/// What a token IS, independent of any colour.
///
/// The same vocabulary the Markdown renderer uses for its fenced blocks: one
/// class of tokens must not be two colours depending on which screen it was
/// found on. The mapping from token to colour lives in `CodePalette`, which is
/// measured against both themes by `test/ui/code_palette_test.dart`.
enum CodeRole {
  /// Tokens with no class, and every class this app has no role for.
  plain,

  /// Control flow and structure: `if`, `return`, a markdown heading.
  keyword,

  /// String-ish literals, including a markdown link and inline code.
  string,

  /// Numeric and named constants (`true`, `null`, YAML `yes`).
  number,

  /// Comments and quoted text — faded rather than coloured.
  comment,

  /// Function and method names.
  function,

  /// Types, classes and built-ins.
  type,

  /// Keys, attributes, parameters, variables.
  attribute,

  /// Punctuation and operators, at the dimmest legible step.
  punctuation,

  /// An added line in a diff.
  inserted,

  /// A removed line in a diff.
  deleted,
}

/// One run of characters that share a role.
///
/// A flat run list rather than a tree: the highlight.js node tree mirrors the
/// grammar's own nesting, and nothing down here needs it — a nested node that
/// adds no class produces the same pixels as its parent. Flattening also makes
/// the result [sendable to an isolate], which is what lets a large file be
/// tokenised without blocking a frame.
///
/// [sendable to an isolate]: https://api.dart.dev/stable/dart-isolate/Isolate-class.html
class CodeRun {
  /// Holds one run's text and what it is.
  const CodeRun(
    this.text, {
    this.role = CodeRole.plain,
    this.italic = false,
    this.bold = false,
  });

  /// The characters, verbatim. A run may contain newlines.
  final String text;

  /// Which palette role paints it.
  final CodeRole role;

  /// Whether the enclosing token was a comment or an emphasis.
  ///
  /// Carried alongside the role rather than folded into it because the two
  /// compose: a `@param` inside a doc comment is a keyword, and it is still
  /// italic — the class that made the enclosing comment italic is not undone by
  /// the child that only supplies a colour.
  final bool italic;

  /// Whether the enclosing token was a `strong`.
  final bool bold;

  /// The same run with different text, used when a run is split across lines.
  CodeRun withText(String text) =>
      CodeRun(text, role: role, italic: italic, bold: bold);

  @override
  bool operator ==(Object other) =>
      other is CodeRun &&
      other.text == text &&
      other.role == role &&
      other.italic == italic &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(text, role, italic, bold);

  @override
  String toString() => 'CodeRun(${role.name}, ${text.length} chars)';
}

/// One line of a highlighted file: the runs it is made of.
///
/// Joined by nothing — the line separator is not part of any run, and a caller
/// that wants the text back has [plainText].
class CodeLine {
  /// Holds one line's runs.
  const CodeLine(this.runs);

  /// The runs, in order. Empty for a blank line.
  final List<CodeRun> runs;

  /// The line as text, for tests and for anything that does not paint.
  String get plainText => runs.map((r) => r.text).join();

  @override
  String toString() => 'CodeLine(${runs.length} runs)';
}

/// The grammars this app can colour.
///
/// Curated, tiny, and registered once at first use. `registerLanguage` also
/// registers each mode's own aliases, so ` ```sh `, ` ```yml ` and ` ```py `
/// resolve without a second table — the alias list is the grammar's own.
final Map<String, Mode> _languages = {
  'bash': bash,
  'cmake': cmake,
  'clojure': clojure,
  'cpp': cpp,
  'cs': cs,
  'css': css,
  'dart': dart,
  'diff': diff,
  'dockerfile': dockerfile,
  'elixir': elixir,
  'erlang': erlang,
  'go': go,
  'gradle': gradle,
  'graphql': graphql,
  'groovy': groovy,
  'haskell': haskell,
  'ini': ini,
  'java': java,
  'javascript': javascript,
  'json': json,
  'julia': julia,
  'kotlin': kotlin,
  'less': less,
  'lua': lua,
  'makefile': makefile,
  'markdown': markdown,
  'nginx': nginx,
  'objectivec': objectivec,
  'ocaml': ocaml,
  'perl': perl,
  'php': php,
  'powershell': powershell,
  'properties': properties,
  'protobuf': protobuf,
  'python': python,
  'r': r,
  'ruby': ruby,
  'rust': rust,
  'scala': scala,
  'scss': scss,
  'sql': sql,
  'swift': swift,
  'typescript': typescript,
  'vbnet': vbnet,
  'vim': vim,
  'vue': vue,
  'xml': xml,
  'yaml': yaml,
};

/// Every grammar name this app knows, sorted. Used by tests as the contract.
List<String> get registeredLanguages => _languages.keys.toList()..sort();

/// The parser, built once.
final Highlight _highlighter = () {
  final highlighter = Highlight();
  _languages.forEach(highlighter.registerLanguage);
  return highlighter;
}();

/// Every name a fence or a file extension may spell, mapped to the grammar's
/// canonical name.
///
/// Both halves, lower-cased: `bash` → `bash`, but also `sh` → `bash`, `py` →
/// `python` and `yml` → `yaml`. The aliases are the GRAMMAR's own, so any of
/// them colours without a second table — and mapping them to the canonical name
/// is what lets a label say `bash` for input that said `sh`, which is the
/// difference between a label and a copy of the input.
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

/// The id of the grammar a fence or a file names, or null when it names none
/// this app colours.
String? highlightLanguageId(String? info) {
  final id = languageId(info);
  return id == null ? null : _canonicalNames[id];
}

/// Whether [languageId] resolves to a grammar this app registered.
bool hasGrammar(String? languageId) => highlightLanguageId(languageId) != null;

/// The runs of one source text, in order, as a FLAT list.
///
/// Returns a single plain run when [languageId] names no grammar this app has,
/// and also when the grammar itself gives up. A file preview that throws is
/// worse than a file preview with no colours: the reader still wants to read the
/// file.
List<CodeRun> highlightRuns(String source, String? languageId) {
  final id = highlightLanguageId(languageId);
  if (id == null) return [CodeRun(source)];
  if (source.isEmpty) return const [];

  final List<Node>? nodes;
  try {
    nodes = _highlighter.parse(source, language: id).nodes;
  } on Object {
    // The port throws on a handful of malformed inputs. The grammar failed, the
    // text did not — so the text is what is shown.
    return [CodeRun(source)];
  }
  if (nodes == null || nodes.isEmpty) return [CodeRun(source)];

  final runs = <CodeRun>[];
  _walk(nodes, const CodeRun(''), runs);
  return runs.isEmpty ? [CodeRun(source)] : runs;
}

/// The same, split into lines — which is how the file preview paints it.
///
/// Splitting happens HERE rather than in the widget because a multi-line token
/// (a block comment, a triple-quoted string) has to stay one token: a per-line
/// call to the grammar would start each line in a fresh state and the second
/// line of a block comment would come back as code. Tokenising the file as a
/// whole and then cutting at the newlines is the only order that gets both
/// right.
///
/// The line splitting rule is [splitSourceLines]'s, shared with the caller, so
/// the lines of text and the lines of runs cannot disagree about how many lines
/// there are — a gutter that numbers one line more than the file has is exactly
/// the kind of drift this avoids.
List<CodeLine> highlightLines(String source, String? languageId) {
  final lines = splitSourceLines(source);
  if (lines.isEmpty) return const [];

  final runs = highlightRuns(source, languageId);
  final out = <List<CodeRun>>[];
  var line = <CodeRun>[];

  for (final run in runs) {
    var text = run.text;
    while (true) {
      final newline = text.indexOf('\n');
      if (newline < 0) {
        if (text.isNotEmpty) line.add(run.withText(text));
        break;
      }
      if (newline > 0) line.add(run.withText(text.substring(0, newline)));
      out.add(line);
      line = <CodeRun>[];
      text = text.substring(newline + 1);
    }
  }
  out.add(line);

  // The run list ends with a newline exactly when the source does, so it can
  // produce one line too many. Dropped rather than numbered: it is a line that
  // does not exist in the file. The counts are then forced to agree, because a
  // mismatch here would be a gutter misaligned with its text, and refusing to
  // show the file would be a worse answer than showing it plainly.
  while (out.length > lines.length) {
    if (out.last.isEmpty) {
      out.removeLast();
    } else {
      break;
    }
  }
  while (out.length < lines.length) {
    out.add(const []);
  }

  return [for (final runs in out) CodeLine(List.unmodifiable(runs))];
}

/// A text's lines, with the trailing empty line a final newline produces
/// removed.
///
/// The one place this project decides what a "line" is, so the code view's
/// gutter and [highlightLines] can never number a different set of lines.
List<String> splitSourceLines(String source) {
  final lines = source.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Walk the node tree, flattening it into runs and folding the classes in.
void _walk(List<Node> nodes, CodeRun current, List<CodeRun> out) {
  for (final node in nodes) {
    final style = _styleFor(node, current);
    final value = node.value;
    if (value != null && value.isNotEmpty) {
      _append(out, style.withText(value));
    } else if (node.children != null) {
      _walk(node.children!, style, out);
    }
  }
}

/// The style one node imposes on its subtree.
///
/// A class name can carry SEVERAL classes — highlight.js emits `title
/// function_` for a call, and `title class_` for a type — so the first name
/// this table knows wins, and a name built by suffixing an underscore is
/// stripped first. A node with no class keeps whatever the enclosing token
/// established; that is what makes a nested `string` inside a `meta` keep the
/// string colour.
CodeRun _styleFor(Node node, CodeRun inherited) {
  final className = node.className;
  if (className == null || className.isEmpty) return inherited;

  var style = inherited;
  for (final name in className.split(' ')) {
    final effect = _effectFor(name);
    if (effect == null) continue;
    style = CodeRun(
      '',
      role: effect.role ?? style.role,
      italic: style.italic || effect.italic,
      bold: style.bold || effect.bold,
    );
  }
  return style;
}

/// What one class name does.
///
/// The list was taken from what the port actually emits, measured by running
/// every curated grammar over a representative snippet and collecting the class
/// names, rather than from highlight.js's documentation — the two differ, and an
/// unmapped class silently renders as plain text.
_ClassEffect? _effectFor(String className) {
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
    'section' => const _ClassEffect(CodeRole.keyword),
    'string' ||
    'char' ||
    'regexp' ||
    'symbol' ||
    'link' ||
    'code' ||
    'meta-string' ||
    'subst' => const _ClassEffect(CodeRole.string),
    'number' || 'literal' => const _ClassEffect(CodeRole.number),
    'comment' || 'quote' => const _ClassEffect(CodeRole.comment, italic: true),
    'title' || 'function' => const _ClassEffect(CodeRole.function),
    'type' || 'class' || 'built_in' => const _ClassEffect(CodeRole.type),
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
    'bullet' => const _ClassEffect(CodeRole.attribute),
    'punctuation' || 'operator' => const _ClassEffect(CodeRole.punctuation),
    'addition' => const _ClassEffect(CodeRole.inserted),
    'deletion' => const _ClassEffect(CodeRole.deleted),
    'strong' => const _ClassEffect(null, bold: true),
    'emphasis' => const _ClassEffect(null, italic: true),
    _ => null,
  };
}

/// One class name's contribution: a colour role, emphasis, or both.
class _ClassEffect {
  const _ClassEffect(this.role, {this.italic = false, this.bold = false});

  /// Null when the class only adds emphasis and keeps the enclosing colour.
  final CodeRole? role;
  final bool italic;
  final bool bold;
}

/// Adds [run], merging it into the previous one when nothing about it changed.
///
/// Merging is not cosmetic: it is what keeps a run from being split once per
/// parse node, which matters because the run list is what crosses the isolate
/// boundary.
void _append(List<CodeRun> out, CodeRun run) {
  if (out.isNotEmpty) {
    final last = out.last;
    if (last.role == run.role &&
        last.italic == run.italic &&
        last.bold == run.bold) {
      out[out.length - 1] = last.withText(last.text + run.text);
      return;
    }
  }
  out.add(run);
}
