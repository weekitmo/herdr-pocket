import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/composer.dart';

/// How the phone's keyboard is read.
///
/// The bug these rules exist for was invisible in a widget test and in a demo:
/// the field was cleared after every keystroke, so pressing delete produced no
/// edit at all, and the terminal's own input line could not be corrected. Every
/// case below is about a keystroke that has to survive that.
void main() {
  group('typing', () {
    test('what was typed beyond the sentinel is the text', () {
      final edit = ComposerBuffer.read(text: '  ls', composing: false);
      expect(edit, isA<ComposerTyped>());
      expect((edit as ComposerTyped).text, 'ls');
    });

    test('a whole line typed in one report arrives whole', () {
      // A fast typist, or a paste. The IME reports the field's new contents, not
      // the keystrokes, so this is the normal shape of a paste.
      final edit = ComposerBuffer.read(text: '  git status', composing: false);
      expect((edit as ComposerTyped).text, 'git status');
    });
  });

  group('backspace', () {
    test('one character deleted is one DEL', () {
      // THE USER'S BUG. One space left where the sentinel had two: the keyboard
      // deleted a character, and the terminal has to hear about it even though
      // the field is — as far as the app is concerned — empty.
      final edit = ComposerBuffer.read(text: ' ', composing: false);
      expect(edit, isA<ComposerDeleted>());
      expect((edit as ComposerDeleted).count, 1);
    });

    test('a wiped field is counted, not guessed', () {
      final edit = ComposerBuffer.read(text: '', composing: false);
      expect((edit as ComposerDeleted).count, 2);
    });

    test('the sentinel itself is not an edit', () {
      expect(
        ComposerBuffer.read(text: kComposerSentinel, composing: false),
        isA<ComposerNothing>(),
      );
    });
  });

  group('composition', () {
    test('nothing is sent while the IME is composing', () {
      // Pinyin in progress: `ni` is not what the user means to type, and a shell
      // that received it would have a command line full of letters nobody chose.
      expect(
        ComposerBuffer.read(text: '  ni', composing: true),
        isA<ComposerComposing>(),
      );
    });

    test('the committed text is sent once the composition ends', () {
      final edit = ComposerBuffer.read(text: '  你好', composing: false);
      expect((edit as ComposerTyped).text, '你好');
    });
  });

  group('resetting', () {
    test('anything that is not the sentinel is put back', () {
      expect(ComposerBuffer.needsReset(text: '  a', composing: false), isTrue);
      expect(ComposerBuffer.needsReset(text: ' ', composing: false), isTrue);
    });

    test('a field already at rest is left alone', () {
      // Asking the keyboard to re-set the same value would be a round trip per
      // keystroke for no change, and some IMEs answer it by re-announcing the
      // same edit.
      expect(
        ComposerBuffer.needsReset(text: kComposerSentinel, composing: false),
        isFalse,
      );
    });

    test('a live composition is NEVER reset', () {
      // Resetting the editing state mid-composition destroys the composing
      // region: the candidate window stays open over nothing.
      expect(ComposerBuffer.needsReset(text: '  ni', composing: true), isFalse);
    });
  });
}
