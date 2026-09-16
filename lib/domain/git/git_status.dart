/// `git status --porcelain=v2 --branch -z` as this client is willing to
/// interpret it.
///
/// Pure Dart on purpose: the parsing is where the bugs live, and the widget
/// layer should never be the only way to reach it.
///
/// The format was verified by running the command on this machine (git 2.53.0,
/// macOS) rather than from memory. Two properties matter and are easy to get
/// wrong:
///
///   * `-z` separates records with NUL, not newline. A path may contain a
///     newline; splitting on `\n` would silently turn one file into two.
///   * A RENAME record is TWO NUL-separated paths. Git emits the new path
///     first, then the original, and consuming only one shifts every following
///     record by a field — a bug that produces plausible-looking garbage.
///
/// See [GitStatus.parse] for the record grammar.
library;

/// What happened to one side of a file's status.
///
/// [unrecognised] is the important case. Git's porcelain status letters are an
/// open set — upstream has added to it before — and a client that maps an
/// unknown letter onto [modified] would report a file as changed when it was
/// added, deleted, or in some state that does not exist yet. That is the same
/// class of bug `AgentStatus` refuses to make: see the long comment in
/// `lib/domain/agent/agent_status.dart` about `default: idle`. The raw letter
/// is CARRIED here rather than discarded, so the UI can show it and a future
/// reader can diagnose it instead of guessing.
enum GitChangeKind {
  modified,
  added,
  deleted,
  renamed,
  copied,
  typechange,
  untracked,
  ignored,
  conflicted,

  /// A letter this build has never seen. Never collapse this into another
  /// case.
  unrecognised;

  /// Maps one porcelain status letter.
  ///
  /// `.` is git's "unchanged on this side" and is genuinely NOT a change, so it
  /// is distinguished from an unknown letter: it returns null, which callers
  /// read as "nothing here", not as "I could not tell".
  static GitChangeKind? fromLetter(String letter) => switch (letter) {
        'M' => GitChangeKind.modified,
        'A' => GitChangeKind.added,
        'D' => GitChangeKind.deleted,
        'R' => GitChangeKind.renamed,
        'C' => GitChangeKind.copied,
        'T' => GitChangeKind.typechange,
        '?' => GitChangeKind.untracked,
        '!' => GitChangeKind.ignored,
        'U' => GitChangeKind.conflicted,
        '.' => null,
        _ => GitChangeKind.unrecognised,
      };
}

/// One side of a change: the raw letter, and what we make of it.
class GitState {
  /// Builds a state from a single porcelain letter.
  GitState(this.letter) : _forced = null;

  /// Builds a state whose meaning is dictated by its RECORD TYPE rather than by
  /// the letter alone.
  ///
  /// Only the unmerged record needs this. git reuses `A` and `D` there for
  /// conflicts (`AU`, `DU`, `UD`, `AD`, …), so reading those letters literally
  /// inside a `u` record would file a conflicted path under "added" — exactly
  /// the coercion [GitChangeKind] exists to prevent.
  GitState.forced(this.letter, this._forced);

  /// The letter exactly as git printed it.
  final String letter;

  final GitChangeKind? _forced;

  /// What this side means. Null means "unchanged on this side" — the `.` case,
  /// which is genuinely not a change rather than an unknown letter.
  GitChangeKind? get kind => _forced ?? GitChangeKind.fromLetter(letter);

  /// True when the letter meant nothing to this build.
  bool get isUnrecognised => kind == GitChangeKind.unrecognised;

  @override
  String toString() => letter;

  @override
  bool operator ==(Object other) => other is GitState && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  /// Git's letter for "nothing on this side".
  static const clean = '.';
}

/// One changed path.
class GitEntry {
  /// Renders one entry. [rawStatus] is retained verbatim for diagnostics — a
  /// status string that cannot be rendered is exactly the thing a bug report
  /// needs to contain.
  const GitEntry({
    required this.path,
    required this.index,
    required this.worktree,
    required this.rawStatus,
    this.originalPath,
  });

  /// The path, relative to the repository root, as git printed it.
  final String path;

  /// Where the file came from, for a rename or a copy. Null otherwise.
  final String? originalPath;

  /// The index (staging area) side.
  final GitState index;

  /// The worktree side.
  final GitState worktree;

  /// The raw porcelain status field, kept for diagnostics.
  final String rawStatus;

  /// True when the change this entry describes is real on the untracked side.
  ///
  /// Git reports untracked and ignored files with an empty status pair and a
  /// record type of its own; the parsers synthesise `?` and `!` so the rest of
  /// the code has one story to tell.
  bool get isUntracked => index.kind == GitChangeKind.untracked;
  bool get isIgnored => index.kind == GitChangeKind.ignored;

  /// True when git could not merge this path and a human has to.
  ///
  /// Checked on the KIND rather than by looking for the letter `U`, because an
  /// unmerged record can spell its conflict `AU`, `DU`, `AD`, `AA`, `DD`, `UA`,
  /// `UD` or `UU` — and [GitState.forced] is what turns all of them into the one
  /// meaning they share.
  bool get isConflicted =>
      index.kind == GitChangeKind.conflicted ||
      worktree.kind == GitChangeKind.conflicted;

  /// True when something is staged for the next commit.
  ///
  /// Untracked files are excluded deliberately: "staged" means a commit would
  /// pick it up, and `git commit` without `-a` would not. An UNRECOGNISED letter
  /// is excluded for the stronger reason: a letter this build cannot read is not
  /// evidence that anything is staged, and filing it here would present a guess
  /// as a fact. It is surfaced through [hasUnrecognisedStatus] instead.
  ///
  /// A CONFLICT is excluded too, and the exclusion has to be written even though
  /// a conflicted side is never clean — git spells a conflict on both sides, so
  /// without this a broken file would appear under "staged" as well as under
  /// "conflicted" and imply a commit would take it.
  bool get isStaged =>
      !isUntracked &&
      !isIgnored &&
      !isConflicted &&
      index.kind != null &&
      index.kind != GitChangeKind.unrecognised;

  /// True when there are edits not yet staged.
  ///
  /// Unrecognised letters are excluded for the same reason as [isStaged], and a
  /// CONFLICT is excluded even when its worktree letter is set — which is always,
  /// because git spells a conflict on both sides. Filing it here as well as in
  /// [GitStatus.conflicted] would report one unresolved file twice and imply the
  /// reader could just stage it.
  bool get isUnstaged =>
      !isUntracked &&
      !isIgnored &&
      !isConflicted &&
      worktree.kind != null &&
      worktree.kind != GitChangeKind.unrecognised;

  /// Whether an unrecognised status letter appears anywhere in this entry.
  bool get hasUnrecognisedStatus => index.isUnrecognised || worktree.isUnrecognised;

  @override
  String toString() => 'GitEntry(${index.letter}${worktree.letter} $path)';
}

/// A parsed `git status`.
class GitStatus {
  const GitStatus({
    required this.branch,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.entries = const [],
    this.hasUpstream = false,
  });

  /// An empty status, for a repository with nothing to report.
  const GitStatus.empty()
      : branch = null,
        upstream = null,
        ahead = 0,
        behind = 0,
        entries = const [],
        hasUpstream = false;

  /// The current branch, or null when HEAD is detached or unborn.
  final String? branch;

  /// The upstream ref, e.g. `origin/main`. Null when the branch has none.
  final String? upstream;

  /// Whether git reported an upstream relationship at all.
  ///
  /// Separate from [upstream] being non-null because a branch can have an
  /// upstream whose name git did not print in a form we kept. "No upstream" and
  /// "an upstream I could not name" are different answers, and only the first
  /// should be stated as fact.
  final bool hasUpstream;

  final int ahead;
  final int behind;

  final List<GitEntry> entries;

  /// Everything git would put in the next commit.
  List<GitEntry> get staged =>
      entries.where((e) => e.isStaged).toList(growable: false);

  /// Everything touched but not staged.
  List<GitEntry> get unstaged =>
      entries.where((e) => e.isUnstaged).toList(growable: false);

  List<GitEntry> get untracked =>
      entries.where((e) => e.isUntracked).toList(growable: false);

  List<GitEntry> get conflicted =>
      entries.where((e) => e.isConflicted).toList(growable: false);

  /// Nothing to report: no staged, unstaged, untracked or conflicted entries.
  ///
  /// Ignored files do not count — a working tree is not "dirty" because a build
  /// directory exists. An entry with an UNRECOGNISED status letter DOES count,
  /// because the one thing this must not do is call a tree clean when it did not
  /// understand what git said. That entry is excluded from every section (see
  /// [GitEntry.isStaged]) and is surfaced by [hasUnrecognisedStatus] instead, so
  /// without this it would be invisible noise; with it, the screen cannot say
  /// "working tree clean" about a status it could not read.
  bool get isClean =>
      !hasUnrecognisedStatus &&
      staged.isEmpty &&
      unstaged.isEmpty &&
      untracked.isEmpty &&
      conflicted.isEmpty;

  /// Whether any entry carried a status letter this build does not know.
  bool get hasUnrecognisedStatus => entries.any((e) => e.hasUnrecognisedStatus);

  /// Parses the `-z` form of `git status --porcelain=v2 --branch`.
  ///
  /// Record grammar, per git's `git-status` documentation:
  ///
  /// ```text
  /// # branch.oid <oid>              header lines start with '#'
  /// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
  /// 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><NUL><origPath>
  /// u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
  /// ? <path>
  /// ! <path>
  /// ```
  ///
  /// Everything except the header lines is NUL-separated, which is why the
  /// split below is on NUL and not on `\n`.
  static GitStatus parse(String output) {
    final records = output.split('\u0000');

    String? branch;
    String? upstream;
    var ahead = 0;
    var behind = 0;
    var sawUpstream = false;
    final entries = <GitEntry>[];

    // `-z` closes every record with a NUL, so the split leaves one empty tail.
    // Labelled so the unknown-record case can LEAVE the loop rather than
    // silently `continue`. There is no way to know how many fields an unknown
    // record carries, so every record after it would be misread — and misreading
    // a rename's second path is how a deleted file gets reported as modified.
    records:
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.isEmpty) continue;

      if (record.startsWith('#')) {
        final header = record.substring(1).trim();
        if (header.startsWith('branch.head ')) {
          final value = header.substring('branch.head '.length);
          // `(detached)` is git's own marker, not a branch name. Keeping it out
          // of [branch] is what lets the UI say "detached HEAD" honestly
          // instead of printing a branch literally called "(detached)".
          if (value != '(detached)') branch = value;
        } else if (header.startsWith('branch.upstream ')) {
          upstream = header.substring('branch.upstream '.length);
          sawUpstream = true;
        } else if (header.startsWith('branch.ab ')) {
          final ab = header.substring('branch.ab '.length).split(' ');
          for (final token in ab) {
            if (token.startsWith('+')) ahead = int.tryParse(token.substring(1)) ?? 0;
            if (token.startsWith('-')) behind = int.tryParse(token.substring(1)) ?? 0;
          }
        }
        // branch.oid is deliberately ignored: it identifies the commit, and
        // nothing on this screen needs it.
        continue;
      }

      switch (record[0]) {
        case '1':
          final e = _parseOrdinary(record);
          if (e != null) entries.add(e);
        case '2':
          // The rename/copy record's original path is the NEXT record, not a
          // field inside this one. An EMPTY next record is the `-z` frame's
          // trailing NUL rather than a path, so it is not consumed — a rename
          // at the very end of the output is normal, and reading the frame's
          // own terminator as the old name would put an empty string on screen.
          final next = i + 1 < records.length ? records[i + 1] : null;
          final original = (next == null || next.isEmpty) ? null : next;
          if (original != null) i++;
          final e = _parseRenamed(record, original);
          if (e != null) entries.add(e);
        case 'u':
          final e = _parseUnmerged(record);
          if (e != null) entries.add(e);
        case '?':
          // The record is `? <path>`; the space between them is the separator,
          // not part of the name. Both readings matter here in a way they do
          // not for the numbered records, because a leading space in a path is
          // legal and would silently make every untracked file unreachable.
          final path = record.substring(1).trimLeft();
          if (path.isNotEmpty) {
            entries.add(
              GitEntry(
                path: path,
                index: GitState('?'),
                worktree: GitState(GitState.clean),
                rawStatus: '?',
              ),
            );
          }
        case '!':
          // Ignored files are parsed and then grouped out of every section. They
          // are not a fifth thing to show — but dropping them at parse time
          // would mean the parser could not be tested against a real
          // `--ignored` capture.
          final path = record.substring(1).trimLeft();
          if (path.isNotEmpty) {
            entries.add(
              GitEntry(
                path: path,
                index: GitState('!'),
                worktree: GitState(GitState.clean),
                rawStatus: '!',
              ),
            );
          }
        default:
          break records;
      }
    }

    return GitStatus(
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      entries: entries,
      hasUpstream: sawUpstream,
    );
  }

  /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
  ///
  /// Every field up to the path is a token with no spaces in it — modes and
  /// abbreviated object hashes are hex, and `sub` is `N...` or `S<c><m><u>` —
  /// so the FIRST eight tokens after the record type are fixed and the path is
  /// the remainder. Taking the remainder rather than a further split field is
  /// what lets a path with spaces through.
  static GitEntry? _parseOrdinary(String record) {
    final parts = record.split(' ');
    if (parts.length < 9) return null;
    final status = parts[1];
    if (status.length < 2) return null;
    final path = parts.skip(8).join(' ');
    if (path.isEmpty) return null;
    return GitEntry(
      path: path,
      index: GitState(status[0]),
      worktree: GitState(status[1]),
      rawStatus: status,
    );
  }

  /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` + original.
  ///
  /// One more fixed field than the ordinary record: the combined rename/copy
  /// score (`R100`, `C075`).
  static GitEntry? _parseRenamed(String record, String? originalPath) {
    final parts = record.split(' ');
    if (parts.length < 10) return null;
    final status = parts[1];
    if (status.length < 2) return null;
    final path = parts.skip(9).join(' ');
    if (path.isEmpty) return null;
    return GitEntry(
      path: path,
      originalPath: originalPath,
      index: GitState(status[0]),
      worktree: GitState(status[1]),
      rawStatus: status,
    );
  }

  /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
  ///
  /// Four unmerged STAGES rather than the ordinary record's three modes, so the
  /// path is the tenth token onwards. Anchoring from the END is not an option
  /// here for the same reason it is not for the others: the path may contain
  /// spaces, so the end of a space-separated list is not where the path ends.
  ///
  /// An unmerged record's letters (`DD`, `AU`, `AA`, `UU`, …) are read with the
  /// CONFLICT meaning forced: in a `u` record there is no such thing as an added
  /// file, only an unresolved one. Reading `A`/`D` literally here would file a
  /// conflicted path under "added" — the exact coercion [GitChangeKind] exists
  /// to prevent.
  static GitEntry? _parseUnmerged(String record) {
    final parts = record.split(' ');
    if (parts.length < 11) return null;
    final status = parts[1];
    if (status.length < 2) return null;
    final path = parts.skip(10).join(' ');
    if (path.isEmpty) return null;
    return GitEntry(
      path: path,
      index: _conflictedState(status[0]),
      worktree: _conflictedState(status[1]),
      rawStatus: status,
    );
  }

  static GitState _conflictedState(String letter) => letter == GitState.clean
      ? GitState(letter)
      : GitState.forced(letter, GitChangeKind.conflicted);
}
