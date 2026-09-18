import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';
import 'package:herdr_pocket/ui/markdown/markdown_code_block.dart';
import 'package:herdr_pocket/ui/markdown/markdown_inline.dart';
import 'package:herdr_pocket/ui/markdown/markdown_palette.dart';
import 'package:herdr_pocket/ui/markdown/markdown_table.dart';
import 'package:herdr_pocket/ui/markdown/mermaid_block.dart';
import 'package:markdown/markdown.dart' as md;

/// A Markdown document, rendered in this app's own vocabulary.
///
/// ## Why the document is parsed here and painted by hand
///
/// The obvious route is `flutter_markdown`, which is a layer of Material widgets
/// over the same `markdown` parser this file uses. That would put Material's
/// type ramp, colours and spacing inside a document — in an app whose first hard
/// rule is that there is no Material in it (ADR-004) — and the parts a README
/// actually needs (tables, fenced code, task lists) are exactly the parts a
/// generic renderer is least likely to have opinions about. So the parser is the
/// package's and the LOOK is this app's.
///
/// The list is lazy: a 3000-line README builds the blocks that are on screen,
/// which is what makes opening one on a phone a tap rather than a wait.
class MarkdownView extends StatefulWidget {
  /// Renders [source].
  const MarkdownView({
    required this.source,
    this.header,
    this.onLinkTap,
    super.key,
  });

  /// The document's text.
  final String source;

  /// Drawn as the list's first row — a statement about the document rather than
  /// part of it (a truncated read, chiefly).
  final Widget? header;

  /// Called with a link's `href`. Null leaves links styled but inert.
  final void Function(String url)? onLinkTap;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  List<md.Node> _blocks = const [];

  @override
  void initState() {
    super.initState();
    _blocks = _parse(widget.source);
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _blocks = _parse(widget.source);
    }
  }

  /// The document's top-level blocks.
  ///
  /// `gitHubFlavored` rather than `gitHubWeb`: the web set adds GitHub's
  /// `:emoji:` shortcodes, which this parser turns into IMAGES pointing at
  /// GitHub's CDN — and an image this renderer refuses to fetch would fill a
  /// document with placeholder chips for text nobody asked to be an image. GFM
  /// plus footnotes, tables, task lists and strikethrough is what a README
  /// actually uses.
  ///
  /// `encodeHtml: false` because the AST is not HTML: the escape step exists for
  /// the package's own HTML renderer, and letting it run would put `&amp;` on
  /// screen where the document says `&`.
  static List<md.Node> _parse(String source) {
    var text = source;
    // A byte-order mark arrives from files written on other platforms and would
    // otherwise be rendered as a zero-width character at the top of the page;
    // CR is normalised because the file came over SSH from a machine nobody
    // here has seen.
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    return md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseLines(text.split('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final offset = widget.header == null ? 0 : 1;

    return ListView.builder(
      padding: EdgeInsets.only(
        top: insets.top + Space.md,
        bottom: insets.bottom + Space.xxl,
      ),
      itemCount: _blocks.length + offset,
      itemBuilder: (context, index) {
        if (offset == 1 && index == 0) return widget.header!;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: MarkdownBlock(
            node: _blocks[index - offset],
            base: MarkdownBlock.baseStyleOf(context),
            onLinkTap: widget.onLinkTap,
          ),
        );
      },
    );
  }
}

/// One block of a document.
///
/// Public because the renderer recurses through it: a blockquote and a list item
/// contain BLOCKS, and the recursion has to go through the same dispatch or a
/// quote stops being able to hold a table.
class MarkdownBlock extends StatelessWidget {
  /// Renders [node].
  const MarkdownBlock({
    required this.node,
    required this.base,
    this.onLinkTap,
    super.key,
  });

  /// The block to render.
  final md.Node node;

  /// The style text starts from, and the one a nested block inherits.
  final TextStyle base;

  /// Passed down to inline content.
  final void Function(String url)? onLinkTap;

  /// The style a document's prose is set in.
  ///
  /// Read from the theme rather than written here so a document is the same
  /// colour as the app around it. The line height is the one number in this file
  /// with no token: prose is the only place in the app where a line is read as a
  /// line rather than scanned, and 1.55 is what makes a paragraph of Chinese and
  /// a paragraph of English feel equally aired.
  static TextStyle baseStyleOf(BuildContext context) => TextStyle(
    color: MarkdownPalette.of(context).ink,
    fontSize: TextSize.body,
    height: 1.55,
  );

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    final node = this.node;

    if (node is md.Text) return Text(node.text, style: base);
    if (node is! md.Element) return const SizedBox.shrink();

    return switch (node.tag) {
      'p' => _paragraph(palette, node),
      'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => _heading(palette, node),
      'ul' || 'ol' => _list(palette, node),
      'blockquote' => _quote(palette, node),
      'pre' => _code(palette, node),
      'table' => Padding(
        padding: const EdgeInsets.only(bottom: Space.lg),
        child: MarkdownTable(
          table: node,
          base: base,
          onLinkTap: onLinkTap,
        ),
      ),
      'hr' => _rule(palette),
      // An element this renderer has no opinion about — a `div` that came in as
      // raw HTML, a footnote definition. Its CHILDREN are the document's own
      // words, so they are rendered as blocks rather than dropped.
      _ => _children(node),
    };
  }

  Widget _paragraph(MarkdownPalette palette, md.Element element) => Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: InlineMarkdownText(
      nodes: element.children ?? const <md.Node>[],
      style: base,
      palette: palette,
      onLinkTap: onLinkTap,
    ),
  );

  /// One heading, at the rung its level picks off the app's type scale.
  ///
  /// Six levels over seven rungs on purpose: `h1` is the page's large title
  /// because a README's first heading IS the page's title, and the two deepest
  /// levels are close together because a document that uses `#####` has already
  /// stopped relying on size to make its point.
  Widget _heading(MarkdownPalette palette, md.Element element) {
    final size = switch (element.tag) {
      'h1' => TextSize.largeTitle,
      'h2' => TextSize.headline,
      'h3' => TextSize.title,
      'h4' => TextSize.strong,
      'h5' => TextSize.note,
      _ => TextSize.meta,
    };
    final isTop = element.tag == 'h1' || element.tag == 'h2';
    final style = base.copyWith(
      fontSize: size,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: palette.ink,
    );

    final heading = InlineMarkdownText(
      nodes: element.children ?? const <md.Node>[],
      style: style,
      palette: palette,
      onLinkTap: onLinkTap,
    );

    return Padding(
      padding: EdgeInsets.only(
        top: isTop ? Space.lg : Space.md,
        bottom: Space.sm,
      ),
      // A rule under the first two levels, and nowhere else: it is what makes a
      // long README readable as sections, and past `##` the size step is
      // already carrying the hierarchy.
      child: isTop
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                const SizedBox(height: Space.sm),
                SizedBox(
                  height: 1,
                  child: ColoredBox(color: palette.hairline),
                ),
              ],
            )
          : heading,
    );
  }

  Widget _list(MarkdownPalette palette, md.Element element) {
    final ordered = element.tag == 'ol';
    final start = int.tryParse(element.attributes['start'] ?? '') ?? 1;

    final items = <md.Element>[];
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'li') items.add(child);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            _listItem(
              palette,
              items[i],
              marker: ordered ? '${start + i}.' : '\u2022',
            ),
        ],
      ),
    );
  }

  Widget _listItem(
    MarkdownPalette palette,
    md.Element item, {
    required String marker,
  }) {
    final checkbox = _checkboxOf(palette, item);
    final children = <md.Node>[
      for (final child in item.children ?? const <md.Node>[])
        // The `input` a task list item carries is REPLACED by the drawn box
        // below, not rendered as a control: this is a document, and a checkbox
        // the reader can tap would be a lie about what tapping does.
        if (!(child is md.Element && child.tag == 'input')) child,
    ];

    final blocks = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (i == 0 && child is md.Element && child.tag == 'p') {
        // The first paragraph sits ON the marker's line rather than under it,
        // which is what makes a list read as a list.
        blocks.add(
          InlineMarkdownText(
            nodes: child.children ?? const <md.Node>[],
            style: base,
            palette: palette,
            onLinkTap: onLinkTap,
          ),
        );
      } else {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: MarkdownBlock(
              node: child,
              base: base,
              onLinkTap: onLinkTap,
            ),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _markerWidth,
            child: Align(
              alignment: Alignment.topRight,
              child: checkbox ?? _markerText(marker, palette),
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: blocks,
            ),
          ),
        ],
      ),
    );
  }

  Widget _markerText(String marker, MarkdownPalette palette) => Text(
    marker,
    style: base.copyWith(color: palette.mutedInk, height: 1.55),
  );

  /// The drawn box for a task list item, or null when it is an ordinary one.
  Widget? _checkboxOf(MarkdownPalette palette, md.Element item) {
    final isTask = (item.attributes['class'] ?? '').split(' ').contains(
      'task-list-item',
    );
    if (!isTask) return null;

    var checked = false;
    for (final child in item.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'input') {
        checked = child.attributes['checked'] == 'true';
        break;
      }
    }

    final accent = palette.colors.accent;
    return Padding(
      // Nudged down onto the first line's baseline box. A checkbox is a shape,
      // not a glyph, so it has no baseline to align to and the four pixels have
      // to be chosen.
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: checked ? accent : null,
            border: Border.all(
              color: checked ? accent : palette.colors.hairline,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: checked
              ? Icon(
                  CupertinoIcons.check_mark,
                  size: 9,
                  color: palette.colors.surface,
                )
              : null,
        ),
      ),
    );
  }

  Widget _quote(MarkdownPalette palette, md.Element element) => Container(
    margin: const EdgeInsets.only(bottom: Space.md),
    padding: const EdgeInsets.only(left: Space.md),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(width: 3, color: palette.rule),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in element.children ?? const <md.Node>[])
          MarkdownBlock(
            node: child,
            base: base.copyWith(color: palette.mutedInk),
            onLinkTap: onLinkTap,
          ),
      ],
    ),
  );

  Widget _code(MarkdownPalette palette, md.Element element) {
    final code = _firstChild(element, 'code');
    final source = _textOf(code ?? element);
    final info = code?.attributes['class'];

    if (languageId(info) == 'mermaid') {
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.lg),
        child: MermaidBlock(source: source),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: MarkdownCodeBlock(code: source, language: info),
    );
  }

  Widget _rule(MarkdownPalette palette) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.lg),
    child: SizedBox(height: 1, child: ColoredBox(color: palette.hairline)),
  );

  Widget _children(md.Element element) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final child in element.children ?? const <md.Node>[])
        MarkdownBlock(node: child, base: base, onLinkTap: onLinkTap),
    ],
  );
}

/// Wide enough for the longest marker a list can have (`9999.` at this size)
/// and no wider, so the text of every item in a document starts at the same
/// column whether it is bulleted or numbered.
const double _markerWidth = 24;

/// The first descendant with this tag, or null.
md.Element? _firstChild(md.Element element, String tag) {
  for (final child in element.children ?? const <md.Node>[]) {
    if (child is md.Element && child.tag == tag) return child;
  }
  return null;
}

/// Every text descendant, in order.
String _textOf(md.Element element) {
  final buffer = StringBuffer();
  void walk(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is md.Text) {
        buffer.write(node.text);
      } else if (node is md.Element) {
        walk(node.children ?? const <md.Node>[]);
      }
    }
  }

  walk(element.children ?? const <md.Node>[]);
  // The fence's own newline. `MarkdownCodeBlock` renders what it is given, and a
  // trailing empty line inside a bordered block is a visible extra row.
  var text = buffer.toString();
  if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
  return text;
}
