import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/menu.dart';

/// The rules that decide when `/` and `@` open a menu, and what they show.
///
/// Worth pinning because they are the part of the composer that replaces
/// something the terminal does by itself. The TUI pops its own menu when it SEES
/// the slash; a composer sends one paste, so the menu has to be drawn here — and
/// a trigger that fires inside a URL, a path or an email address makes typing an
/// ordinary sentence impossible.
void main() {
  group('when a trigger opens', () {
    test('at the start of an empty draft', () {
      final token = readMenuToken(text: '/', caret: 1);
      expect(token?.trigger, MenuTrigger.slash);
      expect(token?.query, '');
    });

    test('after a space', () {
      final token = readMenuToken(text: 'please /cod', caret: 11);
      expect(token?.query, 'cod');
      expect(token?.start, 7);
    });

    test('what has been typed filters the menu', () {
      expect(readMenuToken(text: '/code-review', caret: 12)?.query, 'code-review');
      // Caret in the middle: the query is only what is behind it.
      expect(readMenuToken(text: '/code-review', caret: 5)?.query, 'code');
    });

    test('NOT in the middle of a word', () {
      expect(readMenuToken(text: 'src/foo', caret: 7), isNull);
      expect(readMenuToken(text: 'someone@host', caret: 12), isNull);
    });

    test('NOT inside a URL', () {
      // Three spellings, all of them things people paste into a prompt.
      expect(readMenuToken(text: 'https://a.com/b', caret: 15), isNull);
      expect(readMenuToken(text: 'see https://x', caret: 13), isNull);
      expect(readMenuToken(text: 'a // b', caret: 6), isNull);
    });

    test('NOT after a Chinese word, which is a word', () {
      // `[a-z0-9_]` would call 好 punctuation and open a menu in the middle of a
      // Chinese sentence — in the language this app defaults to.
      expect(readMenuToken(text: '请看看/foo', caret: 7), isNull);
    });

    test('a slash after punctuation does open', () {
      expect(readMenuToken(text: '好的，/co', caret: 6)?.query, 'co');
    });

    test('the trigger nearest the caret is the one that counts', () {
      // The `/` in `src/` is mid-word and dead; the one just typed is live.
      const line = 'look at src/x then /rev';
      final token = readMenuToken(text: line, caret: line.length);
      expect(token?.query, 'rev');
      expect(token?.start, line.indexOf('/rev'));
    });

    test('a caret outside the text is not a trigger', () {
      expect(readMenuToken(text: '/a', caret: 9), isNull);
      expect(readMenuToken(text: '/a', caret: -1), isNull);
    });

    test('@ is the same rule with a different character', () {
      expect(readMenuToken(text: '@lib/', caret: 5)?.trigger, MenuTrigger.at);
      expect(readMenuToken(text: '@lib/', caret: 5)?.query, 'lib/');
      // A path with a slash in it does not turn into a skills menu.
      expect(readMenuToken(text: '@lib/x', caret: 6)?.trigger, MenuTrigger.at);
    });
  });

  group('when a token does NOT open a menu', () {
    MenuToken tokenFor(String text) => readMenuToken(
      text: text,
      caret: text.length,
    )!;

    test('a slash with another slash in it is a PATH', () {
      // `cd /usr/local` popped the skills list, and so did every absolute path
      // anybody typed into a message. No skill is called `usr/local`.
      expect(
        shouldOpenMenu(tokenFor('cd /usr/local'), agentPane: true),
        isFalse,
      );
      expect(
        shouldOpenMenu(tokenFor('/etc/hosts'), agentPane: true),
        isFalse,
      );
      // A plain command is still a command.
      expect(
        shouldOpenMenu(tokenFor('/code-review'), agentPane: true),
        isTrue,
      );
    });

    test('a pane with no agent has no skills', () {
      // `pane.list` leaves `agent` empty for a plain shell (measured on herdr
      // 0.9.0), and `/` there is a path separator. Offering a skills menu in a
      // shell is offering a menu of things that shell cannot do.
      expect(
        shouldOpenMenu(tokenFor('/code-review'), agentPane: false),
        isFalse,
      );
    });

    test('@ is NOT suppressed in a shell', () {
      // A file reference is useful in a shell too — what changes is what a pick
      // inserts, not whether the list opens.
      expect(
        shouldOpenMenu(tokenFor('cat @lib'), agentPane: false),
        isTrue,
      );
    });

    test('what a picked file becomes depends on the pane', () {
      expect(fileReferenceText('lib/main.dart', agentPane: true), '@lib/main.dart');
      expect(
        fileReferenceText('lib/main.dart', agentPane: false),
        'lib/main.dart',
        reason: 'a shell resolves no mention syntax',
      );
    });
  });

  group('picking a row', () {
    test('the token is replaced and a space ends it', () {
      final token = readMenuToken(text: '/cod', caret: 4)!;
      final result = applyPick(text: '/cod', token: token, pick: 'code-review');
      expect(result.text, 'code-review ');
      // The space is what closes the menu: the caret is past the token, so the
      // next keystroke is ordinary text rather than another query.
      expect(readMenuToken(text: result.text, caret: result.caret), isNull);
    });

    test('text around the token is kept, without a doubled space', () {
      final token = readMenuToken(text: 'run /te then stop', caret: 7)!;
      final result = applyPick(
        text: 'run /te then stop',
        token: token,
        pick: '/test',
      );
      expect(result.text, 'run /test then stop');
      expect(result.caret, 9);
    });

    test('a file reference keeps its @', () {
      final token = readMenuToken(text: '@lib/ma', caret: 7)!;
      final result = applyPick(text: '@lib/ma', token: token, pick: '@lib/main.dart');
      expect(result.text, '@lib/main.dart ');
    });
  });

  group('ranking the candidates', () {
    String name(String value) => value;

    test('an empty query leaves the list alone', () {
      final items = ['b', 'a'];
      expect(rankByName(items, '', name), items);
    });

    test('a prefix beats a match further in', () {
      expect(
        rankByName(['unrelated-code', 'code-review'], 'code', name),
        ['code-review', 'unrelated-code'],
      );
    });

    test('an ordered subsequence matches', () {
      final ranked = rankByName(
        ['code-review', 'cloudflare-one', 'customs'],
        'crv',
        name,
      );
      expect(ranked.first, 'code-review');
    });

    test('a character out of order does not match', () {
      expect(rankByName(['code-review'], 'rvc', name), isEmpty);
    });

    test('matching ignores case', () {
      expect(rankByName(['Code-Review'], 'code', name), ['Code-Review']);
    });

    test('ties keep the order they arrived in', () {
      // The catalogue's own order is stable, so an empty-ish query does not
      // reshuffle a list the user was about to tap.
      expect(
        rankByName(['aa', 'ab', 'ac'], 'a', name),
        ['aa', 'ab', 'ac'],
      );
    });

    test('a separator boundary scores like a word start', () {
      expect(
        rankByName(['xx-yy', 'xxayy'], 'yy', name).first,
        'xx-yy',
      );
    });
  });
}
