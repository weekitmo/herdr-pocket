import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// The files an `@` reference can point at, for one directory.
///
/// ## Which files, and why that question has a short answer
///
/// The pane's own directory, listed once, then filtered on the phone. Not a
/// walk of the whole machine: an `@` menu is for the file you are working on,
/// and the interesting half of "what is here" is already decided by the thing
/// that decides it everywhere else — the project's ignore rules.
///
/// So: `git ls-files` where there is a repository (tracked files plus the
/// untracked ones git does not ignore — i.e. exactly the files a person working
/// in that directory considers to be there), and a bounded depth-limited `find`
/// where there is not.
///
/// ## One listing, then filter locally
///
/// The listing is fetched ONCE, when the menu opens, and every keystroke filters
/// the list on the phone. Re-running the command per keystroke would put a round
/// trip behind each character the user types — which is the exact cost the
/// composer exists to remove.
///
/// The cap is real and it is documented rather than hidden: a monorepo with
/// 40 000 paths gets its first [maxPaths], in order, and a file past the cap is
/// not offered. Paging that is a later problem; typing the path by hand still
/// works, and so does the `+` attach button.
class RemoteFileIndex {
  const RemoteFileIndex(this._runner);

  final RemoteCommandRunner _runner;

  /// How many paths are worth carrying to a phone.
  static const int maxPaths = 2000;

  /// Printed instead of a listing when the directory cannot be entered.
  ///
  /// A marker rather than an exit code, because `head` inside a pipeline owns
  /// the pipeline's status — a failed `cd` would arrive as zero, i.e. as "this
  /// folder is empty", which is a different sentence with a worse answer.
  static const String noDirectoryMarker = '__HERDR_NO_DIRECTORY__';

  Future<FileIndexResult> list(String directory) async {
    final cwd = _absolute(directory);
    if (cwd == null) return const FileIndexUnreadable('no directory for this pane');

    final String out;
    try {
      out = await _runner.runCommand(buildCommand(cwd: cwd));
    } on HerdrTransportException catch (e) {
      return FileIndexUnreadable(e.message);
    } on Object catch (e) {
      return FileIndexUnreadable('$e');
    }

    final (body, exitCode) = splitTrailingSentinel(out);
    if (exitCode == null) {
      // The paths that arrived are still paths; but a half-listed directory
      // shown as a complete one is a menu that quietly omits the file the user
      // is looking for.
      return const FileIndexUnreadable('the remote shell did not finish');
    }

    final paths = <String>[];
    final seen = <String>{};
    for (final raw in body.split('\n')) {
      final path = raw.trimRight();
      if (path.isEmpty) continue;
      if (path == noDirectoryMarker) {
        return FileIndexUnreadable('the directory is gone: $cwd');
      }
      if (!seen.add(path)) continue;
      paths.add(path);
    }
    return paths.isEmpty ? const FileIndexEmpty() : FileIndexFound(paths);
  }

  /// Visible for testing: this is generated shell.
  ///
  /// Built one shell word per line rather than written as one big literal,
  /// because a generated command has two kinds of dollar sign in it —
  /// `$maxPaths` is Dart's, `$f` and `$?` are the remote shell's — and telling
  /// them apart inside one long string is how a command comes out silently
  /// wrong. See the same note in `remote_capabilities.dart`.
  /// The command as the machine receives it: [buildScript] inside a POSIX shell.
  static String buildCommand({required String cwd, int maxPaths = maxPaths}) =>
      posixShellCommand(buildScript(cwd: cwd, maxPaths: maxPaths));

  /// The script itself, before the wrapper. Split out for the tests.
  static String buildScript({required String cwd, int maxPaths = maxPaths}) {
    final quote = quoteRemotePath(cwd);
    final git = 'LC_ALL=C git -C $quote';
    final script = StringBuffer()
          ..writeln('if $git rev-parse --is-inside-work-tree >/dev/null 2>&1; then')
          // `head` sits INSIDE each branch, so the pipeline's status is the
          // branch's and no separate `exit` has to be threaded through to keep
          // the sentinel reachable.
          ..writeln(
            '  $git ls-files --cached --others --exclude-standard 2>/dev/null '
            '| head -n $maxPaths',
          )
          ..writeln('else')
          ..writeln('  if cd $quote 2>/dev/null; then')
          ..writeln(r'    find . -maxdepth 5 -type f \')
          ..writeln(r"      -not -path './.git/*' -not -path '*/node_modules/*' \")
          ..writeln(r'      2>/dev/null \')
          // `\.` reaches sed escaped, and sed is what turns it back into a dot.
          ..writeln("      | sed -e 's|^\\./||' | head -n $maxPaths")
          ..writeln('  else')
          ..writeln("    printf '$noDirectoryMarker\\n'")
          ..writeln('  fi')
          ..writeln('fi')
          ..write("printf '$remoteExitMarkerEscape%s' \"\$?\"");

    return script.toString();
  }
}

/// What the listing found.
sealed class FileIndexResult {
  const FileIndexResult();
}

/// Paths, relative to the directory that was listed.
final class FileIndexFound extends FileIndexResult {
  const FileIndexFound(this.paths);

  final List<String> paths;
}

/// The directory is there and holds nothing to reference.
final class FileIndexEmpty extends FileIndexResult {
  const FileIndexEmpty();
}

/// The listing could not be read, or did not arrive whole.
final class FileIndexUnreadable extends FileIndexResult {
  const FileIndexUnreadable(this.detail);

  final String detail;
}

String? _absolute(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty || !trimmed.startsWith('/')) {
    return null;
  }
  return trimmed.endsWith('/') && trimmed.length > 1
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// The index, wired to the live connection.
final fileIndexProvider = Provider<RemoteFileIndex?>(
  (ref) {
    final runner = ref.watch(remoteRunnerProvider);
    return runner == null ? null : RemoteFileIndex(runner);
  },
);
