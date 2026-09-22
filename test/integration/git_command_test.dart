import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/git_client.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/git/git_diff.dart';
import 'package:herdr_pocket/domain/git/git_status.dart';

/// The generated git commands, run for real.
///
/// WHY THIS EXISTS. `test/ui/file_and_git_page_test.dart` answers every command
/// with a fake runner, and a fake runner is more forgiving than a shell: it
/// cannot tell `--no-index`'s exit 1 ("there are differences") apart from a
/// failure, it never rejects a path, and — the reason this file exists — it
/// never notices which DIRECTORY the command runs in. The bug that made a
/// brand-new file report "no diff to show" lived exactly in that gap: the old
/// fallback read a repository-root-relative path from a shell whose cwd is the
/// user's home, and every fake-runner test went on passing.
///
/// So this runs the command strings [GitClient] builds against a REAL temporary
/// repository, through a real POSIX shell, from the user's home — the way an
/// SSH exec session behaves. No daemon, no sshd, no phone: the only requirements
/// are git and `/bin/sh`.
class _LocalShellRunner implements RemoteCommandRunner {
  const _LocalShellRunner(this.home);

  /// The directory commands run in. HOME, deliberately: that is where an ssh
  /// exec request starts, and it is what makes a relative path a bug rather
  /// than a coincidence that happens to work.
  final String home;

  @override
  Future<String> runCommand(String command) async {
    final result = await Process.run(
      '/bin/sh',
      ['-c', command],
      workingDirectory: home,
      stdoutEncoding: utf8,
    );
    return result.stdout as String;
  }
}

/// Runs `git` for TEST SETUP (building the repository), not for the code under
/// test — that distinction matters here: the assertions must go through
/// [GitClient], or they would be comparing git with git.
Future<void> _git(Directory repo, List<String> args) async {
  final result = await Process.run('git', ['-C', repo.path, ...args]);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

void main() {
  final home = Platform.environment['HOME'] ?? '';
  final skipReason = Platform.isWindows
      ? 'this test drives a POSIX shell'
      : !File('/bin/sh').existsSync()
          ? 'no /bin/sh'
          : Process.runSync('git', ['--version']).exitCode != 0
              ? 'git is not installed'
              : home.isEmpty
                  ? 'no HOME to run commands from'
                  : null;

  group('GitClient against a real repository', () {
    late Directory repo;
    final runner = _LocalShellRunner(home);

    GitClient client({int? maxDiffBytes}) => GitClient(
          runner,
          maxDiffBytes: maxDiffBytes ?? GitClient.defaultMaxDiffBytes,
        );

    setUp(() async {
      // Resolved through the filesystem on purpose: on macOS `git rev-parse
      // --show-toplevel` answers `/private/var/...` for a temp directory spelled
      // `/var/...`, and comparing the two spellings of one directory is a test
      // bug, not a product bug.
      repo = Directory(
        Directory.systemTemp.createTempSync('herdr-git-').resolveSymbolicLinksSync(),
      );
      await _git(repo, ['init', '-q']);
      await _git(repo, ['config', 'user.email', 'pocket@example.com']);
      await _git(repo, ['config', 'user.name', 'Pocket Test']);
      File('${repo.path}/tracked.txt').writeAsStringSync('one\n');
      await _git(repo, ['add', 'tracked.txt']);
      await _git(repo, ['commit', '-qm', 'init']);
    });

    tearDown(() {
      if (repo.existsSync()) repo.deleteSync(recursive: true);
    });

    Future<GitStatus> status() async {
      final result = await client().status(repo.path);
      expect(result, isA<GitStatusBody>(), reason: 'status should have answered');
      return (result as GitStatusBody).status;
    }

    Future<GitDiff> diffFor(String path, {bool staged = false}) async {
      final result = await client().diff(repo.path, path: path, staged: staged);
      expect(result, isA<GitDiffBody>(), reason: 'diff should have answered');
      return (result as GitDiffBody).diff;
    }

    Future<GitDiffResult> untrackedFor(String path, {int? maxDiffBytes}) =>
        client(maxDiffBytes: maxDiffBytes).untrackedDiff(repo.path, path);

    test('a new file is its own untracked entry, even inside a new directory',
        () async {
      // `--untracked-files=all`. With `normal` this is ONE `? new/` row that can
      // never be diffed, which is how a file created inside a fresh directory
      // came to have no diff on the phone.
      Directory('${repo.path}/new').createSync();
      File('${repo.path}/new/inner.txt').writeAsStringSync('inner\n');

      final result = await status();

      expect(
        result.untracked.map((e) => e.path),
        contains('new/inner.txt'),
      );
    });

    test('an untracked file comes back as additions, not as "no diff"', () async {
      File('${repo.path}/fresh.txt')
          .writeAsStringSync('hello from a new file\n');

      final result = await untrackedFor('fresh.txt');

      expect(result, isA<GitDiffBody>());
      final diff = (result as GitDiffBody).diff;
      expect(diff.isEmpty, isFalse);
      expect(diff.addedCount, 1);
      expect(diff.hunks.single.lines.single.text, 'hello from a new file');
      expect(diff.hunks.single.header, contains('new file mode 100644'));
      expect(diff.hunks.single.header, contains('--- /dev/null'));
    });

    test('a nested new file is diffed through the ROOT, not the subdirectory',
        () async {
      // The git page resolves the repository root first and asks from there,
      // because every path git prints is root-relative. This is that sequence,
      // run for real: resolve the root from a subdirectory, then diff a path
      // relative to it.
      Directory('${repo.path}/sub').createSync();
      File('${repo.path}/sub/note.txt').writeAsStringSync('nested\n');

      final root = await client().repoRoot('${repo.path}/sub');
      expect(root, repo.path);

      final result = await client().untrackedDiff(root!, 'sub/note.txt');

      expect(result, isA<GitDiffBody>());
      final diff = (result as GitDiffBody).diff;
      expect(diff.addedCount, 1);
      expect(diff.hunks.single.lines.single.text, 'nested');
    });

    test('a BINARY new file says git called it binary, not that nothing changed',
        () async {
      File('${repo.path}/blob.bin')
          .writeAsBytesSync([0x00, 0x01, 0x02, 0x03, 0x00, 0xff, 0xfe]);

      final result = await untrackedFor('blob.bin');

      expect(result, isA<GitDiffBody>());
      final diff = (result as GitDiffBody).diff;
      expect(diff.isEmpty, isFalse);
      expect(diff.meta, anyElement(contains('Binary files')));
      expect(diff.hunks, isEmpty);
    });

    test('a new EMPTY file shows its header rather than nothing at all',
        () async {
      File('${repo.path}/empty.txt').writeAsStringSync('');

      final result = await untrackedFor('empty.txt');

      expect(result, isA<GitDiffBody>());
      final diff = (result as GitDiffBody).diff;
      expect(diff.isEmpty, isFalse);
      expect(diff.meta, anyElement(contains('new file mode')));
    });

    test('a path that does not exist is a failure, not an empty diff', () async {
      final result = await untrackedFor('never-existed.txt');

      expect(result, isA<GitDiffFailure>());
    });

    test('an untracked diff is CAPPED, like every other diff', () async {
      File('${repo.path}/big.txt').writeAsStringSync(
        List.generate(200, (i) => 'line $i').join('\n'),
      );

      final result = await untrackedFor('big.txt', maxDiffBytes: 100);

      expect(result, isA<GitDiffBody>());
      expect((result as GitDiffBody).truncated, isTrue);
    });

    test('a deleted file shows what was removed', () async {
      File('${repo.path}/tracked.txt').deleteSync();

      final diff = await diffFor('tracked.txt');

      expect(diff.removedCount, 1);
      expect(diff.hunks.single.lines.single.text, 'one');
    });

    test('a staged NEW file shows its content as additions', () async {
      File('${repo.path}/staged_new.txt').writeAsStringSync('staged content\n');
      await _git(repo, ['add', 'staged_new.txt']);
      // And the status must agree it is staged rather than untracked, or the
      // page would ask the wrong question of the wrong command.
      final parsed = await status();
      expect(parsed.staged.map((e) => e.path), contains('staged_new.txt'));
      expect(parsed.untracked, isEmpty);

      final diff = await diffFor('staged_new.txt', staged: true);

      expect(diff.addedCount, 1);
      expect(diff.hunks.single.lines.single.text, 'staged content');
      expect(diff.hunks.single.header, contains('new file mode 100644'));
    });

    test('a staged DELETION shows what was removed', () async {
      await _git(repo, ['rm', '-q', 'tracked.txt']);

      final diff = await diffFor('tracked.txt', staged: true);

      expect(diff.removedCount, 1);
      expect(diff.hunks.single.header, contains('deleted file mode'));
    });

    test('a directory that is not a repository is reported as such, not clean',
        () async {
      final outside = Directory.systemTemp.createTempSync('herdr-not-a-repo-');
      addTearDown(() => outside.deleteSync(recursive: true));

      final result = await client().status(outside.path);

      expect(result, isA<GitStatusFailure>());
      expect(
        (result as GitStatusFailure).reason,
        GitFailure.notARepository,
      );
    });
  }, skip: skipReason);
}
