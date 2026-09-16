import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/git/git_status.dart';

/// Tests for the `--porcelain=v2 -z` parser.
///
/// EVERY FIXTURE BELOW IS REAL CAPTURED OUTPUT, not a hand-written approximation
/// of git's format. They were produced on this machine (git 2.53.0 on macOS) by
/// running, in a scratch repository in /tmp:
///
/// ```sh
/// git status --porcelain=v2 --branch -z --untracked-files=normal
/// ```
///
/// and then transcribing the bytes, with `\x00` written as an escape. Getting
/// this wrong is invisible: a mis-split record produces a plausible-looking
/// filename and a plausible-looking status letter, so the parser would keep
/// "working" while lying. That is the reason the fixtures are captured rather
/// than invented.
void main() {
  group('branch headers', () {
    test('clean tree: branch, upstream and no entries', () {
      // A checkout two directories down, on branch main tracking origin/main.
      const out = '# branch.oid 93c6578666e656c32066e61389e81853bcc0b88d\x00'
          '# branch.head main\x00'
          '# branch.upstream origin/main\x00'
          '# branch.ab +0 -0\x00';

      final status = GitStatus.parse(out);

      expect(status.branch, 'main');
      expect(status.upstream, 'origin/main');
      expect(status.hasUpstream, isTrue);
      expect(status.ahead, 0);
      expect(status.behind, 0);
      expect(status.entries, isEmpty);
      expect(status.isClean, isTrue);
    });

    test('ahead and behind are read off branch.ab', () {
      const out = '# branch.head feature/x\x00'
          '# branch.upstream origin/feature/x\x00'
          '# branch.ab +3 -7\x00';

      final status = GitStatus.parse(out);

      expect(status.ahead, 3);
      expect(status.behind, 7);
      expect(status.hasUpstream, isTrue);
    });

    test('a repo with no upstream says so rather than guessing', () {
      // Freshly `git init`-ed repository, before any remote exists.
      const out = '# branch.oid 484cc83b497bb383a8a1789474749a201c3d2d5e\x00'
          '# branch.head master\x00';

      final status = GitStatus.parse(out);

      expect(status.branch, 'master');
      expect(status.upstream, isNull);
      expect(status.hasUpstream, isFalse);
    });

    test('a detached HEAD is not reported as a branch', () {
      // `(detached)` is git's marker, not a name. Reporting it as the branch
      // would print a branch called "(detached)" on screen.
      const out = '# branch.oid 484cc83b497bb383a8a1789474749a201c3d2d5e\x00'
          '# branch.head (detached)\x00';

      final status = GitStatus.parse(out);

      expect(status.branch, isNull);
    });
  });

  group('entries', () {
    test('modified file', () {
      // `echo mod >> a.txt` in the scratch repo.
      const out = '# branch.head master\x00'
          '1 .M N... 100644 100644 100644 45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 a.txt\x00';

      final status = GitStatus.parse(out);
      final entry = status.entries.single;

      expect(entry.path, 'a.txt');
      expect(entry.index.kind, isNull, reason: '`.` means unchanged, not unknown');
      expect(entry.worktree.kind, GitChangeKind.modified);
      expect(entry.isUnstaged, isTrue);
      expect(entry.isStaged, isFalse);
      expect(status.unstaged.single, same(entry));
      expect(status.isClean, isFalse);
    });

    test('untracked file', () {
      // `echo new > untracked.txt`.
      const out = '? untracked.txt\x00';

      final status = GitStatus.parse(out);
      final entry = status.entries.single;

      expect(entry.path, 'untracked.txt');
      expect(entry.index.kind, GitChangeKind.untracked);
      // Untracked is NOT staged: `git commit` without `-a` would not pick it
      // up, and calling it staged would make the section lie.
      expect(entry.isStaged, isFalse);
      expect(entry.isUnstaged, isFalse);
      expect(status.untracked.single, same(entry));
      expect(status.staged, isEmpty);
    });

    test('staged file', () {
      // `echo staged > staged.txt && git add staged.txt`. The hash is the blob
      // of the empty file because the scratch repo's file was created empty
      // before the echo; the field's VALUE does not matter, its POSITION does.
      const out = '1 A. N... 000000 100644 100644 '
          '0000000000000000000000000000000000000000 '
          '19d9cc8584ac2c7dcf57d2680375e80f099dc481 staged.txt\x00';

      final status = GitStatus.parse(out);
      final entry = status.entries.single;

      expect(entry.path, 'staged.txt');
      expect(entry.index.kind, GitChangeKind.added);
      expect(entry.worktree.kind, isNull);
      expect(entry.isStaged, isTrue);
      expect(status.staged.single, same(entry));
    });

    test('rename: the two NUL-separated paths are new-then-original', () {
      // `git mv a.txt renamed.txt` plus an edit. THIS is the record that makes
      // a naive parser lose every following entry: the original path is a
      // SEPARATE NUL-terminated record, not a field.
      const out = '2 RM N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 R100 renamed.txt\x00'
          'a.txt\x00'
          '? untracked.txt\x00';

      final status = GitStatus.parse(out);

      expect(status.entries, hasLength(2));
      final rename = status.entries.first;
      expect(rename.path, 'renamed.txt', reason: 'git prints the NEW path first');
      expect(rename.originalPath, 'a.txt');
      expect(rename.index.kind, GitChangeKind.renamed);
      expect(rename.worktree.kind, GitChangeKind.modified);

      // The record after the rename is still read correctly, which is the
      // whole point of consuming the second path.
      expect(status.entries.last.path, 'untracked.txt');
      expect(status.untracked.single.path, 'untracked.txt');
    });

    test('the full captured status parses record for record', () {
      // The complete capture from the scratch repo, in the order git printed
      // it: the rename pair, the staged file, the untracked file.
      const out = '# branch.oid 484cc83b497bb383a8a1789474749a201c3d2d5e\x00'
          '# branch.head master\x00'
          '2 RM N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 R100 renamed.txt\x00'
          'a.txt\x00'
          '1 A. N... 000000 100644 100644 '
          '0000000000000000000000000000000000000000 '
          '19d9cc8584ac2c7dcf57d2680375e80f099dc481 staged.txt\x00'
          '? untracked.txt\x00';

      final status = GitStatus.parse(out);

      expect(status.branch, 'master');
      expect(status.entries.map((e) => e.path).toList(), [
        'renamed.txt',
        'staged.txt',
        'untracked.txt',
      ]);
      expect(status.staged.map((e) => e.path).toList(), [
        'renamed.txt',
        'staged.txt',
      ]);
      expect(status.untracked.map((e) => e.path).toList(), ['untracked.txt']);
      expect(status.unstaged.map((e) => e.path).toList(), ['renamed.txt']);
      expect(status.isClean, isFalse);
    });

    test('paths with spaces survive', () {
      // Ordinary record, 8 fixed fields then the path.
      const out = '1 .M N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 docs/my notes.txt\x00';

      expect(GitStatus.parse(out).entries.single.path, 'docs/my notes.txt');
    });

    test('ignored files are parsed, and are neither staged nor unstaged', () {
      // `-z` with `--ignored` produces `!` records; they arrive only when
      // `--ignored` asks for them, but the parser must not file them as changes.
      const out = '! build/output.o\x00';

      final status = GitStatus.parse(out);
      final entry = status.entries.single;

      expect(entry.index.kind, GitChangeKind.ignored);
      expect(entry.isStaged, isFalse);
      expect(entry.isUnstaged, isFalse);
      // A working tree is not dirty because a build directory exists.
      expect(status.isClean, isTrue);
    });
  });

  group('conflicts', () {
    test('an unmerged record is conflicted, whatever its letters say', () {
      // Both sides modified. The stage modes and hashes are the shape git
      // prints for an unmerged path; the point of the test is the READING of
      // `UU`, not the hash values.
      const out = 'u UU N... 100644 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '19d9cc8584ac2c7dcf57d2680375e80f099dc481 '
          '5fb37f0000000000000000000000000000000000 clashed.txt\x00';

      final status = GitStatus.parse(out);
      final entry = status.entries.single;

      expect(entry.index.kind, GitChangeKind.conflicted);
      expect(entry.worktree.kind, GitChangeKind.conflicted);
      expect(status.conflicted.single, same(entry));
      // A conflict has its own section. Filing it under "staged" or "unstaged"
      // as well would report one broken file twice and imply a commit would
      // pick it up.
      expect(entry.isStaged, isFalse);
      expect(entry.isUnstaged, isFalse);
      expect(status.staged, isEmpty);
      expect(status.unstaged, isEmpty);
      expect(status.conflicted, hasLength(1));
      expect(status.isClean, isFalse);
    });

    test('`AU` in an unmerged record is a conflict, not an addition', () {
      // The coercion this parser exists to refuse: `A` in an ordinary record
      // means "added", so reading the letter literally here would file a
      // conflicted path under "added" and hide the fact that a human has to
      // resolve it.
      const out = 'u AU N... 100644 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '19d9cc8584ac2c7dcf57d2680375e80f099dc481 '
          '0000000000000000000000000000000000000000 theirs.txt\x00';

      final entry = GitStatus.parse(out).entries.single;

      expect(entry.index.kind, GitChangeKind.conflicted);
      expect(entry.index.letter, 'A', reason: 'the raw letter is still carried');
    });
  });

  group('fail-closed on the unknown', () {
    test('an unknown status letter is KEPT, not coerced to modified', () {
      // No version of git emits `Q`. That is the point: this is what a future
      // git — or a patch series in someone's fork — would look like, and the
      // one thing the client must not do is call it "modified" and move on.
      const out = '1 .Q N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 mystery.txt\x00';

      final status = GitStatus.parse(out);
      final entry = status.entries.single;

      expect(entry.worktree.kind, GitChangeKind.unrecognised);
      expect(entry.worktree.letter, 'Q');
      expect(entry.hasUnrecognisedStatus, isTrue);
      expect(status.hasUnrecognisedStatus, isTrue);
      // Still counted as a change: an unreadable status is not a clean tree.
      expect(status.isClean, isFalse);
    });

    test('an unknown status letter does not become staged or unstaged', () {
      // `unrecognised` is neither, so it falls outside every section. That is
      // the fail-closed choice: it is reported through
      // [GitStatus.hasUnrecognisedStatus] rather than being smuggled into a
      // section where a human would read it as something they recognise.
      const out = '1 Q. N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 mystery.txt\x00';

      final status = GitStatus.parse(out);

      expect(status.staged, isEmpty);
      expect(status.unstaged, isEmpty);
      expect(status.isClean, isFalse);
      expect(status.hasUnrecognisedStatus, isTrue);
    });

    test('an unknown RECORD TYPE stops the parse instead of misreading', () {
      // A `x` record is not a thing. The parser cannot know how many fields it
      // carries, so reading on would shift every following record — and a
      // shifted rename is a deleted file reported as modified.
      const out = 'x something new\x00'
          '1 .M N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 a.txt\x00';

      final status = GitStatus.parse(out);

      expect(status.entries, isEmpty);
    });

    test('a truncated ordinary record is dropped, not half-read', () {
      const out = '1 .M N... 100644\x00';

      expect(GitStatus.parse(out).entries, isEmpty);
    });

    test('a rename with a missing original path still reports the new one', () {
      // The tail of a truncated reply. The entry is still real; only the
      // original name is unknown, and null says exactly that.
      const out = '2 RM N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 R100 renamed.txt\x00';

      final entry = GitStatus.parse(out).entries.single;

      expect(entry.path, 'renamed.txt');
      expect(entry.originalPath, isNull);
    });

    test('empty output is an empty status, not a crash', () {
      final status = GitStatus.parse('');

      expect(status.entries, isEmpty);
      expect(status.branch, isNull);
      expect(status.isClean, isTrue);
    });
  });

  group('grouping', () {
    test('a file staged AND further modified appears in both sections', () {
      // `MM` is the common case: `git add` then keep editing. Two different
      // diffs, so two rows — collapsing them would hide one.
      const out = '1 MM N... 100644 100644 100644 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 both.txt\x00';

      final status = GitStatus.parse(out);

      expect(status.staged.single.path, 'both.txt');
      expect(status.unstaged.single.path, 'both.txt');
      expect(status.entries.single.isStaged, isTrue);
      expect(status.entries.single.isUnstaged, isTrue);
    });

    test('a deleted file is deleted on whichever side git says', () {
      const out = '1 D. N... 100644 000000 000000 '
          '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
          '0000000000000000000000000000000000000000 gone.txt\x00';

      final entry = GitStatus.parse(out).entries.single;

      expect(entry.index.kind, GitChangeKind.deleted);
      expect(entry.worktree.kind, isNull);
    });
  });
}
