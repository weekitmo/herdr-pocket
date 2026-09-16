import 'package:xterm/core.dart';

/// A run of cells the user has selected, in BUFFER coordinates.
///
/// Buffer coordinates, not screen ones: the viewport moves (the user can scroll
/// back) and screen coordinates would silently mean a different run of text the
/// moment they did. Anchoring to the buffer is what lets a selection survive a
/// scroll, which is exactly when a user is most likely to be making one.
class TerminalSelection {
  const TerminalSelection({
    required this.startLine,
    required this.startColumn,
    required this.endLine,
    required this.endColumn,
  });

  /// A selection built from two corners, normalised so the start is always
  /// before the end regardless of which way the user dragged.
  ///
  /// Dragging upwards is at least half of all selections, and a model that
  /// stores them backwards makes every consumer remember to check.
  factory TerminalSelection.between(
    (int line, int column) a,
    (int line, int column) b,
  ) {
    final aFirst = a.$1 < b.$1 || (a.$1 == b.$1 && a.$2 <= b.$2);
    final first = aFirst ? a : b;
    final last = aFirst ? b : a;
    return TerminalSelection(
      startLine: first.$1,
      startColumn: first.$2,
      endLine: last.$1,
      endColumn: last.$2,
    );
  }

  final int startLine;
  final int startColumn;
  final int endLine;
  final int endColumn;


  bool get isEmpty =>
      startLine == endLine && startColumn == endColumn;

  /// Whether a cell at (line, column) is inside the selection.
  bool contains(int line, int column) {
    if (line < startLine || line > endLine) return false;
    if (startLine == endLine) {
      return column >= startColumn && column < endColumn;
    }
    if (line == startLine) return column >= startColumn;
    if (line == endLine) return column < endColumn;
    return true;
  }

  @override
  String toString() =>
      'TerminalSelection($startLine:$startColumn -> $endLine:$endColumn)';
}

/// Reads the selected text out of a terminal buffer.
///
/// Trailing blanks are trimmed per line — a terminal line is padded to the
/// viewport width and nobody wants to paste 200 spaces — but INNER spaces are
/// preserved, because a path with a space in it is exactly the thing this
/// feature exists to copy correctly.
String selectionText(Terminal terminal, TerminalSelection selection) {
  final lines = terminal.buffer.lines;
  if (lines.length == 0) return '';

  final lastLine = selection.endLine.clamp(0, lines.length - 1);
  final parts = <String>[];
  final cell = CellData.empty();

  for (var lineIndex = selection.startLine; lineIndex <= lastLine; lineIndex++) {
    if (lineIndex < 0 || lineIndex >= lines.length) continue;
    final line = lines[lineIndex];

    final from = lineIndex == selection.startLine ? selection.startColumn : 0;
    final to = lineIndex == selection.endLine
        ? selection.endColumn
        : line.length;

    parts.add(_lineText(line, from, to, cell));
  }

  return parts.join('\n');
}

/// Reads the lines the viewport is currently showing.
///
/// The fallback for Copy when nothing is selected. It takes the WINDOW rather
/// than a coordinate, because the caller is the only thing that knows where the
/// window is — and getting that wrong would copy the wrong screenful, which is
/// worse than copying nothing.
String viewportText(
  Terminal terminal, {
  required int startLine,
  required int rowCount,
}) {
  final lines = terminal.buffer.lines;
  if (lines.length == 0 || rowCount <= 0) return '';

  final cell = CellData.empty();
  final parts = <String>[];
  for (var i = 0; i < rowCount; i++) {
    final index = startLine + i;
    if (index < 0 || index >= lines.length) break;
    parts.add(_lineText(lines[index], 0, lines[index].length, cell));
  }
  return parts.join('\n');
}

/// One line of buffer, trimmed, with wide characters emitted once.
String _lineText(BufferLine line, int from, int to, CellData cell) {
  final run = StringBuffer();
  for (var column = from; column < to && column < line.length; column++) {
    line.getCellData(column, cell);
    final width = (cell.content >> CellContent.widthShift) & 3;
    // The trailing half of a wide character has no glyph of its own; emitting
    // one would duplicate every Han character it follows.
    if (width == 0) continue;
    final code = cell.content & CellContent.codepointMask;
    // Never-written cells hold codepoint 0, which is not a character anyone can
    // copy — see the same rule in the painter.
    run.write(code == 0 ? ' ' : String.fromCharCode(code));
  }
  return _trimTrailing(run.toString());
}

/// Removes trailing whitespace but leaves the rest untouched.
String _trimTrailing(String s) {
  var end = s.length;
  while (end > 0 && (s[end - 1] == ' ' || s[end - 1] == '\u0000')) {
    end--;
  }
  return s.substring(0, end);
}
