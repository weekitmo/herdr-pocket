import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/git/git_status.dart';
import 'package:herdr_pocket/domain/git/git_tree_marks.dart';

/// Tests for the "which row wears what" fold.
///
/// The input is a parsed status (its own tests live in `git_status_test.dart`),
/// and what is checked here is the MATCHING: a file's own path, a directory's
/// subtree, and the boundary cases that make a highlight lie — `foo` lit up by
/// `foobar/x.txt`, or a path spelled relative to the wrong root.
GitEntry ordinary(String status, String path) => GitEntry(
      path: path,
      index: GitState(status[0]),
      worktree: GitState(status[1]),
      rawStatus: status,
    );

GitEntry untracked(String path) => GitEntry(
      path: path,
      index: GitState('?'),
      worktree: GitState(GitState.clean),
      rawStatus: '?',
    );

GitEntry renamed(String path, String original) => GitEntry(
      path: path,
      originalPath: original,
      index: GitState('R'),
      worktree: GitState(GitState.clean),
      rawStatus: 'R.',
    );

GitEntry conflicted(String path) => GitEntry(
      path: path,
      index: GitState.forced('U', GitChangeKind.conflicted),
      worktree: GitState.forced('U', GitChangeKind.conflicted),
      rawStatus: 'UU',
    );

void main() {
  const root = '/repo';

  GitTreeMarks marksFor(List<GitEntry> entries) =>
      GitTreeMarks.forStatus(root: root, entries: entries);

  GitTreeMark? fileAt(GitTreeMarks marks, String name, {String dir = root}) =>
      marks.markFor(dir, name, isDirectory: false);

  GitTreeMark? dirAt(GitTreeMarks marks, String name, {String dir = root}) =>
      marks.markFor(dir, name, isDirectory: true);

  group('files', () {
    test("a modified file carries git's own letter", () {
      final marks = marksFor([ordinary('.M', 'edited.txt')]);

      final mark = fileAt(marks, 'edited.txt');

      expect(mark, isNotNull);
      expect(mark!.kind, GitChangeKind.modified);
      expect(mark.letter, 'M');
    });

    test('an untracked file is a question mark, not a made-up word', () {
      final mark = fileAt(marksFor([untracked('new.txt')]), 'new.txt');

      expect(mark!.kind, GitChangeKind.untracked);
      expect(mark.letter, '?');
    });

    test('a file staged AND modified shows one mark, and "added" wins', () {
      // `AM`: added to the index, edited again since. One glyph has to stand
      // for both, and what the reader needs to know is that the file is NEW.
      final mark = fileAt(marksFor([ordinary('AM', 'both.txt')]), 'both.txt');

      expect(mark!.kind, GitChangeKind.added);
      expect(mark.letter, 'A');
    });

    test('a conflict outranks a modification on the other side', () {
      final mark = fileAt(marksFor([conflicted('clash.txt')]), 'clash.txt');

      expect(mark!.kind, GitChangeKind.conflicted);
      expect(mark.letter, 'U');
    });

    test('a letter this build cannot read is carried verbatim', () {
      // The same fail-closed rule as the status list: an unknown letter is
      // shown, never folded into "modified".
      final mark = fileAt(marksFor([ordinary('.Q', 'mystery.txt')]), 'mystery.txt');

      expect(mark!.kind, GitChangeKind.unrecognised);
      expect(mark.letter, 'Q');
    });

    test('a file that is clean on BOTH sides has no mark at all', () {
      // `..` is git's "unchanged on both sides". It reaches the fold only if
      // something odd produced such an entry, and even then it must not paint a
      // row: `.` is not a change, which is the distinction the status parser
      // makes between "nothing here" and "I could not tell".
      final marks = marksFor([ordinary('..', 'plain.txt')]);

      expect(fileAt(marks, 'plain.txt'), isNull);
    });
  });

  group('directories', () {
    test('a directory containing a change is marked, without a letter', () {
      final marks = marksFor([ordinary('.M', 'src/inner.txt')]);

      final mark = dirAt(marks, 'src');

      expect(mark, isNotNull);
      expect(mark!.kind, GitChangeKind.modified);
      // A directory is not itself modified: it CONTAINS changes, and the UI
      // draws that as a dot rather than claiming a file's letter.
      expect(mark.letter, isNull);
    });

    test('every ancestor is marked, not just the parent', () {
      final marks = marksFor([ordinary('.M', 'a/b/c/deep.txt')]);

      expect(dirAt(marks, 'a'), isNotNull);
      expect(dirAt(marks, 'b', dir: '$root/a'), isNotNull);
      expect(dirAt(marks, 'c', dir: '$root/a/b'), isNotNull);
      // And the lookup is not a scan: `c` is not a child of `a`.
      expect(dirAt(marks, 'c', dir: root), isNull);
    });

    test('a sibling with a SHARED PREFIX is not marked', () {
      // The classic string-prefix bug: `foo` must not light up because
      // `foobar/x.txt` changed. The fold walks path components, so the two are
      // never compared as strings.
      final marks = marksFor([ordinary('.M', 'foobar/x.txt')]);

      expect(dirAt(marks, 'foobar'), isNotNull);
      expect(dirAt(marks, 'foo'), isNull);
    });

    test('a rename marks the directory it left as well as the one it entered',
        () {
      final marks = marksFor([renamed('b/moved.txt', 'a/moved.txt')]);

      expect(dirAt(marks, 'b'), isNotNull);
      expect(dirAt(marks, 'a'), isNotNull);
      expect(fileAt(marks, 'moved.txt', dir: '$root/b'), isNotNull);
      // The old path is not a file any more; only its directory remembers it.
      expect(fileAt(marks, 'moved.txt', dir: '$root/a'), isNull);
    });

    test('a directory inherits the STRONGEST kind underneath it', () {
      final marks = marksFor([
        untracked('mix/new.txt'),
        ordinary('.M', 'mix/edited.txt'),
        ordinary('.D', 'mix/gone.txt'),
      ]);

      // Deleted outranks modified outranks untracked: the dot is red because a
      // file under this directory is gone, which is the thing worth noticing.
      expect(dirAt(marks, 'mix')!.kind, GitChangeKind.deleted);
    });
  });

  group('the boundary between the listing and the repository', () {
    test('a directory that is not inside the repository has no marks', () {
      final marks = marksFor([ordinary('.M', 'edited.txt')]);

      expect(marks.markFor('/tmp/elsewhere', 'edited.txt', isDirectory: false),
          isNull);
    });

    test('a path with the root as a STRING PREFIX is not inside the root', () {
      // `/repo-other` starts with `/repo`, and the naive prefix test would
      // happily answer about a tree it knows nothing about.
      final marks = marksFor([ordinary('.M', 'edited.txt')]);

      expect(
        marks.markFor('/repo-other', 'edited.txt', isDirectory: false),
        isNull,
      );
    });

    test("browsing a subdirectory looks up that directory's children", () {
      final marks = marksFor([ordinary('.M', 'src/inner.txt')]);

      expect(
        marks.markFor('$root/src', 'inner.txt', isDirectory: false),
        isNotNull,
      );
      // And the same name at the root is NOT that file.
      expect(marks.markFor(root, 'inner.txt', isDirectory: false), isNull);
    });

    test('the empty set answers null for everything', () {
      final marks = GitTreeMarks.empty();

      expect(marks.markFor(root, 'anything', isDirectory: false), isNull);
      expect(marks.markFor(root, 'anything', isDirectory: true), isNull);
    });
  });
}
