import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:xterm/core.dart';

/// Colours the painter actually puts on the canvas.
///
/// The buffer is not the thing the user sees: a cell can carry a colour and
/// still be painted in the default one. These tests read pixels so that gap is
/// closed rather than assumed away.
Future<Set<int>> _paintedColors(String ansi, {int cols = 20}) {
  final terminal = Terminal(maxLines: 100);
  terminal.resize(cols, 4);
  terminal.write(ansi);
  return _painted(terminal, cols: cols, rows: 4);
}

/// Every colour the painter puts on the canvas for [terminal].
Future<Set<int>> _painted(Terminal terminal, {required int cols, required int rows}) async {
  final pixels = await _pixels(terminal, cols: cols, rows: rows);
  final seen = <int>{};
  for (var i = 0; i < pixels.length; i += 4) {
    seen.add(
      (0xFF << 24) | (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2],
    );
  }
  return seen;
}

/// The raw RGBA buffer the painter produced.
Future<Uint8List> _pixels(
  Terminal terminal, {
  required int cols,
  required int rows,
  int topRow = 0,
  int topPadding = 0,
  bool cursorVisible = false,
}) async {
  const cellWidth = 10.0;
  const cellHeight = 20.0;
  final recorder = ui.PictureRecorder();
  TerminalPainter(
    terminal: terminal,
    palette: TerminalColors.dark,
    cellWidth: cellWidth,
    cellHeight: cellHeight,
    fontFamily: null,
    fontFamilyFallback: const [],
    fontSize: 14,
    cursorVisible: cursorVisible,
    scrollOffset: 0,
    topRow: topRow,
    topPadding: topPadding,
    selection: null,
    repaint: Listenable.merge(const []),
  ).paint(Canvas(recorder), Size(cols * cellWidth, rows * cellHeight));

  final image = await recorder.endRecording().toImage(
        (cols * cellWidth).toInt(),
        (rows * cellHeight).toInt(),
      );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  final red = TerminalColors.dark.ansi[1].toARGB32();
  final green = TerminalColors.dark.ansi[2].toARGB32();

  test('topPadding moves the whole frame down the canvas', () async {
    // THE PHONE REPORT THIS PINS: after the keyboard or the chat window closes,
    // the pane sat at the top of the screen with a band of empty terminal under
    // it. The painter is handed a canvas taller than the frame and a number of
    // spare rows; the frame's own pixels have to move down by that many rows,
    // which no assertion on the painter's fields can prove.
    final terminal = Terminal(maxLines: 100);
    terminal.resize(20, 4);
    // One row with a green background, so the frame's first row is findable on
    // the canvas by colour.
    terminal.write('\x1b[42mMMMM');

    const cellHeight = 20.0;
    final pixels = await _pixels(
      terminal,
      cols: 20,
      rows: 10,
      topPadding: 6,
    );

    // The first row that is not the terminal's own background.
    final background = TerminalColors.dark.background.toARGB32();
    var firstContentRow = -1;
    for (var y = 0; y < 10 * cellHeight; y++) {
      final i = (y * 200 + 5) * 4;
      final argb = (0xFF << 24) | (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2];
      if (argb != background) {
        firstContentRow = y;
        break;
      }
    }

    expect(
      firstContentRow,
      greaterThanOrEqualTo((6 * cellHeight).toInt()),
      reason: 'the six spare rows are above the frame, not under it',
    );
    expect(
      firstContentRow,
      lessThan((7 * cellHeight).toInt()),
      reason: 'and the frame starts immediately after them',
    );
  });

  test('the cursor survives topPadding — it sits at the BOTTOM of the frame', () async {
    // Found by review, not by the phone: the cursor's bound used to be
    // `row >= terminal.viewHeight`, which could never fire while only the
    // keyboard shift existed. With padding, `row` grows by the pad, so a frame
    // shorter than its box dropped every cursor in its lower part — i.e. the
    // prompt the user is typing at the moment the keyboard is down.
    final terminal = Terminal(maxLines: 100);
    terminal.resize(20, 4);
    // A cursor on the frame's LAST row, which is where a prompt lives.
    terminal.write('\x1b[4;1H');

    const cellHeight = 20.0;
    final pixels = await _pixels(
      terminal,
      cols: 20,
      rows: 10,
      topPadding: 6,
      cursorVisible: true,
    );

    // The cursor is a thin bar (~1.2px) at the left edge of its cell, so the
    // scan looks at the canvas's first pixel column.
    final cursor = TerminalColors.dark.cursor.toARGB32();
    var found = -1;
    for (var y = 0; y < 10 * cellHeight; y++) {
      final i = y * 200 * 4;
      final argb =
          (0xFF << 24) | (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2];
      if (argb == cursor) {
        found = y;
        break;
      }
    }

    expect(found, isNot(-1), reason: 'the cursor was not painted at all');
    expect(
      found,
      greaterThanOrEqualTo((6 + 3) * cellHeight),
      reason: 'frame row 4 of a 4-row frame lands in the padded canvas',
    );
    expect(
      found,
      lessThan((6 + 4) * cellHeight),
      reason: 'and inside the frame row it belongs to',
    );
  });

  test('a coloured run keeps its colour when the next run is default', () async {
    // The naive painter resolves each cell into one shared scratch object and
    // then reads that object AFTER the run loop has already advanced past the
    // run — so every run is drawn in its successor's colour, and a coloured run
    // followed by a default one loses its colour entirely.
    final seen = await _paintedColors('\x1b[31mAAAA\x1b[0mBBBB');

    expect(
      seen.contains(red),
      isTrue,
      reason: 'red run followed by default run painted no red pixel',
    );
  });

  test('a colour survives when it is followed by a different colour', () async {
    final seen = await _paintedColors('\x1b[31mAAAA\x1b[32mBBBB');

    expect(seen.contains(red), isTrue, reason: 'first colour was overwritten');
    expect(seen.contains(green), isTrue, reason: 'second colour was lost');
  });

  test('a colour survives at the very end of a line', () async {
    // The mirror of the first case: nothing follows the run, so the scratch
    // object happens to still describe it. Handling one end of the buffer
    // correctly is not evidence that the other end is handled.
    final seen = await _paintedColors('BBBB\x1b[31mAAAA');

    expect(seen.contains(red), isTrue, reason: 'trailing colour was lost');
  });

  test('background colour is painted for a coloured run', () async {
    final seen = await _paintedColors('\x1b[41mAAAA\x1b[0mBBBB');

    expect(
      seen.contains(TerminalColors.dark.ansi[1].toARGB32()),
      isTrue,
      reason: 'red background never reached the canvas',
    );
  });

  test('a cell nobody has written paints NOTHING, not the missing-glyph box',
      () async {
    // `CellData.empty()` holds codepoint 0, and U+0000 has no glyph in any
    // font — so drawing it paints the font's `.notdef` box. The buffer grows
    // when the viewport does, and the new rows stay empty until the daemon
    // repaints them, which is what produced a wall of hatched boxes for the
    // first fraction of a second after a terminal opened.
    final terminal = Terminal(maxLines: 100);
    terminal.resize(20, 6);

    final seen = await _painted(terminal, cols: 20, rows: 6);

    expect(
      seen,
      {TerminalColors.dark.background.toARGB32()},
      reason: 'an unwritten screen must be background only',
    );
  });

  test('a written screen is not empty, so the test above can fail', () async {
    // The guard on the guard: if the harness ever stopped painting, the
    // assertion above would pass for the wrong reason.
    final seen = await _paintedColors('AAAA');

    expect(seen.length, greaterThan(1));
  });
}
