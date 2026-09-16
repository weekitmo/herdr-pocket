import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/terminal/terminal_selection.dart';
import 'package:xterm/core.dart';

/// Tests for the selection model and text extraction.
///
/// The model is pure so it can be tested here; the parts worth testing are the
/// ones that fail QUIETLY — a normalised range, a half-width of a wide glyph,
/// and trailing padding that would otherwise be copied into whatever the user
/// pastes.
void main() {
  Terminal terminalWith(List<String> lines) {
    final t = Terminal();
    // Write with explicit newlines so each string becomes its own buffer line.
    t.write('${lines.join('\r\n')}\r\n');
    return t;
  }

  group('TerminalSelection.between normalises direction', () {
    test('dragging down gives the same range as dragging up', () {
      final down = TerminalSelection.between((2, 3), (5, 1));
      final up = TerminalSelection.between((5, 1), (2, 3));
      expect(down.startLine, up.startLine);
      expect(down.endLine, up.endLine);
      expect(down.startColumn, up.startColumn);
      expect(down.endColumn, up.endColumn);
    });

    test('an upward drag still starts before it ends', () {
      final s = TerminalSelection.between((9, 0), (1, 4));
      expect(s.startLine, 1);
      expect(s.endLine, 9);
      // Dragging upwards is at least half of all selections; storing them
      // backwards would make every consumer remember to check.
    });

    test('a backwards drag on ONE line normalises too', () {
      final s = TerminalSelection.between((3, 9), (3, 2));
      expect(s.startColumn, 2);
      expect(s.endColumn, 9);
    });
  });

  group('contains', () {
    test('a single-line range includes the start and excludes the end', () {
      const s = TerminalSelection(
        startLine: 1,
        startColumn: 2,
        endLine: 1,
        endColumn: 5,
      );
      expect(s.contains(1, 1), isFalse);
      expect(s.contains(1, 2), isTrue);
      expect(s.contains(1, 4), isTrue);
      // Half-open: the cell under the finger is the end, and including it
      // would highlight one more cell than the user selected.
      expect(s.contains(1, 5), isFalse);
    });

    test('a multi-line range covers the middle lines entirely', () {
      const s = TerminalSelection(
        startLine: 1,
        startColumn: 4,
        endLine: 4,
        endColumn: 2,
      );
      expect(s.contains(1, 3), isFalse, reason: 'before the start column');
      expect(s.contains(1, 4), isTrue);
      expect(s.contains(2, 0), isTrue, reason: 'a middle line is fully in');
      expect(s.contains(2, 999), isTrue);
      expect(s.contains(4, 1), isTrue);
      expect(s.contains(4, 2), isFalse);
      expect(s.contains(5, 0), isFalse);
    });
  });

  group('selectionText', () {
    test('joins lines and trims the padding', () {
      final t = terminalWith(['hello   ', 'world']);
      final text = selectionText(
        t,
        const TerminalSelection(
          startLine: 0,
          startColumn: 0,
          endLine: 1,
          endColumn: 5,
        ),
      );
      // Trailing padding is a terminal artefact; nobody wants to paste it.
      expect(text, 'hello\nworld');
    });

    test('inner spaces survive, because paths contain them', () {
      final t = terminalWith(['/Users/me/My Folder/file.txt']);
      final text = selectionText(
        t,
        const TerminalSelection(
          startLine: 0,
          startColumn: 0,
          endLine: 0,
          endColumn: 28,
        ),
      );
      expect(text, '/Users/me/My Folder/file.txt');
    });

    test('a partial line takes only the selected columns', () {
      final t = terminalWith(['abcdef']);
      final text = selectionText(
        t,
        const TerminalSelection(
          startLine: 0,
          startColumn: 2,
          endLine: 0,
          endColumn: 4,
        ),
      );
      expect(text, 'cd');
    });

    test('CJK survives and is not duplicated by its trailing half', () {
      // A wide glyph occupies two cells; the second has no glyph of its own.
      // Emitting one for it would duplicate every Han character.
      final t = terminalWith(['中文测试']);
      final text = selectionText(
        t,
        const TerminalSelection(
          startLine: 0,
          startColumn: 0,
          endLine: 0,
          endColumn: 8,
        ),
      );
      expect(text, '中文测试');
    });

    test('an empty terminal yields an empty string rather than throwing', () {
      final t = Terminal();
      final text = selectionText(
        t,
        const TerminalSelection(
          startLine: 0,
          startColumn: 0,
          endLine: 0,
          endColumn: 3,
        ),
      );
      expect(text, '');
    });

    test('a range past the end of the buffer is clamped', () {
      final t = terminalWith(['only one line']);
      final text = selectionText(
        t,
        const TerminalSelection(
          startLine: 0,
          startColumn: 0,
          endLine: 500,
          endColumn: 4,
        ),
      );
      expect(text, contains('only one line'));
    });
  });

  group('the visible screen', () {
    test('reads the lines the viewport is showing', () {
      final t = terminalWith(['one', 'two', 'three']);

      expect(viewportText(t, startLine: 1, rowCount: 2), 'two\nthree');
    });

    test('reading past the content yields blanks, never invented text', () {
      // xterm pre-allocates the buffer, so the lines past the content EXIST.
      // What matters is that they come back blank rather than as whatever the
      // cell happens to hold.
      final t = terminalWith(['one', 'two']);

      final rows = viewportText(t, startLine: 0, rowCount: 40).split('\n');

      expect(rows[0], 'one');
      expect(rows[1], 'two');
      expect(rows.join(), 'onetwo');
    });

    test('trims the padding off every line', () {
      // A terminal line is padded to the viewport width, and copying that
      // padding is how a copied command ends up with 200 trailing spaces.
      final t = terminalWith(['id']);

      final text = viewportText(t, startLine: 0, rowCount: 1);

      expect(text, 'id');
    });

    test('a never-written screen copies as nothing', () {
      // Cells nobody wrote hold codepoint 0. Emitting it would put NUL bytes on
      // the clipboard, which paste into the next program as nothing and into a
      // diff as a difference.
      final t = Terminal(maxLines: 50);
      t.resize(20, 3);

      expect(viewportText(t, startLine: 0, rowCount: 3), '\n\n');
    });

    test('an empty buffer is not an error', () {
      final t = Terminal(maxLines: 50);

      expect(viewportText(t, startLine: 0, rowCount: 0), '');
    });
  });
}
