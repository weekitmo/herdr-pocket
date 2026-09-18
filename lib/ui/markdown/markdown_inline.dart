import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/markdown_palette.dart';
import 'package:markdown/markdown.dart' as md;

/// Inline markdown — the text INSIDE a paragraph, a heading, a table cell — as
/// one rich [Text].
///
/// A widget rather than a function because links need gesture recognizers and
/// recognizers need an owner. `TextSpan.recognizer` must be disposed exactly
/// once, and a `build` method has no `dispose`; building them per frame leaks
/// one recognizer per link per frame, which is the classic way this is got
/// wrong. Here they are created lazily, kept for the life of the block, and
/// released in [dispose].
///
/// [onLinkTap] is injected rather than implemented: this file knows how a link
/// looks, and the page decides what tapping one does.
class InlineMarkdownText extends StatefulWidget {
  /// Renders [nodes] at [style].
  const InlineMarkdownText({
    required this.nodes,
    required this.style,
    required this.palette,
    this.textAlign = TextAlign.start,
    this.onLinkTap,
    this.maxLines,
    super.key,
  });

  /// The inline nodes of one block.
  final List<md.Node> nodes;

  /// The base style. Roles adjust colour and weight; they never set a font, so
  /// a document cannot re-introduce a face this app does not use.
  final TextStyle style;

  /// The code-block palette, used for inline `code` spans.
  final MarkdownPalette palette;

  final TextAlign textAlign;
  final int? maxLines;

  /// Called with a link's `href`. Null leaves links styled but inert.
  final void Function(String url)? onLinkTap;

  @override
  State<InlineMarkdownText> createState() => _InlineMarkdownTextState();
}

class _InlineMarkdownTextState extends State<InlineMarkdownText> {
  /// One recognizer per distinct href, reused across rebuilds.
  final Map<String, TapGestureRecognizer> _links = {};

  @override
  void dispose() {
    for (final recognizer in _links.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  void _activate(String url) => widget.onLinkTap?.call(url);

  TapGestureRecognizer _recognizerFor(String url) {
    final existing = _links[url];
    if (existing != null) {
      existing.onTap = () => _activate(url);
      return existing;
    }
    _links[url] = TapGestureRecognizer()..onTap = () => _activate(url);
    return _links[url]!;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return Text.rich(
      TextSpan(
        style: style,
        children: buildInlineSpans(
          widget.nodes,
          style,
          widget.palette,
          recognizerFor: _recognizerFor,
          imageLabel: AppLocalizations.of(context).markdownImage,
        ),
      ),
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
    );
  }
}

/// Flattens inline markdown nodes into spans.
///
/// Split out of the widget because the SPANS are what a test wants to inspect —
/// "the bold run is bold", "the code run is monospace on its own background" —
/// and that needs no widget tree.
///
/// [recognizerFor] is how links get their gesture handling; the caller owns the
/// recognizers.
List<InlineSpan> buildInlineSpans(
  List<md.Node> nodes,
  TextStyle style,
  MarkdownPalette palette, {
  TapGestureRecognizer Function(String url)? recognizerFor,
  String imageLabel = 'image',
}) {
  final spans = <InlineSpan>[];
  _appendInline(spans, nodes, style, palette, recognizerFor, imageLabel);
  return spans;
}

void _appendInline(
  List<InlineSpan> out,
  List<md.Node> nodes,
  TextStyle style,
  MarkdownPalette palette,
  TapGestureRecognizer Function(String url)? recognizerFor,
  String imageLabel,
) {
  for (final node in nodes) {
    switch (node) {
      // Text can carry a newline: the markdown parser keeps a soft line break
      // as `\n` inside a Text node, and this app renders it as a LINE BREAK
      // rather than as a space. That is what GitHub does with a README, and a
      // README is the document being previewed — a wrapped paragraph that
      // reflows on a phone would look different from the browser the author
      // wrote it in.
      case final md.Text text:
        out.add(TextSpan(text: text.text));
      case final md.Element element:
        _appendElement(out, element, style, palette, recognizerFor, imageLabel);
      default:
        break;
    }
  }
}

void _appendElement(
  List<InlineSpan> out,
  md.Element element,
  TextStyle style,
  MarkdownPalette palette,
  TapGestureRecognizer Function(String url)? recognizerFor,
  String imageLabel,
) {
  final children = element.children ?? const <md.Node>[];
  switch (element.tag) {
    case 'br':
      out.add(const TextSpan(text: '\n'));
    case 'strong' || 'b':
      _appendInline(
        out,
        children,
        style.copyWith(fontWeight: FontWeight.w600),
        palette,
        recognizerFor,
        imageLabel,
      );
    case 'em' || 'i':
      _appendInline(
        out,
        children,
        style.copyWith(fontStyle: FontStyle.italic),
        palette,
        recognizerFor,
        imageLabel,
      );
    case 'del' || 's':
      _appendInline(
        out,
        children,
        style.copyWith(decoration: TextDecoration.lineThrough),
        palette,
        recognizerFor,
        imageLabel,
      );
    case 'code':
      // Inline code keeps the app's own face (it is already monospace) and is
      // separated by its background rather than by a different font — the
      // difference between prose and a command has to survive at 13 pt.
      out.add(
        TextSpan(
          text: _textOf(element),
          style: style.copyWith(
            color: palette.codeInk,
            backgroundColor: palette.codeBackground,
          ),
        ),
      );
    case 'a':
      final href = element.attributes['href'] ?? '';
      out.add(
        TextSpan(
          text: _textOf(element),
          style: style.copyWith(
            color: palette.link,
            decoration: TextDecoration.underline,
            decorationColor: palette.link.withValues(alpha: 0.4),
          ),
          recognizer: href.isEmpty ? null : recognizerFor?.call(href),
        ),
      );
    case 'img':
      out.add(_imageSpan(element, style, palette, imageLabel));
    default:
      // An inline element this renderer does not know (raw HTML that reached
      // the inline parser, a footnote reference, `sub`). Its TEXT is still the
      // document's words, so the children are rendered in the current style
      // rather than dropped.
      _appendInline(out, children, style, palette, recognizerFor, imageLabel);
  }
}

/// An image, as a placeholder chip.
///
/// NOT fetched, and the reason is not laziness: the bytes are on the other side
/// of an SSH connection that is already the slowest part of the app, the
/// document's own read is capped at 256 KB, and a README's images are often
/// relative paths that mean nothing outside the repository. A visible,
/// honest chip — `alt` text, or the file name when there is no alt — says "an
/// image belongs here and this is what it is" instead of drawing a broken box
/// or silently dropping it.
WidgetSpan _imageSpan(
  md.Element element,
  TextStyle style,
  MarkdownPalette palette,
  String imageLabel,
) {
  final alt = element.attributes['alt'] ?? '';
  final src = element.attributes['src'] ?? '';
  final label = alt.isNotEmpty ? alt : _basename(src);
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.chipBackground,
          borderRadius: BorderRadius.circular(Radii.uniform),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.sm,
            vertical: 2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.photo,
                size: 12,
                color: palette.chipInk,
              ),
              const SizedBox(width: Space.xs),
              Text(
                label.isEmpty ? imageLabel : label,
                style: style.copyWith(
                  color: palette.chipInk,
                  fontSize: TextSize.meta,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The plain text of an element, ignoring any nested markup.
///
/// Used where a subtree has to become ONE span — inline code and links — and
/// where nested emphasis inside a link is a difference that does not survive.
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
  return buffer.toString();
}

String _basename(String path) {
  final slash = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(slash + 1) : path;
}
