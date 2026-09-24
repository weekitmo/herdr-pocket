/// Which grammar a FILE NAME gets.
///
/// Markdown fences carry their language explicitly (` ```python `); a file on a
/// disk does not, so it has to be inferred from its name. This is that
/// inference, and it is pure data on purpose: it can be wrong, and a wrong guess
/// is the kind of bug a screenshot looks fine in — `main.m` is MATLAB or
/// Objective-C, and no amount of staring at colours settles which one the
/// user's repository holds.
///
/// Two rules follow from that, and both are load-bearing:
///
/// 1. **An unknown name gets no grammar.** The file still opens, as plain
///    monospace text. Guessing (say, `cpp` for anything with a `.h`) would put
///    confidently wrong colours on a file, which is worse than no colours.
/// 2. **The values here must be registered grammars**, and a test asserts it by
///    resolving every one of them through [hasGrammar] — a typo in this table
///    would otherwise show up as "that one file type is never coloured", which
///    nobody would ever report.
///
/// Deliberately absent, each for a reason: `.m` (MATLAB or Objective-C), `.h`
/// (C, C++ or Objective-C), `.pl` is present but `.t` is not (Perl tests vs
/// TypeScript definitions), `.tf`/`.hcl` and `.nix` (no registered grammar),
/// `.csv` (no highlighting to do), `.mdx` (see `isMarkdownName`).
library;

import 'package:herdr_pocket/domain/files/file_kind.dart';

/// The grammar id for [name], or null when this app has no business colouring
/// it.
///
/// Ordered: a whole name beats a pattern, a pattern beats an extension. That
/// order is what lets `Dockerfile.dev` be a Dockerfile while `.dev` is not a
/// language, and `nginx.conf` be Nginx while every other `.conf` is INI.
String? sourceLanguageFor(String name) {
  final lower = name.toLowerCase();

  // The whole name, with a leading dot tried as well: `.vimrc` is a vimrc. The
  // table below spells the dotless form, because that is what the filename is
  // ABOUT — the dot is a convention, not part of the language's name.
  final byName = _byWholeName[lower] ??
      (lower.startsWith('.') ? _byWholeName[lower.substring(1)] : null);
  if (byName != null) return byName;

  for (final pattern in _byNamePattern) {
    if (pattern.matches(lower)) return pattern.language;
  }

  final extension = extensionOf(name);
  return extension == null ? null : _byExtension[extension];
}

/// One "this name means this language" rule for names that are not extensions.
class _NamePattern {
  /// Holds one rule.
  const _NamePattern(this.language, {this.prefix, this.suffix});

  /// The grammar id it yields.
  final String language;

  /// The name starts with this, followed by the end of the string or a dot.
  ///
  /// `Dockerfile`, `Dockerfile.dev`, `Dockerfile.prod` — but NOT `DockerfileX`.
  final String? prefix;

  /// The name ends with this, preceded by the start of the string or a dot.
  ///
  /// `dev.Dockerfile` and `Dockerfile` — but not `NotADockerfile`.
  final String? suffix;

  /// Whether [name] (already lowercased) is this rule's.
  bool matches(String name) {
    final prefix = this.prefix;
    if (prefix != null) {
      if (name == prefix) return true;
      if (name.startsWith('$prefix.')) return true;
    }
    final suffix = this.suffix;
    if (suffix != null) {
      if (name == suffix) return true;
      if (name.endsWith('.$suffix')) return true;
    }
    return false;
  }
}

/// Names that are a language in their own right, extensions be damned.
///
/// The lowercased WHOLE name, so `Makefile` and `makefile` agree. A project
/// tool's conventional filename is a stronger signal than its extension —
/// `Gemfile` has none at all, and `Vagrantfile` is Ruby that never says so.
const _byWholeName = <String, String>{
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
  'gnumakefile': 'makefile',
  'cmakelists.txt': 'cmake',
  'gemfile': 'ruby',
  'rakefile': 'ruby',
  'guardfile': 'ruby',
  'podfile': 'ruby',
  'brewfile': 'ruby',
  'vagrantfile': 'ruby',
  'fastfile': 'ruby',
  'appfile': 'ruby',
  'berksfile': 'ruby',
  'puppetfile': 'ruby',
  'jenkinsfile': 'groovy',
  'nginx.conf': 'nginx',
  'bashrc': 'bash',
  'bash_profile': 'bash',
  'bash_aliases': 'bash',
  'bash_logout': 'bash',
  'zshrc': 'bash',
  'zprofile': 'bash',
  'zshenv': 'bash',
  'zlogin': 'bash',
  'profile': 'bash',
  'kshrc': 'bash',
  'vimrc': 'vim',
  'gvimrc': 'vim',
  'editorconfig': 'ini',
};

/// Names that carry the language in a prefix or a suffix.
///
/// `Dockerfile.dev` and `dev.Dockerfile` are the same kind of file; so are
/// `Makefile.am` and `Makefile.in`. The boundary is a dot or the end of the
/// name, which is what keeps `DockerfileX` out.
const _byNamePattern = <_NamePattern>[
  _NamePattern('dockerfile', prefix: 'dockerfile', suffix: 'dockerfile'),
  _NamePattern('makefile', prefix: 'makefile', suffix: 'makefile'),
  _NamePattern('bash', prefix: '.bash'),
  _NamePattern('bash', prefix: '.env'),
];

/// Extensions, and the grammar each one gets.
///
/// Every value must be a registered grammar (asserted by test). Where a name
/// could be two languages, this table either says the more common one for the
/// kind of repository this app is used in, or says nothing at all.
const _byExtension = <String, String>{
  // Dart and the Flutter stack.
  'dart': 'dart',

  // Scripting.
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'ksh': 'bash',
  'bats': 'bash',
  'env': 'bash',
  'py': 'python',
  'pyi': 'python',
  'pyw': 'python',
  'rb': 'ruby',
  'ru': 'ruby',
  'gemspec': 'ruby',
  'pl': 'perl',
  'pm': 'perl',
  'lua': 'lua',
  'ps1': 'powershell',
  'psm1': 'powershell',
  'psd1': 'powershell',
  'r': 'r',
  'rmd': 'r',
  'jl': 'julia',

  // Compiled languages.
  'go': 'go',
  'rs': 'rust',
  'c': 'cpp',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'hh': 'cpp',
  'hxx': 'cpp',
  'cs': 'cs',
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'scala': 'scala',
  'sbt': 'scala',
  'swift': 'swift',
  'mm': 'objectivec',
  'vb': 'vbnet',
  'hs': 'haskell',
  'lhs': 'haskell',
  'ml': 'ocaml',
  'mli': 'ocaml',
  'ex': 'elixir',
  'exs': 'elixir',
  'erl': 'erlang',
  'hrl': 'erlang',
  'clj': 'clojure',
  'cljs': 'clojure',
  'cljc': 'clojure',
  'edn': 'clojure',

  // The web.
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'json': 'json',
  'jsonc': 'json',
  'ipynb': 'json',
  'html': 'xml',
  'htm': 'xml',
  'xhtml': 'xml',
  'xml': 'xml',
  'plist': 'xml',
  'xsl': 'xml',
  'xslt': 'xml',
  'svg': 'xml',
  'css': 'css',
  'scss': 'scss',
  'less': 'less',
  'vue': 'vue',

  // Config and build.
  'yaml': 'yaml',
  'yml': 'yaml',
  'toml': 'ini',
  'ini': 'ini',
  'cfg': 'ini',
  'conf': 'ini',
  'service': 'ini',
  'properties': 'properties',
  'gradle': 'gradle',
  'groovy': 'groovy',
  'graphql': 'graphql',
  'gql': 'graphql',
  'proto': 'protobuf',

  // Data, docs, diffs.
  'sql': 'sql',
  'md': 'markdown',
  'markdown': 'markdown',
  'diff': 'diff',
  'patch': 'diff',
  'vim': 'vim',
};
