import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/git/git_diff.dart';
import 'package:herdr_pocket/domain/git/git_status.dart';

/// Where a git query's exit code came from.
///
/// Shares [splitTrailingSentinel] with the file reader rather than
/// re-implementing the search: the marker's shape and the quirks of finding it
/// are one subject, and two copies would drift.
({String body, int? exitCode}) _splitExit(String out) {
  final (body, code) = splitTrailingSentinel(out);
  // `printf` puts a newline before the sentinel, so a body produced by a command
  // that does NOT end in one — `git status -z` ends in a NUL — would otherwise
  // carry a stray newline into the LAST field it printed. That is how a branch
  // name becomes `main\n`.
  return (
    body: body.endsWith('\n') ? body.substring(0, body.length - 1) : body,
    exitCode: code,
  );
}

/// Runs `git` on the machine the daemon runs on.
///
/// herdr's own API exposes NOTHING about git — verified against a live 0.9.0,
/// whose method list contains only `worktree.list`, which carries a branch name
/// and topology and no changed files at all. `herdr-sidebar` (the TUI that ships
/// alongside it) reads git by SHELLING OUT, so that is the data source, not a
/// shortcut: the daemon has no better answer to give.
///
/// TWO THINGS HERE ARE LOAD-BEARING.
///
/// `LC_ALL=C` on every command. git translates its messages, and on this
/// machine `git -C /tmp status` prints `致命错误：不是 Git 仓库`. Matching message
/// text to decide "is this a repository" would therefore work in one locale and
/// fail in another. Pinning the locale makes the text stable, and the exit code
/// makes it unnecessary.
///
/// The exit code is carried in stdout behind a sentinel, because
/// [RemoteCommandRunner.runCommand] returns stdout and nothing else. `;` rather
/// than `&&` between the git command and the sentinel: with `&&` a failing git
/// would skip the `printf` and the failure would be indistinguishable from a
/// truncated reply.
class GitClient {
  /// Wraps one command runner.
  const GitClient(this._runner, {this.maxDiffBytes = defaultMaxDiffBytes});

  /// How much diff text to accept before calling it truncated.
  ///
  /// A diff is read by a human on a phone. 128 KB is already far past the point
  /// where anyone keeps scrolling, and the cap is what keeps a regenerated
  /// lockfile from becoming a multi-megabyte reply over SSH.
  static const defaultMaxDiffBytes = 131072;

  final RemoteCommandRunner _runner;
  final int maxDiffBytes;

  /// Whether `git` is installed on the far end.
  ///
  /// Exit 127 is the shell's "command not found", which is a different problem
  /// from "this directory is not a repository" and needs a different sentence.
  Future<bool> isAvailable() async {
    final out = await _runner.runCommand(
      'LC_ALL=C git --version 2>/dev/null; printf \'$remoteExitMarkerEscape%s\' "\$?"',
    );
    final result = _splitExit(out);
    return result.exitCode == 0;
  }

  /// The repository root containing [cwd], or null when there is none.
  ///
  /// Every path git prints is relative to the ROOT, not to the directory the
  /// command ran in, so a status read from a subdirectory cannot be joined back
  /// onto [cwd] without this. Resolving it first is what stops the file list
  /// from pointing at paths that do not exist.
  Future<String?> repoRoot(String cwd) async {
    final out = await _runner.runCommand(
      'LC_ALL=C git -C ${quoteRemotePath(cwd)} rev-parse --show-toplevel '
      "2>/dev/null; printf '$remoteExitMarkerEscape%s' \"\$?\"",
    );
    final result = _splitExit(out);
    if (result.exitCode != 0) return null;
    final root = _stripTrailingNewline(result.body);
    return root.isEmpty ? null : root;
  }

  /// Reads the status of the repository containing [cwd].
  ///
  /// Fail-closed about the two failures that are not "a clean tree": no git at
  /// all, and no repository. Each gets its own outcome, because "nothing is
  /// wrong here" and "I could not look" must never be the same sentence — the
  /// sidebar's own vocabulary draws the same line.
  ///
  /// `--untracked-files=all`, not `normal`. With `normal` a new DIRECTORY is a
  /// single `? dir/` row, and a directory is the one thing this feature can
  /// never diff — git refuses it, correctly, and the reader who just created
  /// `new/thing.txt` sees one un-openable row instead of their file. `all`
  /// lists unnamed files themselves, which is also what the desktop git clients
  /// do. Empty directories disappear from the listing under `all`, which is
  /// right: git cannot commit them, so there is nothing to report.
  Future<GitStatusResult> status(String cwd) async {
    final quote = quoteRemotePath(cwd);
    final out = await _runner.runCommand(
      'LC_ALL=C git -C $quote status --porcelain=v2 --branch '
      "--untracked-files=all -z 2>/dev/null; printf '$remoteExitMarkerEscape%s' \"\$?\"",
    );
    final result = _splitExit(out);
    final code = result.exitCode;

    if (code == null) return const GitStatusFailure(GitFailure.unknown);
    if (code == 127) return const GitStatusFailure(GitFailure.notInstalled);
    // 128 is git's catch-all for a fatal error, and "not a git repository" is
    // overwhelmingly what it is here. The message is only consulted when the
    // code says something else entirely, and `LC_ALL=C` is what keeps the text
    // that is matched against stable.
    if (code == 128 || result.body.contains('not a git repository')) {
      return const GitStatusFailure(GitFailure.notARepository);
    }
    if (code != 0) {
      return GitStatusFailure(
        GitFailure.unknown,
        detail: 'git status exited $code',
      );
    }

    return GitStatusBody(GitStatus.parse(result.body));
  }

  /// Reads the diff for [path], or for the whole tree when [path] is null.
  ///
  /// [staged] asks for the INDEX against HEAD (`--cached`), which is what "what
  /// am I about to commit" means. Unstaged is the worktree against the index.
  /// The two are different questions and the UI shows them as different
  /// sections, so this never merges them.
  Future<GitDiffResult> diff(
    String cwd, {
    String? path,
    bool staged = false,
  }) async {
    final quote = quoteRemotePath(cwd);
    // `--no-color` because this output is PARSED. A colourised diff would have
    // to be un-ANSIed before anything could be read out of it, and the styling
    // belongs to the theme rather than to a subprocess's idea of a terminal.
    final args = StringBuffer('git -C $quote diff --no-color --patch');
    if (staged) args.write(' --cached');
    if (path != null) {
      args
        ..write(' -- ')
        ..write(quoteRemotePath(path));
    }

    final out = await _runner.runCommand(
      'LC_ALL=C $args 2>/dev/null; printf \'$remoteExitMarkerEscape%s\' "\$?"',
    );
    final result = _splitExit(out);
    final code = result.exitCode;

    if (code == null) return const GitDiffFailure(GitFailure.unknown);
    if (code == 127) return const GitDiffFailure(GitFailure.notInstalled);
    if (code == 128 || result.body.contains('not a git repository')) {
      return const GitDiffFailure(GitFailure.notARepository);
    }
    if (code != 0) {
      return GitDiffFailure(
        GitFailure.unknown,
        detail: 'git diff exited $code',
      );
    }

    return _diffBody(result.body);
  }

  /// Reads the diff for a path git does not track yet.
  ///
  /// `git diff` cannot see a path that is not in the index, so an untracked
  /// file has no diff from it at all — which is the whole reason this method
  /// exists. `--no-index` is git's own answer: with `/dev/null` on one side it
  /// prints exactly what `git add -N` followed by `git diff` would have
  /// printed, `new file mode 100644` and content-as-additions included, and
  /// `Binary files … differ` for something it will not render.
  ///
  /// Synthesising that text in the UI — which is what this replaces — meant
  /// re-deriving the header, the missing-trailing-newline rule, the binary
  /// rule and the path base by hand. The path base came out wrong, and the file
  /// the user had just created was reported as "no diff to show".
  Future<GitDiffResult> untrackedDiff(String cwd, String path) async {
    final args = 'git -C ${quoteRemotePath(cwd)} diff --no-index --no-color '
        '--patch -- /dev/null ${quoteRemotePath(path)}';

    final out = await _runner.runCommand(
      'LC_ALL=C $args 2>/dev/null; printf \'$remoteExitMarkerEscape%s\' "\$?"',
    );
    final result = _splitExit(out);
    final code = result.exitCode;

    if (code == null) return const GitDiffFailure(GitFailure.unknown);
    if (code == 127) return const GitDiffFailure(GitFailure.notInstalled);
    // Exit 1 is `--no-index`'s way of saying "there are differences", so for
    // this one command it is the NORMAL answer rather than an error. It is also
    // what an unreadable path produces, and the two are told apart by the
    // output: anything git managed to read leaves at least the `diff --git`
    // line, while a path it could not access leaves stdout empty (its complaint
    // goes to the stderr this command discards).
    if (code == 1 && result.body.trim().isEmpty) {
      return GitDiffFailure(
        GitFailure.unknown,
        detail: 'git could not read $path',
      );
    }
    if (code != 0 && code != 1) {
      return GitDiffFailure(
        GitFailure.unknown,
        detail: 'git diff --no-index exited $code',
      );
    }

    return _diffBody(result.body);
  }

  /// Caps and parses one diff reply.
  ///
  /// THE SAME RULE FOR BOTH COMMANDS, deliberately: a diff read from `git diff`
  /// and one read from `git diff --no-index` are the same kind of answer, and two
  /// copies of "strip the sentinel newline, cut at the cap on a byte boundary,
  /// decode leniently" would eventually disagree about one of the three.
  GitDiffResult _diffBody(String stdout) {
    final body = _stripTrailingNewline(stdout);
    final encoded = utf8.encode(body);
    final truncated = encoded.length > maxDiffBytes;
    final text = truncated
        ? utf8.decode(encoded.sublist(0, maxDiffBytes), allowMalformed: true)
        : body;

    return GitDiffBody(GitDiff.parse(text), truncated: truncated);
  }

  /// A command's stdout loses its final newline to `printf`'s sentinel only if
  /// one was printed; git always prints one, and it is not part of the content.
  static String _stripTrailingNewline(String s) =>
      s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
}

/// Why a git query could not answer.
enum GitFailure {
  /// `git` is not on the far end at all (exit 127).
  notInstalled,

  /// git ran and said this is not a repository it can use (exit 128).
  notARepository,

  /// Anything else, including a reply with no exit code at all.
  unknown,
}

/// The outcome of [GitClient.status].
sealed class GitStatusResult {
  const GitStatusResult();
}

/// A status was produced.
class GitStatusBody extends GitStatusResult {
  /// Holds one parsed status.
  const GitStatusBody(this.status);

  final GitStatus status;
}

/// No status was produced, and why.
class GitStatusFailure extends GitStatusResult {
  /// Holds one failure and why.
  const GitStatusFailure(this.reason, {this.detail});

  final GitFailure reason;

  /// What the command did, for diagnostics. The UI localises from [reason].
  final String? detail;
}

/// The outcome of [GitClient.diff].
sealed class GitDiffResult {
  const GitDiffResult();
}

/// A diff was produced.
class GitDiffBody extends GitDiffResult {
  /// Holds one parsed diff.
  const GitDiffBody(this.diff, {this.truncated = false});

  final GitDiff diff;

  /// True when the diff was cut at [GitClient.maxDiffBytes].
  final bool truncated;
}

/// No diff was produced, and why.
class GitDiffFailure extends GitDiffResult {
  /// Holds one failure and why.
  const GitDiffFailure(this.reason, {this.detail});

  final GitFailure reason;
  final String? detail;
}

/// Picks the command runner out of a live connection.
///
/// Null is a real answer rather than a loading state — see
/// [remoteRunnerProvider], which this shares so both features agree about when
/// the far end can run commands at all.
final gitClientProvider = Provider<GitClient?>((ref) {
  final runner = ref.watch(remoteRunnerProvider);
  return runner == null ? null : GitClient(runner);
});
