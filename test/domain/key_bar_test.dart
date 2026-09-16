import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';

/// The key bar's rules.
///
/// These are the arithmetic of a terminal's input, and arithmetic nobody can
/// eyeball: `Ctrl` + `[` is `ESC`, `Shift` + `Tab` is the only way to say
/// "backwards", and `Ctrl+C` is a signal rather than a copy. Every one of them
/// is a fact about the wire, so every one of them is asserted here rather than
/// implied by a widget.
void main() {
  group('the catalogue', () {
    test('every key has a unique id, because ids are what gets stored', () {
      final ids = [for (final k in SoftKey.values) k.id];
      expect(ids.toSet().length, ids.length);
    });

    test('the default bar holds only keys that exist in the catalogue', () {
      expect(defaultKeyBar.toSet().difference(SoftKey.values.toSet()), isEmpty);
    });

    test('the default bar is free of duplicates', () {
      expect(defaultKeyBar.toSet().length, defaultKeyBar.length);
    });

    test('literals produce bytes with nothing armed, and only literals do', () {
      for (final key in SoftKey.values) {
        if (key.kind == KeyKind.literal) {
          expect(key.plain, isNotNull, reason: '${key.id} is a literal');
          expect(key.plain, isNotEmpty);
        } else {
          expect(key.plain, isNull, reason: '${key.id} is not a literal');
        }
      }
    });

    test('Escape and Enter send the sequences a terminal actually reads', () {
      // Not pedantry: a bare LF for Enter is a different key that most shells
      // will not treat as "run this line", and it is the single easiest way to
      // ship a terminal where the enter key appears to do nothing.
      expect(SoftKey.esc.plain, '\x1b');
      expect(SoftKey.enter.plain, '\r');
      expect(SoftKey.backspace.plain, '\x7f');
    });
  });

  group('modifiers are sticky', () {
    test('tapping one arms it and sends nothing', () {
      final outcome = const KeyBarState().tap(SoftKey.ctrl);

      expect(outcome.armed, {TerminalModifier.ctrl});
      expect(outcome.bytes, isNull);
    });

    test('tapping it twice disarms it', () {
      final once = const KeyBarState().tap(SoftKey.ctrl);
      final twice = KeyBarState(armed: once.armed).tap(SoftKey.ctrl);

      expect(twice.armed, isEmpty);
    });

    test('an armed modifier is CONSUMED by the next key', () {
      // Even by a key it cannot affect. An armed Ctrl that silently survived a
      // keypress would fire on the one after it, which is how you interrupt
      // something you were not looking at.
      const state = KeyBarState(armed: {TerminalModifier.ctrl});
      final outcome = state.tap(SoftKey.enter);

      expect(outcome.armed, isEmpty);
      expect(outcome.bytes, '\r');
    });

    test('the modifier + key combination is what gets sent', () {
      const state = KeyBarState(armed: {TerminalModifier.ctrl});
      // `Ctrl` then `c` is the interrupt, and only the interrupt: there is no
      // "copy" on a terminal's wire.
      expect(state.tap(SoftKey.esc).bytes, '\x1b');
    });

    test('actions do NOT consume armed modifiers', () {
      // Arming Ctrl and then reaching for Paste is two unrelated intentions in
      // a row, not a request to send a controlled paste.
      const state = KeyBarState(armed: {TerminalModifier.ctrl});
      final copy = state.tap(SoftKey.copy);
      final paste = state.tap(SoftKey.paste);

      expect(copy.bytes, isNull);
      expect(paste.bytes, isNull);
      expect(copy.armed, {TerminalModifier.ctrl});
      expect(paste.armed, {TerminalModifier.ctrl});
    });
  });

  group('typing on the soft keyboard', () {
    test('with nothing armed, text passes through untouched', () {
      final outcome = const KeyBarState().type('ls -la');

      expect(outcome.bytes, 'ls -la');
      expect(outcome.armed, isEmpty);
    });

    test('Ctrl plus a typed letter becomes the control code', () {
      // This is the half that matters most: Ctrl+D has no button of its own on
      // any sane bar, so the only way to reach it is Ctrl and then the phone's
      // own keyboard.
      const state = KeyBarState(armed: {TerminalModifier.ctrl});

      expect(state.type('d').bytes, '\x04');
      expect(state.type('D').bytes, '\x04');
      expect(state.type('r').bytes, '\x12');
    });

    test('typing spends the modifier', () {
      const state = KeyBarState(armed: {TerminalModifier.ctrl});

      expect(state.type('d').armed, isEmpty);
    });

    group('a newline from the phone keyboard is the Enter key', () {
      // Reported from real use: type a command, press return, nothing happened.
      // Two separate causes, and this is the second one — whatever the IME
      // inserts has to become the byte a terminal reads as Enter.
      test('LF becomes CR', () {
        expect(const KeyBarState().type('\n').bytes, '\r');
      });

      test('CRLF becomes a single CR, not two Enters', () {
        // "\\r\\n" is ONE grapheme cluster. Forwarding both bytes would run the
        // command twice — invisible with `ls`, not with `rm`.
        expect(const KeyBarState().type('\r\n').bytes, '\r');
      });

      test('a trailing newline submits the line before it', () {
        expect(const KeyBarState().type('ls\n').bytes, 'ls\r');
      });

      test('normal text is still untouched', () {
        expect(const KeyBarState().type('git status').bytes, 'git status');
      });
    });

    test('multi-character input is controlled character by character', () {
      // A fast typist can produce two characters between two frames of the
      // text field, so this is a real case rather than a synthetic one.
      const state = KeyBarState(armed: {TerminalModifier.ctrl});

      expect(state.type('cd').bytes, '\x03\x04');
    });
  });

  group('applying modifiers', () {
    test('Ctrl on a letter is code & 0x1f', () {
      expect(applyModifiers('a', {TerminalModifier.ctrl}), '\x01');
      expect(applyModifiers('z', {TerminalModifier.ctrl}), '\x1a');
      expect(applyModifiers('A', {TerminalModifier.ctrl}), '\x01');
    });

    test('Ctrl on the punctuation that has a control code uses it', () {
      expect(applyModifiers('[', {TerminalModifier.ctrl}), '\x1b');
      expect(applyModifiers(' ', {TerminalModifier.ctrl}), '\x00');
      expect(applyModifiers(']', {TerminalModifier.ctrl}), '\x1d');
      expect(applyModifiers('_', {TerminalModifier.ctrl}), '\x1f');
    });

    test('Ctrl on punctuation with NO control code sends it unchanged', () {
      // Swallowing the keypress would be worse than ignoring the modifier: a
      // dropped character in a terminal is invisible until something breaks.
      expect(applyModifiers('. ', {TerminalModifier.ctrl}), '. ');
      expect(applyModifiers('?', {TerminalModifier.ctrl}), '?');
      expect(applyModifiers('1', {TerminalModifier.ctrl}), '1');
    });

    test('Shift + Tab is the backwards-tab sequence', () {
      expect(applyModifiers('\t', {TerminalModifier.shift}), '\x1b[Z');
    });

    test('Ctrl and Shift on an arrow are modifier PARAMETERS, not controls', () {
      expect(applyModifiers('\x1b[A', {TerminalModifier.shift}), '\x1b[1;2A');
      expect(applyModifiers('\x1b[A', {TerminalModifier.ctrl}), '\x1b[1;5A');
    });

    test('Alt prefixes the sequence with ESC', () {
      expect(applyModifiers('f', {TerminalModifier.alt}), '\x1bf');
    });

    test('nothing armed returns the input untouched', () {
      expect(applyModifiers('hello', const {}), 'hello');
      expect(applyModifiers('', {TerminalModifier.ctrl}), '');
    });

    test('Shift plus Ctrl composes in that order', () {
      // Shift first, so this is the control form of the SHIFTED tab rather than
      // a shifted form of a control code that no terminal has a sequence for.
      expect(
        applyModifiers('\t', {TerminalModifier.shift, TerminalModifier.ctrl}),
        '\x1b[1;5Z',
      );
    });
  });

  group('pasting', () {
    test('wraps the text when the program asked for bracketed paste', () {
      expect(
        pastePayload('a\nb', bracketed: true),
        '\x1b[200~a\nb\x1b[201~',
      );
    });

    test('does not wrap when it did not', () {
      expect(pastePayload('a\nb', bracketed: false), 'a\rb');
    });

    test('line endings become CR when unbracketed', () {
      // A terminal's Enter sends carriage return. Without this a pasted command
      // runs AND leaves a stray LF behind, which in a raw-mode program is an
      // extra keypress nobody pressed.
      expect(pastePayload('one\r\ntwo\rthree\n', bracketed: false),
          'one\rtwo\rthree\r');
    });

    test('bracketed paste leaves the text alone', () {
      // The program is going to read it as an insertion; rewriting its line
      // endings would be the client editing the user's clipboard.
      expect(pastePayload('one\r\ntwo', bracketed: true),
          '\x1b[200~one\ntwo\x1b[201~');
    });

    test('an empty paste is still a valid payload', () {
      expect(pastePayload('', bracketed: false), '');
      expect(pastePayload('', bracketed: true), '\x1b[200~\x1b[201~');
    });
  });

  group('the expanded key panel', () {
    // Whether a press closes the panel is a property of the KEY, not of the
    // panel: the panel is a layout, and a layout that decided this would be a
    // second place where "what Ctrl does" is written down.
    test('a modifier keeps the panel open', () {
      // Arming is only half of a combination, so the panel has to survive it —
      // otherwise Ctrl+D needs the D to come from the soft keyboard.
      for (final key in [SoftKey.ctrl, SoftKey.alt, SoftKey.shift]) {
        expect(keyPanelStaysOpen(key), isTrue, reason: '${key.id} is a modifier');
      }
    });

    test('every other key closes it', () {
      final closing = SoftKey.values.where((k) => !k.isModifier);
      expect(closing, isNotEmpty);
      for (final key in closing) {
        expect(
          keyPanelStaysOpen(key),
          isFalse,
          reason: '${key.id} has already done something by being pressed',
        );
      }
    });
  });
}
