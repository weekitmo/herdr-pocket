import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/markdown_inline.dart';
import 'package:herdr_pocket/ui/markdown/markdown_palette.dart';
import 'package:markdown/markdown.dart' as md;

/// A GFM table.
///
/// ## Why this is not a wrapped paragraph of pipes
///
/// A table is the one construct in a README that carries a grid, and the phone
/// is the one device that cannot show a wide grid. So the table scrolls
/// HORIZONTALLY, per column, and the columns keep their natural widths — a
/// two-column table of short values stays two narrow columns, and a table of
/// prose caps each column at [_maxCellWidth] rather than letting the longest
/// sentence decide the width of the whole document.
///
/// The alternative — shrinking every cell to fit the screen — makes a
/// four-column table of command outputs illegible, which is exactly the table
/// somebody opens a README on a phone to read.
class MarkdownTable extends StatelessWidget {
  /// Renders one table node.
  const MarkdownTable({
    required this.table,
    required this.base,
    this.onLinkTap,
    super.key,
  });

  /// The `table` element from the document.
  final md.Element table;

  /// The text style cells start from. Roles adjust colour and weight only.
  final TextStyle base;

  /// Passed through to inline content, so a link in a cell behaves like a link
  /// in a paragraph.
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    final rows = _rows(table);
    if (rows.isEmpty) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.uniform),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          // Horizontal rules only. A full grid draws a box around every cell,
          // which on a phone reads as a spreadsheet; one rule between rows is
          // what GitHub draws and what keeps the header legible as a header.
          border: TableBorder(
            horizontalInside: BorderSide(color: palette.tableRule),
          ),
          children: [
            for (final (index, row) in rows.indexed)
              _rowWidget(
                context,
                row,
                isHeader: index == 0 && _isHeaderRow(row),
                palette: palette,
              ),
          ],
        ),
      ),
    );
  }

  /// One row of the table.
  ///
  /// `TableRow` needs one child per column, so a short row is PADDED rather
  /// than left short: a table with a ragged last column is legal markdown, and
  /// a `Table` that throws on it would turn a rendering nit into a blank
  /// preview.
  TableRow _rowWidget(
    BuildContext context,
    List<md.Element> cells, {
    required bool isHeader,
    required MarkdownPalette palette,
  }) {
    final columns = _columnCount(table);
    return TableRow(
      decoration: isHeader ? BoxDecoration(color: palette.surface) : null,
      children: [
        for (var i = 0; i < columns; i++)
          if (i < cells.length)
            _cell(context, cells[i], isHeader: isHeader, palette: palette)
          else
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    md.Element cell, {
    required bool isHeader,
    required MarkdownPalette palette,
  }) {
    final style = isHeader
        ? base.copyWith(
            fontWeight: FontWeight.w600,
            color: palette.ink,
            fontSize: TextSize.note,
          )
        : base.copyWith(color: palette.mutedInk);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxCellWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        child: InlineMarkdownText(
          nodes: cell.children ?? const <md.Node>[],
          style: style,
          palette: palette,
          textAlign: _alignmentOf(cell),
          onLinkTap: onLinkTap,
        ),
      ),
    );
  }

  /// Every row in the table, header first.
  ///
  /// The header is pulled out of `thead` rather than assumed to be row zero:
  /// the markdown parser emits a table WITHOUT a `thead` when the header row is
  /// empty, in which case there is no header and the first body row must not be
  /// styled as one.
  static List<List<md.Element>> _rows(md.Element table) {
    final rows = <List<md.Element>>[];
    for (final section in table.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      if (section.tag != 'thead' && section.tag != 'tbody') continue;
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'tr') continue;
        rows.add(
          [
            for (final cell in row.children ?? const <md.Node>[])
              if (cell is md.Element) cell,
          ],
        );
      }
    }
    return rows;
  }

  static bool _isHeaderRow(List<md.Element> row) =>
      row.isNotEmpty && row.first.tag == 'th';

  /// How many columns the table has, taken from its widest row.
  ///
  /// NOT from the header: an empty header row is legal, and so is a body row
  /// with a cell the header does not have.
  static int _columnCount(md.Element table) {
    var columns = 0;
    for (final row in _rows(table)) {
      if (row.length > columns) columns = row.length;
    }
    return columns;
  }

  static TextAlign _alignmentOf(md.Element cell) =>
      switch (cell.attributes['align']) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.start,
      };
}

/// The widest a single cell may be before it becomes its own scroll surface.
///
/// Sized so a two-column table of prose fits a 360 dp phone at `body` without
/// the reader having to pan for every line, and so a wide table's columns stay
/// narrow enough to compare at a glance.
const double _maxCellWidth = 240;
