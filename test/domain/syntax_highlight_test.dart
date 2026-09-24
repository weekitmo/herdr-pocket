import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/highlight/syntax.dart';

/// Tests for tokenising a whole file into runs, per line.
///
/// The reason this is not a loop over lines is the reason this file exists: a
/// block comment, a triple-quoted string and a heredoc all START on one line and
/// END on another, and a per-line tokeniser restarts in a fresh state each time
/// — so the second line of a comment comes back as code with keywords in it. The
/// failure is loud in a screenshot and invisible in a diff, which is the wrong
/// way round.
void main() {
  group('highlightLines', () {
    test('a file with no grammar is one plain run per line', () {
      final lines = highlightLines('one\ntwo\nthree\n', null);
      expect(lines.length, 3);
      expect(lines.map((l) => l.plainText), ['one', 'two', 'three']);
      for (final line in lines) {
        expect(line.runs.single.role, CodeRole.plain);
      }
    });

    test('a name with no grammar in the registry is also plain', () {
      final lines = highlightLines('def f():\n    pass\n', 'nosuchlanguage');
      expect(lines.length, 2);
      expect(lines.first.runs.first.role, CodeRole.plain);
    });

    test('a block comment keeps its role on the lines it spans', () {
      // The worked example: line two of a C-style comment is still a comment,
      // and it is the line a per-line tokeniser gets wrong.
      final lines = highlightLines(
        'int a = 1;\n/* first\n   second */\nint b = 2;\n',
        'cpp',
      );
      expect(lines.length, 4);
      expect(lines[0].runs.any((r) => r.role == CodeRole.keyword), isTrue);
      expect(
        lines[1].runs.single.role,
        CodeRole.comment,
        reason: 'the comment opens on this line',
      );
      expect(
        lines[2].runs.single.role,
        CodeRole.comment,
        reason: 'and it is still open on the next one',
      );
      expect(lines[2].runs.single.italic, isTrue);
      expect(
        lines[3].runs.any((r) => r.role == CodeRole.keyword),
        isTrue,
        reason: 'and it is closed by the time this line starts',
      );
    });

    test('a triple-quoted string spans lines too', () {
      final lines = highlightLines('x = """a\nb"""\ny = 2\n', 'python');
      expect(lines.length, 3);
      expect(lines[0].runs.last.role, CodeRole.string);
      expect(lines[1].runs.single.role, CodeRole.string);
      expect(lines[2].runs.any((r) => r.role == CodeRole.number), isTrue);
    });

    test('a nested keyword inside a comment stays italic', () {
      // Emphasis and colour come from different places and compose: the class
      // that made the comment italic is not undone by the class that colours
      // one word inside it.
      final lines = highlightLines('/// A doc comment\n', 'dart');
      expect(lines.single.runs.single.role, CodeRole.comment);
      expect(lines.single.runs.single.italic, isTrue);
    });

    test('the line count agrees with the text, every way a file can end', () {
      // A gutter that numbers one line more than the file has is the visible
      // symptom of the run list and the text disagreeing, so the two are
      // asserted against each other rather than each against a number.
      for (final source in const [
        '',
        'a',
        'a\n',
        'a\n\n',
        '\n',
        'a\n\n\nb\n',
        'a\nb',
      ]) {
        final expected = splitSourceLines(source);
        final lines = highlightLines(source, 'dart');
        expect(
          lines.map((l) => l.plainText).toList(),
          expected,
          reason: 'source: ${source.replaceAll('\n', r'\n')}',
        );
      }
    });

    test('an empty file has no lines at all', () {
      expect(highlightLines('', 'dart'), isEmpty);
    });

    test('a blank line is an empty run list, not a missing entry', () {
      final lines = highlightLines('a\n\n\nb\n', null);
      expect(lines.length, 4);
      expect(lines[1].runs, isEmpty);
      expect(lines[2].runs, isEmpty);
    });

    test('runs never contain the newline that ended their line', () {
      final lines = highlightLines('class A {}\nclass B {}\n', 'dart');
      for (final line in lines) {
        for (final run in line.runs) {
          expect(run.text.contains('\n'), isFalse, reason: run.text);
        }
      }
    });

    test('the same source parses to the same runs twice', () {
      // The result is computed in an isolate and applied to state; a rebuild
      // must not be able to produce a different picture.
      const source = 'class A {\n  final int x = 1;\n}\n';
      final first = highlightLines(source, 'dart');
      final second = highlightLines(source, 'dart');
      expect(first.length, second.length);
      for (var i = 0; i < first.length; i++) {
        expect(first[i].runs, second[i].runs);
      }
    });
  });

  group('registered grammar contract', () {
    test('every language the file table names is registered', () {
      // The other half of `source_language_test`'s guard, from this side: if a
      // grammar is dropped from the registry, the file table's values stop
      // resolving and this is where it is noticed.
      expect(hasGrammar('python'), isTrue);
      expect(hasGrammar('py'), isTrue, reason: 'aliases count');
      expect(hasGrammar('Dockerfile'), isTrue, reason: 'case-insensitive');
      expect(hasGrammar('sh'), isTrue);
      expect(hasGrammar('nope'), isFalse);
      expect(hasGrammar(null), isFalse);
    });

    test('the registry carries the languages a repository actually holds', () {
      // Not a count — a count would be re-pinned on every addition and would
      // never fail for the reason it exists. These are the ones the user named,
      // plus the ones that show up beside them.
      for (final id in const [
        'json',
        'yaml',
        'dockerfile',
        'typescript',
        'javascript',
        'go',
        'rust',
        'cs',
        'python',
        'dart',
        'bash',
        'sql',
        'toml',
        'swift',
        'kotlin',
        'ruby',
        'php',
        'java',
        'cpp',
        'html',
        'css',
        'scss',
        'lua',
        'perl',
        'powershell',
        'protobuf',
        'graphql',
        'gradle',
        'cmake',
        'nginx',
        'markdown',
        'diff',
      ]) {
        expect(hasGrammar(id), isTrue, reason: '$id is not registered');
        expect(
          registeredLanguages.contains(highlightLanguageId(id)),
          isTrue,
          reason: '$id resolved to a canonical name that is not registered',
        );
      }
    });
  });
}
