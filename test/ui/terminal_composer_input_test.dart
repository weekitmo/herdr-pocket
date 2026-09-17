import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_harness.dart';

/// The terminal page against a scripted daemon.
///
/// TWO BUGS ARE PINNED HERE, and both of them are about the soft keyboard:
///
///  * **The delete key did nothing.** The page fed the terminal from a text
///    field's `onChanged`, and cleared that field after every keystroke — so a
///    backspace had nothing to delete and produced no event at all. Typing into
///    a TUI's input box and then being unable to take a character back out of it
///    is the whole complaint; the DEL below is the fix.
///
///  * **The pane was asked for the widget's height.** The daemon does not reflow
///    a pane to the geometry it is asked for, it crops it — from the top — so a
///    request shorter than the pane silently drops the bottom of the terminal,
///    which is where the input box is. The request has to be the pane's height,
///    and what fits on screen decides only which rows are VISIBLE.
///
/// The daemon is faked rather than faked-out: the page really opens a control
/// session through `TerminalControl`, so the assertions are about the bytes and
/// the `--rows` that would have gone on the wire.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<FakeTerminalDaemon> pumpTerminal(
    WidgetTester tester, {
    int paneRows = 46,
  }) => pumpTerminalPage(tester, prefs: prefs, paneRows: paneRows);

  /// Everything the app has sent on the terminal channel, decoded.
  List<Map<String, Object?>> inputCommands(FakeTerminalDaemon daemon) =>
      daemon.inputCommands();

  /// Types on the phone's keyboard, the way the IME reports it.
  ///
  /// The sentinel is the field's resting contents, so typing is what the field
  /// looks like WITH the new characters appended — which is exactly what the
  /// real keyboard sends.
  void type(WidgetTester tester, String text) {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '$kComposerSentinel$text',
        selection: TextSelection.collapsed(
          offset: kComposerSentinel.length + text.length,
        ),
      ),
    );
  }

  /// Presses delete, which is one character shorter than the field was.
  void backspace(WidgetTester tester) {
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' ',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
  }

  testWidgets('a backspace sends DEL even though the field was empty',
      (tester) async {
    final daemon = await pumpTerminal(tester);
    // The keyboard is up because the page autofocuses its input surface, which
    // is what the real page does on open.
    expect(tester.testTextInput.hasAnyClients, isTrue);

    backspace(tester);
    await tester.pump();

    final input = inputCommands(daemon);
    expect(input, hasLength(1), reason: 'a backspace must reach the terminal');
    expect(
      utf8.decode(base64.decode(input.single['bytes']! as String)),
      '\x7f',
      reason: 'DEL is a terminal backspace; nothing else deletes a character',
    );
  });

  testWidgets('typing sends what was typed', (tester) async {
    final daemon = await pumpTerminal(tester);

    type(tester, 'ls');
    await tester.pump();

    final input = inputCommands(daemon);
    expect(input.single['text'], 'ls');
  });

  testWidgets('a composition is not typed into the pane', (tester) async {
    final daemon = await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '${kComposerSentinel}nihao',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 2, end: 7),
      ),
    );
    await tester.pump();

    expect(
      inputCommands(daemon),
      isEmpty,
      reason: 'pinyin letters are not a command',
    );
  });

  testWidgets(
      "the grid asked for is the PANE's height, not the widget's",
      (tester) async {
    final daemon = await pumpTerminal(tester, paneRows: 46);

    final open = daemon.openCommands.single;
    expect(open, contains('terminal session control'));
    expect(
      open,
      contains('--rows 46'),
      reason: "a shorter request makes the daemon crop the pane's bottom away",
    );
  });

  testWidgets('a hardware backspace sends DEL too', (tester) async {
    // The other door into the composer: a physical keyboard (or `adb shell
    // input`) delivers KeyEvents, not edits to a field, and a hand-written
    // input client sees none of them unless it asks. Without this the terminal
    // types nothing at all from a real keyboard.
    final daemon = await pumpTerminal(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    final input = inputCommands(daemon);
    expect(input, hasLength(1));
    expect(
      utf8.decode(base64.decode(input.single['bytes']! as String)),
      '\x7f',
    );
  });

  testWidgets('hardware keys type the characters they carry', (tester) async {
    final daemon = await pumpTerminal(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();

    expect(inputCommands(daemon).single['text'], 'l');
  });

  testWidgets('a hardware Enter is the key bar Enter', (tester) async {
    final daemon = await pumpTerminal(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(inputCommands(daemon).single['text'], '\r');
  });

  testWidgets(
      'a frame taller than the box is drawn from its BOTTOM',
      (tester) async {
    // The pane is 46 rows and no phone box holds 46 at this font size, so this
    // is the software-keyboard case by construction: without the shift, the
    // pane's last rows — the prompt, the composer — are under the key bar.
    await pumpTerminal(tester, paneRows: 46);

    final painter = surfacePainter(tester);
    final visibleRows = boxRows(tester, painter);
    expect(
      visibleRows,
      lessThan(46),
      reason: 'the test needs a box shorter than the pane',
    );
    expect(
      painter.topRow,
      46 - visibleRows,
      reason: "the frame's last row has to land on the box's last row",
    );
  });

  testWidgets("the buffer is the size the daemon rendered at, not xterm's default",
      (tester) async {
    // THE BUG THIS PINS. The model was resized only when a frame's declared
    // size differed from the size that had been ASKED for — and they are the
    // same by construction, so the resize never happened and the buffer stayed
    // at xterm's default 80x24. `viewHeight` is what the painter limits its
    // window to, so a 46-row frame on a 24-row buffer drew its last three lines
    // and nothing else: two lines of conversation, the status bar, and a
    // screenful of blank — exactly what the phone showed.
    final daemon = await pumpTerminal(tester, paneRows: 46);

    // The frame the daemon would send is the one it was asked for, so the test
    // has to ask the session what that was.
    final asked = RegExp(r'--cols (\d+) --rows (\d+)')
        .firstMatch(daemon.openCommands.single)!;
    final cols = int.parse(asked.group(1)!);
    final rows = int.parse(asked.group(2)!);
    daemon.emitFrame(
      data: '\x1b[2J\x1b[$rows;1Hthe last row',
      width: cols,
      height: rows,
    );
    await tester.pump();
    await tester.pump();

    final painter = surfacePainter(tester);
    expect(
      painter.terminal.viewWidth,
      cols,
      reason: 'the model has to be the width the escape sequences were built for',
    );
    expect(
      painter.terminal.viewHeight,
      rows,
      reason: 'and its height, or the window is taken from the wrong end',
    );
  });

  testWidgets('the keyboard moves the window, not the grid', (tester) async {
    // THE SYMPTOM THIS PINS. Opening the keyboard takes a third of the screen.
    // If that shrinks the geometry the daemon is asked for, the pane is cropped
    // — from the top — and the agent's input box is not on screen at all. So the
    // keyboard must move the SLICE of the frame that is shown, and cost no
    // round trip to the machine.
    final daemon = await pumpTerminal(tester, paneRows: 46);
    final before = surfacePainter(tester).topRow;

    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final painter = surfacePainter(tester);
    final visibleRows = boxRows(tester, painter);

    expect(
      painter.topRow,
      greaterThan(before),
      reason: 'the visible window has to move down the pane',
    );
    expect(
      painter.topRow + visibleRows,
      46,
      reason: "the pane's last row stays on the box's last row, above the bar",
    );
    expect(
      daemon.sentOnTerminal().where((line) => line.contains('resize')),
      isEmpty,
      reason: "the grid is the pane's, so a keyboard cannot resize it",
    );
  });
}
