/// Git's answer, reduced to the one glyph a file-listing row has room for.
///
/// The file browser lists a directory at a time (see `FileTreePage`), so the
/// question this answers is always the same: "for THIS child of THAT
/// directory, what should the row say?" — a letter for a file, a dot for a
/// directory that contains changes anywhere below it.
///
/// Pure Dart on purpose: the matching is where the bugs live (a directory named
/// `foo` must not light up because `foobar/x.txt` changed), and it should be
/// testable without a widget or a shell.
library;

import 'package:herdr_pocket/domain/git/git_status.dart';

/// What one row shows.
class GitTreeMark {
  /// Holds one mark. [letter] is null for a directory, which is drawn as a dot:
  /// a directory is not `M` or `A`, it only CONTAINS changes.
  const GitTreeMark({required this.kind, this.letter});

  /// What the change means, which is what the colour is chosen from.
  final GitChangeKind kind;

  /// The glyph, in git's own alphabet — `M`, `A`, `D`, `R`, `?`, `U`, or a
  /// letter this build does not recognise, carried verbatim rather than mapped
  /// onto something it is not (the same rule the status list follows).
  final String? letter;

  @override
  String toString() =>
      'GitTreeMark(${kind.name}${letter == null ? '' : ' $letter'})';
}

/// The set of marks for one repository, looked up by directory and name.
///
/// Built once per status read, because the alternative — scanning every entry
/// for every row — is O(rows × entries) on a phone, and a repository with a few
/// thousand untracked files is exactly when the browser is slowest already.
class GitTreeMarks {
  GitTreeMarks._(this._root, this._files, this._directories);

  /// No repository, no runner, or a failed read. Every lookup answers null,
  /// which is what "no highlight" has to look like.
  GitTreeMarks.empty()
      : _root = '',
        _files = const {},
        _directories = const {};

  /// Folds one status into the maps the lookups read.
  ///
  /// Both the new path and a rename's ORIGINAL path mark their directories:
  /// moving `a/x.txt` to `b/x.txt` is a change inside both `a/` and `b/`, and a
  /// tree that only lit up `b/` would tell the reader nothing moved out of `a/`.
  factory GitTreeMarks.forStatus({
    required String root,
    required List<GitEntry> entries,
  }) {
    final files = <String, GitTreeMark>{};
    final directories = <String, GitTreeMark>{};

    for (final entry in entries) {
      if (entry.isIgnored) continue;
      final mark = _markFor(entry);
      if (mark == null) continue;

      // A path git prints twice (the same file staged AND modified) keeps the
      // stronger of the two marks; the last write would otherwise win by
      // accident of the porcelain order.
      files[entry.path] = _stronger(files[entry.path], mark);

      for (final path in [
        entry.path,
        if (entry.originalPath != null) entry.originalPath!,
      ]) {
        // A directory is drawn as a dot, never a letter: the letter belongs to
        // the file that changed, not to the folder it sits in.
        final directoryMark = GitTreeMark(kind: mark.kind);
        var parent = _parentOf(path);
        while (parent.isNotEmpty) {
          directories[parent] = _stronger(directories[parent], directoryMark);
          parent = _parentOf(parent);
        }
      }
    }

    return GitTreeMarks._(
      root,
      Map<String, GitTreeMark>.unmodifiable(files),
      Map<String, GitTreeMark>.unmodifiable(directories),
    );
  }

  final String _root;
  final Map<String, GitTreeMark> _files;
  final Map<String, GitTreeMark> _directories;

  /// The mark for one child of [absoluteDirectory], or null when it has none.
  ///
  /// [absoluteDirectory] need not be the repository root; when it is not inside
  /// the repository at all, every answer is null rather than a guess.
  GitTreeMark? markFor(
    String absoluteDirectory,
    String name, {
    required bool isDirectory,
  }) {
    final relative = _relativeTo(absoluteDirectory);
    if (relative == null) return null;
    final path = relative.isEmpty ? name : '$relative/$name';
    return isDirectory ? _directories[path] : _files[path];
  }

  /// The repository-relative path of a child, or null when outside the tree.
  ///
  /// The suffix test is against `root + '/'`, NOT against `root` alone: with a
  /// bare prefix check, browsing `/tmp/repo-other` inside `/tmp/repo` would
  /// produce paths relative to a root that is not its own, and every row would
  /// be matched against a path that does not exist.
  String? _relativeTo(String absoluteDirectory) {
    // The empty set has no root, and an empty root would make every absolute
    // path look like it starts with it.
    if (_root.isEmpty) return null;
    if (absoluteDirectory == _root) return '';
    final prefix = _root.endsWith('/') ? _root : '$_root/';
    if (!absoluteDirectory.startsWith(prefix)) return null;
    var relative = absoluteDirectory.substring(prefix.length);
    while (relative.endsWith('/')) {
      relative = relative.substring(0, relative.length - 1);
    }
    return relative;
  }

  /// One entry's mark, or null when the entry says nothing about a change.
  static GitTreeMark? _markFor(GitEntry entry) {
    final states = <GitState>[entry.index, entry.worktree];
    GitState? best;
    for (final state in states) {
      final kind = state.kind;
      if (kind == null || kind == GitChangeKind.ignored) continue;
      if (best == null || _rank(kind) < _rank(best.kind!)) best = state;
    }
    if (best == null) return null;
    return GitTreeMark(kind: best.kind!, letter: best.letter);
  }

  /// Keeps the more significant of two marks.
  static GitTreeMark _stronger(GitTreeMark? existing, GitTreeMark candidate) {
    if (existing == null) return candidate;
    return _rank(candidate.kind) < _rank(existing.kind) ? candidate : existing;
  }

  /// Which kind a row should lead with when a file has two states at once.
  ///
  /// One glyph has to stand for both halves of `AM`. The order is about what a
  /// reader would act on: a conflict is the only state that NEEDS them, a
  /// deletion means the file is gone, and "added" outranks "modified" because a
  /// new file that has also been edited is still, overall, new. An unrecognised
  /// letter is kept at the front on purpose — a status this build cannot read
  /// must not be quietly filed as an ordinary edit.
  static int _rank(GitChangeKind kind) => switch (kind) {
        GitChangeKind.unrecognised => 0,
        GitChangeKind.conflicted => 1,
        GitChangeKind.deleted => 2,
        GitChangeKind.added => 3,
        GitChangeKind.renamed => 4,
        GitChangeKind.copied => 5,
        GitChangeKind.typechange => 6,
        GitChangeKind.modified => 7,
        GitChangeKind.untracked => 8,
        GitChangeKind.ignored => 9,
      };

  /// `a/b/c` → `a/b`, and `a` → `''` (the repository root itself).
  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }
}
