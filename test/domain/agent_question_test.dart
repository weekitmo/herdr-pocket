import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_question.dart';

/// Reading a question out of somebody else's TUI.
///
/// Every fixture below is a shape a real agent actually draws. The tests exist
/// because the failure mode here is not "a blank card" — it is pressing the
/// WRONG key on a live agent, so most of them are about refusing to guess.
void main() {
  group('numbered menu (Claude Code permission prompt)', () {
    const screen = [
      '╭──────────────────────────────────────────────────╮',
      '│ Bash command                                     │',
      '│                                                  │',
      '│   rm -rf build                                   │',
      '│   Clean the build directory                      │',
      '│                                                  │',
      '│ Do you want to proceed?                          │',
      '│ ❯ 1. Yes                                         │',
      "│   2. Yes, and don't ask again for rm commands    │",
      '│   3. No, and tell Claude what to do differently  │',
      '╰──────────────────────────────────────────────────╯',
    ];

    test('finds the question, not the command', () {
      final q = parseAgentQuestion(screen);
      expect(q.prompt, 'Do you want to proceed?');
      expect(q.confidence, QuestionConfidence.high);
    });

    test('reads all three options and marks the cursor', () {
      final q = parseAgentQuestion(screen);
      expect(q.options.map((o) => o.key), ['1', '2', '3']);
      expect(q.options.first.label, 'Yes');
      expect(q.options.first.isCursor, isTrue);
      expect(q.options[1].isCursor, isFalse);
    });

    test('a menu option is a keystroke, not a line to submit', () {
      // Pressing the digit is the whole answer. Adding Enter would confirm a
      // second time — against whatever the agent shows next.
      final q = parseAgentQuestion(screen);
      expect(q.options.every((o) => !o.needsEnter), isTrue);
    });

    test('is actionable', () {
      expect(parseAgentQuestion(screen).isActionable, isTrue);
    });
  });

  group('chrome handling', () {
    test('drops the agent status bar below the prompt', () {
      // The real pi footer, measured on a live pane. Leaving it in makes the
      // card look broken rather than informative.
      final q = parseAgentQuestion([
        'Do you want to proceed?',
        '❯ 1. Yes',
        '  2. No',
        '[gw-ai-openai/deepseek-flash @max]  Apps/my-project  main',
        '↑0 ↓0  TTFB 0s  0 tok/s  t0/s0',
      ]);
      expect(q.prompt, 'Do you want to proceed?');
      expect(q.options.length, 2);
      expect(q.rawLines, isNot(contains(contains('tok/s'))));
    });

    test('strips ANSI colour codes', () {
      final q = parseAgentQuestion([
        '\u001B[1mDo you want to proceed?\u001B[0m',
        '\u001B[36m❯ 1. Yes\u001B[0m',
        '\u001B[36m  2. No\u001B[0m',
      ]);
      expect(q.prompt, 'Do you want to proceed?');
      expect(q.options.first.label, 'Yes');
    });

    test('blanks private-use glyphs instead of showing half-width kana', () {
      final q = parseAgentQuestion([
        'Do you want to proceed? \uE0B0',
        '❯ 1. Yes',
        '  2. No',
      ]);
      expect(q.prompt, isNotNull);
      expect(q.prompt, isNot(contains('\uE0B0')));
    });

    test('trailing blank lines do not defeat the walk', () {
      final q = parseAgentQuestion([
        'Proceed?',
        '❯ 1. Yes',
        '  2. No',
        '',
        '',
      ]);
      expect(q.options.length, 2);
      expect(q.confidence, QuestionConfidence.high);
    });
  });

  group('inline yes/no', () {
    const screen = [
      'Build finished with 3 warnings.',
      'Do you want to continue? (y/n)',
    ];

    test('parses both letters', () {
      final q = parseAgentQuestion(screen);
      expect(q.isYesNo, isTrue);
      expect(q.options.map((o) => o.key), ['y', 'n']);
    });

    test('the letter needs a return, unlike a menu digit', () {
      // A raw `(y/n)` sits in the line discipline: the letter does nothing
      // until Enter arrives.
      final q = parseAgentQuestion(screen);
      expect(q.options.every((o) => o.needsEnter), isTrue);
    });

    test('the question is the line the options ride on', () {
      expect(parseAgentQuestion(screen).prompt, 'Do you want to continue? (y/n)');
    });

    test('understands square brackets', () {
      final q = parseAgentQuestion(['Overwrite the file? [y/N]']);
      expect(q.options.map((o) => o.key), ['y', 'n']);
      expect(q.confidence, QuestionConfidence.high);
    });
  });

  group('refuses to guess', () {
    test('a numbered list in the agent prose is not a menu', () {
      // THE dangerous false positive: answering "1" here would type a stray
      // digit into the composer of an agent that is not asking anything.
      final q = parseAgentQuestion([
        'Here is what I did:',
        '1. Read the config',
        '2. Updated the parser',
        '3. Ran the test suite',
        'All tests pass.',
      ]);
      expect(q.confidence, QuestionConfidence.none);
      expect(q.options, isEmpty);
      expect(q.isActionable, isFalse);
    });

    test('a question with no options is not actionable', () {
      final q = parseAgentQuestion(['What would you like me to do next?']);
      expect(q.confidence, QuestionConfidence.low);
      expect(q.isActionable, isFalse);
      expect(q.summary, 'What would you like me to do next?');
    });

    test('an empty screen yields nothing', () {
      final q = parseAgentQuestion(const []);
      expect(q.confidence, QuestionConfidence.none);
      expect(q.rawLines, isEmpty);
      expect(q.summary, isNull);
    });

    test('a bare number at line start is not an option', () {
      // `2026-09-14` must not become option 2026, and `80 columns` must not
      // become option 80.
      final q = parseAgentQuestion(['2026-09-14 release notes', '80 columns wide']);
      expect(q.options, isEmpty);
      expect(q.confidence, QuestionConfidence.none);
    });
  });

  group('raw lines are always there', () {
    test('the fallback keeps the last few real lines', () {
      // Even when nothing is understood, the user gets to read the screen.
      final q = parseAgentQuestion([
        'line one',
        'line two',
        'line three',
        'line four',
        'line five',
        'line six',
        'line seven',
        'Chrome: 12 tok/s',
      ]);
      expect(q.confidence, QuestionConfidence.none);
      expect(q.rawLines.length, 6);
      expect(q.rawLines.last, 'line seven');
      expect(q.rawLines, isNot(contains(contains('tok/s'))));
    });

    test('summary collapses whitespace and caps length', () {
      final q = parseAgentQuestion([
        'Do you want to proceed with   the  refactor?',
        '❯ 1. Yes',
        '  2. No',
      ]);
      expect(q.summary, 'Do you want to proceed with the refactor?');
    });
  });
}
