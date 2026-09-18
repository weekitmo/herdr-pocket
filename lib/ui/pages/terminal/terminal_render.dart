import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart';
import 'package:herdr_pocket/data/terminal/terminal_selection.dart';
import 'package:herdr_pocket/domain/theme/terminal_palette.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:xterm/core.dart';

/// The terminal's colours.
///
/// The terminal is the one surface with its OWN ground: herdr ships
/// `groundMachine` a shade under the app's ground precisely so a terminal reads
/// as a different kind of place. ANSI colours sit on top of that and are the
/// terminal's business, not the app's.
/// The terminal's 20 colours, resolved to `Color`s.
///
/// Named `TerminalColors` rather than `TerminalPalette` because the palette —
/// the same twenty values as data — lives in `lib/domain/theme/`, and two
/// classes with one name across two layers is a rename waiting to happen.
/// This is the UI edge: the domain speaks hex, everything above speaks [Color].
class TerminalColors {
  const TerminalColors({
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.selection,
    required this.ansi,
    required this.bright,
  });

  /// A colour scheme's own twenty colours.
  ///
  /// Verbatim, with no enforcement: these are the colours the scheme's author
  /// chose for a terminal, and this IS a terminal. Scheme-wide readability is
  /// handled where it belongs — on the app chrome the user reads around it.
  /// A scheme with no ANSI defined keeps this app's defaults for those slots,
  /// because an invisible terminal is worse than an off-palette one.
  factory TerminalColors.fromScheme(TerminalPalette scheme) {
    Color color(String hex, Color fallback) =>
        hex.trim().isEmpty ? fallback : HerdrColors.colorFromHex(hex);
    const fallback = TerminalColors.dark;
    return TerminalColors(
      background: color(scheme.background, fallback.background),
      foreground: color(scheme.foreground, fallback.foreground),
      cursor: color(scheme.cursor, fallback.cursor),
      selection: scheme.selectionBackground == null
          ? fallback.selection
          : HerdrColors.colorFromHex(scheme.selectionBackground!).withValues(alpha: 0.5),
      ansi: [
        for (var i = 0; i < 8; i++)
          color(i < scheme.ansi.length ? scheme.ansi[i] : '', fallback.ansi[i]),
      ],
      bright: [
        for (var i = 0; i < 8; i++)
          color(i < scheme.bright.length ? scheme.bright[i] : '', fallback.bright[i]),
      ],
    );
  }

  final Color background;
  final Color foreground;
  final Color cursor;
  final Color selection;

  /// ANSI 0–7.
  final List<Color> ansi;

  /// ANSI 8–15.
  final List<Color> bright;

  /// The standard xterm 16, tuned to sit on herdr's near-black terminal ground
  /// rather than on pure black.
  static const dark = TerminalColors(
    background: Color(0xFF0B0D1C),
    foreground: Color(0xFFEEF0F7),
    cursor: Color(0xFF5B9BE8), // the working blue: the caret is "alive"
    selection: Color(0x555B9BE8),
    ansi: [
      Color(0xFF3B3F54),
      Color(0xFFE2584E),
      Color(0xFF5FB37F),
      Color(0xFFE9A63C),
      Color(0xFF5B9BE8),
      Color(0xFFCE58A4),
      Color(0xFF4FB8C9),
      Color(0xFFD5D9E8),
    ],
    bright: [
      Color(0xFF6B7291),
      Color(0xFFF0705F),
      Color(0xFF7FC99B),
      Color(0xFFF0BE6A),
      Color(0xFF7FB4F0),
      Color(0xFFE07FBC),
      Color(0xFF6FD3E2),
      Color(0xFFFFFFFF),
    ],
  );

  /// xterm-256 colour [index], as a [Color].
  ///
  /// 0–15 come from the theme, 16–231 are a 6×6×6 cube, 232–255 a grey ramp.
  /// The cube levels are the standard `0, 95, 135, 175, 215, 255` — not evenly
  /// spaced, because they were chosen for perceptual uniformity on the
  /// hardware the standard was written for.
  Color indexed(int index) {
    if (index < 0) return foreground;
    if (index < 8) return ansi[index];
    if (index < 16) return bright[index - 8];

    if (index < 232) {
      final i = index - 16;
      const levels = [0, 95, 135, 175, 215, 255];
      return Color.fromARGB(
        255,
        levels[(i ~/ 36) % 6],
        levels[(i ~/ 6) % 6],
        levels[i % 6],
      );
    }

    final grey = 8 + (index - 232) * 10;
    return Color.fromARGB(255, grey, grey, grey);
  }
}

/// One cell's appearance as a value.
///
/// Immutable because of what went wrong without it. An earlier version resolved
/// every cell into a single shared scratch object and then read that object
/// *after* the loop that groups a line into runs — by which point it described
/// the first cell of the NEXT run. The symptom was not a crash but silently
/// missing colour: a red run followed by default text was painted default, so a
/// status bar came out grey and an oh-my-zsh prompt came out plain. A run has to
/// own the style it started with, so the style it starts with is a value.
@immutable
class _CellStyle {
  const _CellStyle({
    required this.fg,
    required this.bg,
    required this.hasBg,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.invisible,
  });

  final Color fg;
  final Color bg;
  final bool hasBg;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool invisible;

  /// What makes two cells part of the same run.
  ///
  /// Deliberately excludes the background: a run is broken by a change in the
  /// glyphs' appearance. Backgrounds are drawn separately as merged rectangles,
  /// so splitting a text run over one would cost a `TextPainter` per colour
  /// change in a screen that is mostly flat.
  int get key => Object.hash(fg.toARGB32(), bold, italic, underline, invisible);
}

/// The mutable scratch a line scan reuses.
///
/// One instance is reused for every cell so that scanning a full screen does not
/// allocate per cell — a screenful is thousands of cells and the painter runs on
/// every frame. Nothing outside a scan loop may hold on to it: the moment a
/// value has to outlive the cell that produced it, take a [snapshot].
class _Resolved {
  Color fg = const Color(0xFF000000);
  Color bg = const Color(0xFF000000);
  bool hasBg = false;
  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool invisible = false;
  int key = 0;

  _CellStyle snapshot() => _CellStyle(
        fg: fg,
        bg: bg,
        hasBg: hasBg,
        bold: bold,
        italic: italic,
        underline: underline,
        invisible: invisible,
      );
}

/// Which slice of the buffer the viewport is showing.
///
/// Extracted from the painter so the arithmetic can be tested. It is the kind
/// of code that looks obvious and is off by one in three places: the window is
/// anchored to the END of the buffer, the offset counts backwards from the live
/// screen, and both ends have to clamp.
///
/// [start] is the first buffer line to draw; the viewport draws [rowCount] of
/// them from there.
({int start, int rowCount}) terminalViewport({
  required int totalLines,
  required int viewHeight,
  required int scrollOffset,
}) {
  if (totalLines <= 0 || viewHeight <= 0) return (start: 0, rowCount: 0);

  // The last `viewHeight` lines are the live screen; everything before is
  // history. Anchoring here rather than at the top is what keeps the reader's
  // place when output arrives.
  final liveStart = math.max(0, totalLines - viewHeight);
  // `clamp` is declared on `num` and returns `num` even for int inputs, so the
  // narrowing is explicit rather than implicit.
  final start = (liveStart - math.max(0, scrollOffset)).clamp(0, liveStart).toInt();
  final available = totalLines - start;
  return (start: start, rowCount: math.min(viewHeight, available));
}

/// Renders a [Terminal] buffer.
///
/// Hand-written rather than reusing xterm's `TerminalView`, for two reasons.
/// The first is the project's hard constraint: `TerminalView` imports
/// `package:flutter/material.dart`, and while it does not instantiate Material
/// widgets, depending on it would make the no-Material rule a matter of trust
/// instead of a matter of fact. The second is that a terminal is the one place
/// the app shows machine output at length, and owning the painter is what makes
/// the type, the cell metrics and the CJK grid ours to get right.
class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.terminal,
    required this.palette,
    required this.cellWidth,
    required this.cellHeight,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontSize,
    required this.cursorVisible,
    required this.scrollOffset,
    required this.selection,
    required super.repaint,
    this.topRow = 0,
    this.topPadding = 0,
  });

  final Terminal terminal;
  final TerminalColors palette;
  final double cellWidth;
  final double cellHeight;
  final String? fontFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final bool cursorVisible;

  /// How many lines back from the live bottom the viewport sits.
  ///
  /// The daemon renders the VISIBLE screen, but xterm's buffer keeps history,
  /// and `Buffer` has no viewport notion — `scrollUp`/`scrollDown` move the
  /// CONTENT the way incoming output does, which is not what a reader wants
  /// when they scroll back. So the window into the history is computed here.
  final int scrollOffset;

  /// The run being selected, in buffer coordinates. Null when nothing is.
  final TerminalSelection? selection;

  /// The first buffer row drawn at the top of the canvas.
  ///
  /// Non-zero when the frame is TALLER than the box it is drawn into — the
  /// soft keyboard has taken part of the screen, or the user has pinched the
  /// text up — and then the frame's bottom is what belongs on screen, because
  /// the bottom of a terminal is where the prompt and every TUI's composer
  /// live. Zero in the split view, where each pane is rendered at its own size
  /// and there is nothing to shift. The arithmetic is in
  /// `domain/terminal/window.dart`, where it is tested without a canvas.
  final int topRow;

  /// Blank rows left ABOVE the frame, in cell rows.
  ///
  /// The other half of the same arithmetic: the frame is SHORTER than the box
  /// (a 48-row desktop pane on a phone that fits 66), and the spare rows are
  /// kept at the top so the pane's last row — the status bar, the prompt, the
  /// line being typed — sits against the key bar instead of floating above a
  /// band of empty terminal. A real terminal viewport is anchored the same way:
  /// the end of the buffer is the fixed point.
  ///
  /// Counted in ROWS rather than pixels so it is the same unit as [topRow], and
  /// the canvas does the multiplication with the cell height it was given.
  final int topPadding;

  @override
  void paint(Canvas canvas, Size size) {
    final buffer = terminal.buffer;
    final viewWidth = terminal.viewWidth;
    final viewHeight = terminal.viewHeight;

    final backgroundPaint = Paint()..color = palette.background;
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    final resolved = _Resolved();
    final cell = CellData.empty();

    // Lines are addressed from the END: the last `viewHeight` of them are the
    // live screen, everything before is scrollback. Offsetting from the bottom
    // rather than the top means output arriving while the user is reading
    // history does not slide the text under their eyes.
    final window = terminalViewport(
      totalLines: buffer.lines.length,
      viewHeight: viewHeight,
      scrollOffset: scrollOffset,
    );

    // The rows this canvas can hold, after the shifted-away ones. Drawing the
    // rest would only paint them under the keyboard bar — and the frame starts
    // [topPadding] rows down when the box is the taller of the two.
    final drawnRows = math.max(0, window.rowCount - topRow);
    final topOffset = topPadding * cellHeight;

    for (var y = 0; y < drawnRows; y++) {
      final lineIndex = window.start + topRow + y;
      if (lineIndex >= buffer.lines.length) break;

      final line = buffer.lines[lineIndex];
      final top = topOffset + y * cellHeight;
      // The frame is at most as tall as it says it is; a canvas given a shorter
      // box than its frame draws only what fits. (`topRow` normally covers
      // this; the guard is for the pinch-zoom case where the cell size is
      // between two whole rows.)
      if (top >= size.height) break;

      // Pass 1: background rectangles for the whole row, merged into runs so a
      // full-width coloured row costs one rect instead of one per cell.
      var runStart = -1;
      var runColor = palette.background;
      for (var x = 0; x <= viewWidth; x++) {
        var bg = palette.background;
        var hasBg = false;
        if (x < viewWidth && x < line.length) {
          line.getCellData(x, cell);
          _resolve(cell, resolved);
          hasBg = resolved.hasBg;
          bg = resolved.bg;
        }

        final sameRun = hasBg && runStart >= 0 && bg.toARGB32() == runColor.toARGB32();
        if (sameRun) continue;

        if (runStart >= 0) {
          canvas.drawRect(
            Rect.fromLTWH(
              runStart * cellWidth,
              top,
              (x - runStart) * cellWidth,
              cellHeight,
            ),
            Paint()..color = runColor,
          );
          runStart = -1;
        }
        if (hasBg) {
          runStart = x;
          runColor = bg;
        }
      }

      // Pass 2: the text, grouped into runs of identical style.
      var x = 0;
      while (x < viewWidth && x < line.length) {
        line.getCellData(x, cell);
        _resolve(cell, resolved);

        final width = _cellWidth(cell);
        if (width == 0) {
          // A trailing half of a wide character: already painted by its head.
          x++;
          continue;
        }

        final startX = x;
        // Snapshot before the loop, not after it. See [_CellStyle].
        final style = resolved.snapshot();
        final styleKey = style.key;
        final run = StringBuffer();

        while (x < viewWidth && x < line.length) {
          line.getCellData(x, cell);
          _resolve(cell, resolved);
          if (resolved.key != styleKey) break;
          final w = _cellWidth(cell);
          if (w == 0) {
            x++;
            continue;
          }
          final code = cell.content & CellContent.codepointMask;
          // A cell nobody has written holds codepoint 0, and U+0000 has no
          // glyph in any font — so drawing it paints the font's `.notdef`, a
          // hatched box. That is not a theoretical case: the buffer grows when
          // the viewport does, the new rows stay empty until the daemon
          // repaints them, and the result was a wall of boxes for the few
          // hundred milliseconds in between. xterm's own painter returns early
          // for the same reason; here the cell has to become a SPACE rather
          // than nothing at all, because a run is positioned by its first cell
          // and dropping a character would shift everything after it left.
          run.write(code == 0 ? ' ' : String.fromCharCode(code));
          x += w;
        }

        if (run.isEmpty || style.invisible) continue;

        final painter = TextPainter(
          text: TextSpan(
            text: run.toString(),
            style: TextStyle(
              color: style.fg,
              fontSize: fontSize,
              fontFamily: fontFamily,
              fontFamilyFallback: fontFamilyFallback,
              fontWeight: style.bold ? FontWeight.w700 : FontWeight.w400,
              fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
              height: 1,
              decoration:
                  style.underline ? TextDecoration.underline : null,
              decorationColor: style.fg,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();

        painter.paint(canvas, Offset(startX * cellWidth, top));
      }
    }

    _paintSelection(canvas, window.start + topRow, drawnRows, size);
    _paintCursor(canvas, size);
  }
  /// Tints the selected cells.
  ///
  /// Drawn as a wash over the existing glyphs rather than as an inverted block:
  /// a terminal's colours carry meaning — red is an error, green is a pass — and
  /// replacing them while the user is reading would hide exactly the thing they
  /// are selecting.
  void _paintSelection(Canvas canvas, int bufferStart, int rowCount, Size size) {
    final range = selection;
    if (range == null || range.isEmpty) return;

    final paint = Paint()..color = palette.selection;
    for (var row = 0; row < rowCount; row++) {
      final lineIndex = bufferStart + row;
      var runStart = -1;
      // One past the end, so a run that reaches the last column is flushed.
      for (var column = 0; column <= terminal.viewWidth; column++) {
        final inside =
            column < terminal.viewWidth && range.contains(lineIndex, column);
        // Rows pushed below the canvas by the padding (a frame taller than the
        // box it is drawn into) are not worth walking cell by cell — the same
        // reason the text loop stops.
        final top = (topPadding + row) * cellHeight;
        if (top >= size.height) break;
        if (inside && runStart < 0) {
          runStart = column;
        } else if (!inside && runStart >= 0) {
          canvas.drawRect(
            Rect.fromLTWH(
              runStart * cellWidth,
              top,
              (column - runStart) * cellWidth,
              cellHeight,
            ),
            paint,
          );
          runStart = -1;
        }
      }
    }
  }

  void _paintCursor(Canvas canvas, Size size) {
    // A cursor drawn over history would claim the shell is typing into text it
    // has already scrolled past.
    if (!cursorVisible || scrollOffset > 0) return;
    final buffer = terminal.buffer;
    final x = buffer.cursorX;
    final y = buffer.cursorY;
    if (x < 0 || y < 0 || y >= terminal.viewHeight) return;

    // `cursorY` is a row of the LIVE SCREEN — xterm keeps it relative to the
    // viewport, not to the history — and with the viewport at the bottom that
    // screen starts exactly at the frame's top. So the only things between it
    // and the canvas are the shift and the padding.
    final row = y - topRow + topPadding;
    if (row < 0) return;
    // THE CANVAS IS THE BOUND, NOT THE FRAME. While only `topRow` existed,
    // `row >= terminal.viewHeight` could never fire (row ≤ y < viewHeight) and
    // stood in for "off the bottom". With padding it fires on every cursor in
    // the lower part of a frame that is SHORTER than the box — i.e. exactly the
    // prompt the user is typing at when the keyboard is down (found by review:
    // a 48-row pane in a 66-row box dropped every cursor at row ≥ 30).
    if ((row + 1) * cellHeight > size.height) return;

    final rect = Rect.fromLTWH(
      x * cellWidth,
      row * cellHeight,
      cellWidth,
      cellHeight,
    );
    // A thin bar rather than a filled block: a block hides the character under
    // it, which on a phone means you cannot see what you are about to type.
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.top, math.max(1, cellWidth * 0.12), rect.height),
      Paint()..color = palette.cursor,
    );
  }

  /// How many columns this cell occupies: 2 for East Asian wide characters,
  /// 0 for the trailing half of one.
  int _cellWidth(CellData cell) {
    final w = (cell.content >> CellContent.widthShift) & 3;
    return w == 0 ? 1 : w;
  }

  /// Turns a packed cell into concrete colours and flags.
  ///
  /// Colours are stored as `(type << 25) | value`, where the type says whether
  /// the value indexes the theme, the 256-colour cube, or is literal RGB.
  /// Getting this wrong is the classic terminal bug: treating a palette index
  /// as RGB produces confidently wrong colours rather than an error.
  void _resolve(CellData cell, _Resolved out) {
    final flags = cell.flags;
    final inverse = flags & CellAttr.inverse != 0;

    final fg = _color(cell.foreground, isForeground: true);
    final bg = _color(cell.background, isForeground: false);

    out.hasBg = bg != null;
    out.bg = bg ?? palette.background;
    out.fg = fg ?? palette.foreground;

    if (inverse) {
      final swapped = out.fg;
      out.fg = out.bg;
      out.bg = swapped;
      out.hasBg = true;
    }

    out.bold = flags & CellAttr.bold != 0;
    out.italic = flags & CellAttr.italic != 0;
    out.underline = flags & CellAttr.underline != 0;
    out.invisible = flags & CellAttr.invisible != 0;
    out.key = Object.hash(
      out.fg.toARGB32(),
      out.bold,
      out.italic,
      out.underline,
      out.invisible,
    );
  }

  /// Returns null for "the default colour", which callers substitute.
  Color? _color(int packed, {required bool isForeground}) {
    switch (packed & CellColor.typeMask) {
      case CellColor.normal:
        return null;
      case CellColor.named:
        final index = packed & CellColor.valueMask;
        return index < 8 ? palette.ansi[index] : palette.bright[index - 8];
      case CellColor.palette:
        return palette.indexed(packed & CellColor.valueMask);
      case CellColor.rgb:
        return Color(0xFF000000 | (packed & CellColor.valueMask));
      default:
        return null;
    }
  }

  @override
  bool shouldRepaint(TerminalPainter old) =>
      old.terminal != terminal ||
      old.scrollOffset != scrollOffset ||
      old.topRow != topRow ||
      old.topPadding != topPadding ||
      old.selection != selection ||
      old.cellWidth != cellWidth ||
      old.fontSize != fontSize ||
      old.palette != palette;
}

/// Measures a monospace cell for the given font.
///
/// Everything about terminal layout depends on this being exact: a cell that is
/// half a pixel too narrow makes every full-width CJK glyph drift, and the drift
/// accumulates across a line until the right edge is visibly ragged.
class CellMetrics {
  const CellMetrics({required this.width, required this.height});

  final double width;
  final double height;

  static CellMetrics measure({
    required String text,
    required TextStyle style,
  }) {
    final painter = TextPainter(
      // A wide glyph: `M` is the conventional measure, but measuring the
      // full-width ideographic space catches fonts whose CJK advance is not
      // exactly twice the Latin one, which is precisely the case that breaks
      // the grid.
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    return CellMetrics(width: painter.width, height: painter.height);
  }
}

/// The font size the terminal is drawn at before the user scales it.
///
/// One of the two numbers that decide how much of a desktop the phone can show
/// at once (the other is the screen): at 12 points, a 411-point-wide phone fits
/// about 68 columns, which is a full-width TUI and a narrow editor.
///
/// It lives beside the cell metrics because the two are one decision: this is
/// the number, [CellMetrics.measure] is what it works out to in pixels, and
/// every surface that draws a grid has to agree on both. There are two of them
/// now — the herdr pane mirror and a plain PTY — and a second copy of this
/// number would be a second, quietly different, terminal.
const double kTerminalBaseFontSize = 12;
