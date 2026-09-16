import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/git/git_diff.dart';

/// Tests for the unified diff parser.
///
/// The diff text below is REAL output, captured on this machine (git 2.53.0,
/// macOS) from a scratch repository with:
///
/// ```sh
/// git -C /tmp/gitcap diff --no-color --patch -- renamed.txt
/// git -C /tmp/gitcap diff --no-color --patch --cached -- staged.txt
/// ```
///
/// The parser exists because the alternative — running `git diff --color=always`
/// and putting ANSI on screen — would make the hue a subprocess's opinion about
/// a terminal instead of a property of this app's palette. Everything below is
/// about proving the plain form carries enough structure to style it.
void main() {
  group('hunks', () {
    test('a modified file has one hunk with context, an addition and a removal',
        () {
      const raw = 'diff --git a/renamed.txt b/renamed.txt\n'
          'index 45b983b..00455c6 100644\n'
          '--- a/renamed.txt\n'
          '+++ b/renamed.txt\n'
          '@@ -1 +1,3 @@\n'
          ' hi\n'
          '+mod\n'
          '+more\n';

      final diff = GitDiff.parse(raw);

      expect(diff.isEmpty, isFalse);
      expect(diff.hunks, hasLength(1));
      expect(diff.addedCount, 2);
      expect(diff.removedCount, 0);

      final hunk = diff.hunks.single;
      expect(hunk.lines.map((l) => l.type).toList(), [
        GitDiffLineType.context,
        GitDiffLineType.added,
        GitDiffLineType.added,
      ]);
      // The marker is stripped by the PARSER, so the renderer never re-derives
      // it and cannot get it wrong.
      expect(hunk.lines.first.text, 'hi');
      expect(hunk.lines.last.text, 'more');
    });

    test('the preamble is folded into the hunk header, not dropped', () {
      // "Which file is this, and how did it change mode" is the first question
      // anyone asks of a diff, and it lives in these lines.
      const raw = 'diff --git a/a.txt b/a.txt\n'
          'new file mode 100644\n'
          'index 0000000..19d9cc8\n'
          '--- /dev/null\n'
          '+++ b/a.txt\n'
          '@@ -0,0 +1 @@\n'
          '+staged\n';

      final header = GitDiff.parse(raw).hunks.single.header;

      expect(header, contains('diff --git a/a.txt b/a.txt'));
      expect(header, contains('new file mode 100644'));
      expect(header, contains('@@ -0,0 +1 @@'));
    });

    test('line numbers are tracked per side', () {
      // A real gutter needs both counters, and they diverge at the first
      // removal — which is exactly where a single running count goes wrong.
      const raw = '@@ -10,3 +10,3 @@\n'
          ' context\n'
          '-gone\n'
          '+new\n';

      final lines = GitDiff.parse(raw).hunks.single.lines;

      expect((lines[0].oldLine, lines[0].newLine), (10, 10));
      expect(lines[1].type, GitDiffLineType.removed);
      expect((lines[1].oldLine, lines[1].newLine), (11, null));
      expect(lines[2].type, GitDiffLineType.added);
      expect((lines[2].oldLine, lines[2].newLine), (null, 11));
    });

    test('several hunks stay separate and in order', () {
      const raw = '@@ -1,2 +1,2 @@\n'
          ' a\n'
          '-b\n'
          '+B\n'
          '@@ -20,2 +20,2 @@\n'
          ' c\n'
          '-d\n'
          '+D\n';

      final diff = GitDiff.parse(raw);

      expect(diff.hunks, hasLength(2));
      expect(diff.hunks.first.header, '@@ -1,2 +1,2 @@');
      expect(diff.hunks.last.header, '@@ -20,2 +20,2 @@');
      expect(diff.hunks.first.lines, hasLength(3));
    });

    test('a hunk header keeps its trailing function context', () {
      const raw = '@@ -31,7 +31,9 @@ void main() {\n'
          ' }\n';

      expect(
        GitDiff.parse(raw).hunks.single.header,
        '@@ -31,7 +31,9 @@ void main() {',
      );
    });
  });

  group('awkward input', () {
    test('no newline at end of file is a meta line, not content', () {
      const raw = '@@ -1 +1 @@\n'
          '-old\n'
          '\\ No newline at end of file\n'
          '+new\n';

      final lines = GitDiff.parse(raw).hunks.single.lines;

      expect(lines[1].type, GitDiffLineType.meta);
      expect(lines[1].text, r'\ No newline at end of file');
      // It must NOT be counted as a removal or an addition.
      expect(GitDiff.parse(raw).removedCount, 1);
      expect(GitDiff.parse(raw).addedCount, 1);
    });

    test('an empty diff is empty, not an error', () {
      expect(GitDiff.parse('').isEmpty, isTrue);
      expect(GitDiff.parse('').hunks, isEmpty);
    });

    test('a mode-only change has no hunks and reports empty', () {
      // `git diff` prints the preamble and two mode lines and NOTHING else when
      // only the mode changed. There is no text to show, and that is a fact
      // about the change rather than a parse failure.
      const raw = 'diff --git a/x.sh b/x.sh\n'
          'old mode 100644\n'
          'new mode 100755\n';

      expect(GitDiff.parse(raw).isEmpty, isTrue);
    });

    test('a CRLF file keeps its carriage returns', () {
      // Stripping them would make the diff disagree with the file it claims to
      // describe, which is worse than a stray glyph.
      const raw = '@@ -1 +1 @@\n'
          '-a\r\n'
          '+b\r\n';

      final lines = GitDiff.parse(raw).hunks.single.lines;

      expect(lines[0].text, 'a\r');
      expect(lines[1].text, 'b\r');
    });

    test('an added line whose content starts with a plus is not double-stripped',
        () {
      // `++i` is an added line whose text is `+i`. Stripping every leading `+`
      // would silently change the code being shown.
      const raw = '@@ -1 +1,2 @@\n'
          ' x\n'
          '++i;\n';

      expect(GitDiff.parse(raw).hunks.single.lines.last.text, '+i;');
    });

    test('a context line that is only whitespace survives', () {
      const raw = '@@ -1,2 +1,2 @@\n'
          ' \n'
          ' a\n';

      final lines = GitDiff.parse(raw).hunks.single.lines;

      expect(lines.first.type, GitDiffLineType.context);
      expect(lines.first.text, '');
    });

    test('CJK content survives byte for byte', () {
      const raw = '@@ -1 +1,2 @@\n'
          ' 你好\n'
          '+世界\n';

      final lines = GitDiff.parse(raw).hunks.single.lines;

      expect(lines[0].text, '你好');
      expect(lines[1].text, '世界');
    });

    test('a file whose name is mentioned in a hunk header is not confused',
        () {
      const raw = 'diff --git a/a b/a b\n'
          '--- a/a b/a b\n'
          '+++ b/a b/a b\n'
          '@@ -1 +1 @@\n'
          '-one\n'
          '+two\n';

      final diff = GitDiff.parse(raw);

      expect(diff.hunks, hasLength(1));
      expect(diff.hunks.single.lines, hasLength(2));
    });
  });
}
