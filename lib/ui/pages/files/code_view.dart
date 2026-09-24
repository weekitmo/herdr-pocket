import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';

/// A file's text, with a line-number gutter, syntax colours and a selection.
///
/// Three things in one widget because they are one decision: the gutter has to
/// stay aligned with the text (so they are siblings in a row, never two columns
/// that can drift), the colours have to come from the same run list the text
/// does, and the selection has to include the code while excluding the numbers.
///
/// ## Why the gutter is not selectable
///
/// Selecting a few lines and tapping Copy is the most likely thing a reader does
/// with a source file, and `  12` in front of every line turns the result into
/// something that has to be cleaned before it can be pasted anywhere. The gutter
/// is therefore wrapped in a [SelectionContainer.disabled] — the documented way
/// to take a subtree out of a selection.
///
/// ## Why [SelectableRegion] and not `SelectionArea`
///
/// `SelectionArea` is the Material library's wrapper — it lives in
/// `package:flutter/material.dart`, and importing it would turn this project's
/// no-Material rule into a matter of trust. [SelectableRegion] is the widget
/// underneath it, and the two things `SelectionArea` adds are supplied here by
/// hand: Cupertino selection handles, and a Cupertino context menu built from
/// the region's own button items. The app looks Apple-flavoured on Android too,
/// which is the whole point of the rule.
class CodeView extends StatelessWidget {
  /// Shows [source], optionally with [lines] pre-tokenised.
  const CodeView({
    required this.source,
    this.lines,
    this.header,
    super.key,
  });

  /// The whole text, as read. Used for the plain rendering, and for the line
  /// count when highlighting has not arrived (or has no grammar to arrive
  /// with).
  final String source;

  /// The tokenised lines, in the same order and the same number as the text's.
  ///
  /// Null means "not highlighted yet", which is a state the reader sees: the
  /// file is on screen immediately in one ink, and the colours appear when the
  /// tokeniser — which for a 256 KB file is hundreds of milliseconds of work,
  /// done in an isolate — comes back. Holding the file back until then would
  /// make the page slower for no gain.
  final List<CodeLine>? lines;

  /// Drawn as the list's first row when there is something to say about the
  /// text below it (a truncated read, chiefly).
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final palette = CodePalette.of(colors.brightness);

    final runs = lines ?? _plainLines(source);

    // Room for the floating bar, read from the scaffold rather than written
    // out: the top value here IS the bar's height, which is what lets the code
    // disappear underneath it as the page scrolls.
    final insets = MediaQuery.paddingOf(context);
    final offset = header == null ? 0 : 1;

    final base = TextStyle(
      color: palette.plain,
      fontSize: TextSize.note,
      height: 1.5,
      fontFamily: HerdrFonts.mono,
      fontFamilyFallback: HerdrFonts.monoFallback,
    );

    return SelectableRegion(
      selectionControls: cupertinoTextSelectionHandleControls,
      contextMenuBuilder: (context, state) =>
          CupertinoAdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        // COPY ONLY, and the omissions are the point. The default list on
        // Android is Copy, Share, Select All — and "all" here means the rows
        // that happen to have been BUILT, because the list is lazy. A Select
        // All that silently copies forty of four thousand lines is worse than
        // no Select All, because the result looks like a whole file in the
        // paste box. Copying the whole file has its own row in the sheet, where
        // it can say what it copies.
        buttonItems: state.contextMenuButtonItems
            .where((item) => item.type == ContextMenuButtonType.copy)
            .toList(),
      ),
      child: ListView.builder(
        padding: EdgeInsets.only(
          top: insets.top + Space.md,
          bottom: insets.bottom + Space.md,
        ),
        itemCount: runs.length + offset,
        itemBuilder: (context, i) {
          if (header != null && i == 0) return header!;
          return _CodeLine(
            number: i + 1 - offset,
            runs: runs[i - offset],
            base: base,
            palette: palette,
            gutter: colors.textFaint,
          );
        },
      ),
    );
  }

  /// The text as one plain run per line, for when there is nothing to colour
  /// with yet.
  static List<CodeLine> _plainLines(String source) => [
        for (final line in splitSourceLines(source))
          CodeLine([CodeRun(line)]),
      ];
}

/// One numbered line.
class _CodeLine extends StatelessWidget {
  const _CodeLine({
    required this.number,
    required this.runs,
    required this.base,
    required this.palette,
    required this.gutter,
  });

  final int number;
  final CodeLine runs;
  final TextStyle base;
  final CodePalette palette;
  final Color gutter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: SizedBox(
              width: 36,
              child: Text(
                '$number',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: gutter,
                  fontSize: TextSize.meta,
                  height: 1.5,
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text.rich(
              // A blank line is an empty run list; giving it a space keeps the
              // row's height identical to every other row, so the gutter cannot
              // drift out of step with the text.
              TextSpan(
                style: base,
                children: [
                  for (final run in runs.runs)
                    TextSpan(
                      text: run.text,
                      style: codeStyle(run, base, palette),
                    ),
                  if (runs.runs.isEmpty) const TextSpan(text: ' '),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
