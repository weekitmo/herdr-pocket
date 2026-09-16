/// A unified diff, parsed so it can be RENDERED rather than printed.
///
/// The obvious shortcut is to run `git diff --color=always` and dump the ANSI
/// on screen. That is rejected on purpose: it makes colour a property of a
/// subprocess's output rather than of this app, so the diff would be styled for
/// a terminal that is not there, in hues that are not the design system's, and
/// on a light background it would be a wall of pink-on-white. Parsing the plain
/// diff costs one hunk scanner and buys the theme, the light mode, and the
/// monospace grid.
///
/// Pure Dart: no Flutter, no `Color`. The widget layer maps [GitDiffLineType]
/// onto the palette.
library;

enum GitDiffLineType {
  /// `@@ -1,4 +1,6 @@` — starts a hunk.
  hunkHeader,

  /// `+added`.
  added,

  /// `-removed`.
  removed,

  /// Unchanged, shown for context.
  context,

  /// `\ No newline at end of file`.
  meta,
}

/// One line of a unified diff.
class GitDiffLine {
  /// Renders one line. [oldLine] and [newLine] are the file line numbers this
  /// line corresponds to, or null on the side it does not exist on — that is
  /// what makes a real gutter possible instead of a running count.
  const GitDiffLine({
    required this.type,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final GitDiffLineType type;

  /// The line WITHOUT its leading `+`/`-`/space marker, so the renderer does not
  /// have to re-strip it and cannot get it wrong.
  final String text;

  final int? oldLine;
  final int? newLine;
}

/// One `@@` section.
class GitDiffHunk {
  /// Groups the lines under one hunk header. [header] is the raw `@@ … @@`
  /// line, including git's trailing function context when there is one.
  const GitDiffHunk({required this.header, required this.lines});

  final String header;
  final List<GitDiffLine> lines;
}

/// A parsed diff.
class GitDiff {
  const GitDiff._({required this.hunks, required this.isEmpty});

  /// An empty diff — nothing to compare, or nothing changed.
  const GitDiff.empty() : hunks = const [], isEmpty = true;

  /// Parses unified diff text.
  ///
  /// Tolerant by design. The input is a subprocess's stdout, and a reader that
  /// throws is worse than one that shows an unparsed line: a diff touching a
  /// file with a trailing `\ No newline at end of file` is normal, not an
  /// error.
  factory GitDiff.parse(String raw) {
    final hunks = <GitDiffHunk>[];
    // The trailing newline of the whole diff splits into one empty element;
    // counting it would add a phantom context line to every hunk, inflate the
    // line count and show a blank row at the end of the file.
    final text = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;
    var prelude = <String>[];
    var currentHeader = <String>[];
    var currentLines = <GitDiffLine>[];
    var oldLine = 0;
    var newLine = 0;

    void flush() {
      if (currentHeader.isEmpty && currentLines.isEmpty) return;
      hunks.add(
        GitDiffHunk(
          header: currentHeader.isEmpty ? '' : currentHeader.join('\n'),
          lines: List<GitDiffLine>.unmodifiable(currentLines),
        ),
      );
      currentHeader = <String>[];
      currentLines = <GitDiffLine>[];
    }

    // Line endings are left alone. git emits `\n`, but the CONTENT of a file
    // with CRLF endings carries its CR through, and stripping it would make the
    // diff disagree with the file it claims to describe. The single trailing
    // newline is removed above, because it would otherwise split into one empty
    // element and become a phantom context line at the end of every hunk.
    for (final line in text.split('\n')) {
      if (line.startsWith('@@')) {
        flush();
        // The preamble belongs to the hunk that follows it, so it is folded
        // into that hunk's header rather than kept as a separate record. "Which
        // file is this, and how did it change mode" is the first question
        // anyone asks of a diff, and it lives in these lines.
        currentHeader = [...prelude, line];
        prelude = <String>[];
        final counts = _hunkCounts(line);
        oldLine = counts.$1;
        newLine = counts.$2;
        continue;
      }

      if (line.startsWith(r'\')) {
        currentLines.add(GitDiffLine(type: GitDiffLineType.meta, text: line));
        continue;
      }

      if (prelude.isEmpty && currentHeader.isEmpty && line.isEmpty) {
        // The trailing newline of the whole diff.
        continue;
      }

      if (currentHeader.isEmpty) {
        // Still in the `diff --git` / `index` / `---` / `+++` preamble.
        prelude = [...prelude, line];
        continue;
      }

      if (line.startsWith('+')) {
        currentLines.add(
          GitDiffLine(
            type: GitDiffLineType.added,
            text: line.substring(1),
            newLine: newLine++,
          ),
        );
      } else if (line.startsWith('-')) {
        currentLines.add(
          GitDiffLine(
            type: GitDiffLineType.removed,
            text: line.substring(1),
            oldLine: oldLine++,
          ),
        );
      } else if (line.startsWith(' ') || line.isEmpty) {
        currentLines.add(
          GitDiffLine(
            type: GitDiffLineType.context,
            // An empty line inside a hunk is a context line whose marker space
            // was trimmed somewhere in the toolchain; treating it as context
            // keeps the two line counts aligned rather than letting the gutter
            // drift by one for the rest of the file.
            text: line.isEmpty ? '' : line.substring(1),
            oldLine: oldLine++,
            newLine: newLine++,
          ),
        );
      } else {
        // A line inside a hunk that starts with something else. Shown verbatim
        // as context rather than dropped: a diff that omits a line is worse
        // than one that shows a line it cannot classify.
        currentLines.add(
          GitDiffLine(
            type: GitDiffLineType.context,
            text: line,
            oldLine: oldLine++,
            newLine: newLine++,
          ),
        );
      }
    }
    flush();

    return GitDiff._(
      hunks: List<GitDiffHunk>.unmodifiable(hunks),
      isEmpty: !text.split('\n').any((l) => l.startsWith('@@')),
    );
  }

  /// The hunks, in file order.
  final List<GitDiffHunk> hunks;

  /// True when there was nothing to show — an empty diff, or a diff with no
  /// hunks at all (a mode-only change looks like this).
  final bool isEmpty;

  /// Added lines across every hunk.
  int get addedCount => hunks
      .expand((h) => h.lines)
      .where((l) => l.type == GitDiffLineType.added)
      .length;

  /// Removed lines across every hunk.
  int get removedCount => hunks
      .expand((h) => h.lines)
      .where((l) => l.type == GitDiffLineType.removed)
      .length;

  /// `@@ -oldStart[,oldCount] +newStart[,newCount] @@`
  ///
  /// Returns the first line number of each side. A missing count means one line,
  /// which is what `@@ -1 +1 @@` does.
  static (int, int) _hunkCounts(String header) {
    final match = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
        .firstMatch(header);
    if (match == null) return (0, 0);
    return (
      int.tryParse(match.group(1)!) ?? 0,
      int.tryParse(match.group(2)!) ?? 0,
    );
  }
}
