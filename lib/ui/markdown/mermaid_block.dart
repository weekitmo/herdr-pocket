import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/markdown_palette.dart';
import 'package:mermaid_core/mermaid_core.dart' as mm;
import 'package:mermaid_flutter/mermaid_flutter.dart';

/// A ```mermaid fence, drawn as a diagram.
///
/// ## Why this renders the scene itself instead of using `MermaidDiagram`
///
/// The package's own widget is the obvious entry point and it is the wrong one
/// here for a reason that only shows up in a document: it builds its scene
/// inside `build`, so the FIRST frame it can lay out is already painted at the
/// scene's own size — and a Markdown column measures its children before it
/// paints them. A diagram wider than the phone would lay out at 800 px inside a
/// 360 px column, and everything downstream of it in the list pays for the
/// overflow before the widget gets a chance to scale.
///
/// So the scene is built here, once, up front: the size is then a NUMBER this
/// widget can scale before layout, the failure case is a `try`/`catch` around
/// one call rather than an error-builder that still has to be laid out, and the
/// paint is the same [ScenePainter] either way.
///
/// The cost is that the render is synchronous — parse, ELK layout and text
/// measurement all on the UI thread, measured at ~160 ms for a five-node
/// flowchart on this machine and ~15 ms for a sequence diagram. A block is only
/// built when the lazy list scrolls it into view, which is what keeps that off
/// the page's first frame; a document with a dozen complex diagrams will stutter
/// while scrolling, and moving the render to an isolate is the fix if that ever
/// becomes a real complaint.
class MermaidBlock extends StatefulWidget {
  /// Renders the fence's source.
  const MermaidBlock({required this.source, super.key});

  /// The diagram source, exactly as it appeared between the fences.
  final String source;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  /// The built scene, or null when the source did not render.
  mm.RenderScene? _scene;

  /// What went wrong, when it did.
  Object? _error;

  /// The brightness the current scene was built for.
  ///
  /// The scene carries COLOURS, so a theme change means re-rendering — and
  /// re-rendering on every build would be catastrophic, so the memo key is the
  /// one thing that can change underneath it.
  Brightness? _builtFor;

  void _ensureScene(HerdrColors colors) {
    if (_builtFor == colors.brightness && (_scene != null || _error != null)) {
      return;
    }
    _builtFor = colors.brightness;
    try {
      _scene = mm.Mermaid(
        measurer: const FlutterTextMeasurer(),
        theme: herdrMermaidTheme(colors),
      ).render(widget.source);
      _error = null;
    } on Object catch (error) {
      // A diagram that does not parse is a normal thing to find in a README
      // that is being edited. It is shown as text, in place, with the note that
      // says so — never as a red box and never as an empty gap.
      _scene = null;
      _error = error;
    }
  }

  @override
  void didUpdateWidget(MermaidBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _builtFor = null;
      _scene = null;
      _error = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    _ensureScene(palette.colors);

    final scene = _scene;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(Radii.uniform),
      ),
      child: scene == null
          ? _Failure(source: widget.source)
          : _Diagram(scene: scene),
    );
  }
}

class _Diagram extends StatelessWidget {
  const _Diagram({required this.scene});

  final mm.RenderScene scene;

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final size = Size(scene.size.width, scene.size.height);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, 0),
          child: Row(
            children: [
              Text(
                'mermaid',
                style: TextStyle(
                  color: palette.chipInk,
                  fontSize: TextSize.micro,
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
              ),
              const Spacer(),
              Semantics(
                button: true,
                label: l10n.markdownMermaidZoom,
                child: Icon(
                  // Corners facing OUT: expand. (The similarly named
                  // `CupertinoIcons.fullscreen` is the one that faces in.)
                  CupertinoIcons.fullscreen_exit,
                  size: 14,
                  color: palette.chipInk,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(Space.md),
          // The tap target is the DIAGRAM, not the whole card: a card-wide
          // target would swallow the horizontal drag of a diagram the reader is
          // scrolling to see, and it would make the header's own affordance
          // redundant.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _open(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxInlineHeight),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox.fromSize(
                  size: size,
                  child: CustomPaint(
                    painter: ScenePainter(scene),
                    size: size,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => MermaidViewerPage(scene: scene),
      ),
    );
  }
}

/// The whole diagram, on its own screen, with pan and zoom.
///
/// It takes the SCENE rather than the source: the diagram was already rendered
/// by the block that opened this, and re-rendering it would spend 150 ms
/// showing the user the same picture a moment later.
class MermaidViewerPage extends StatelessWidget {
  /// Shows one rendered scene.
  const MermaidViewerPage({required this.scene, super.key});

  /// The diagram to show.
  final mm.RenderScene scene;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final size = Size(scene.size.width, scene.size.height);

    return CupertinoPageScaffold(
      backgroundColor: colors.groundDeep,
      navigationBar: HerdrTopBar(
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          l10n.markdownMermaidZoom,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
      ),
      child: Center(
        child: InteractiveViewer(
          // Unconstrained, so the scene keeps its own size and the viewer pans
          // over it. Constrained would squeeze the diagram into the screen and
          // there would be nothing left to zoom into.
          constrained: false,
          minScale: 0.4,
          maxScale: 8,
          boundaryMargin: const EdgeInsets.all(Space.xxxl),
          child: SizedBox.fromSize(
            size: size,
            child: CustomPaint(painter: ScenePainter(scene), size: size),
          ),
        ),
      ),
    );
  }
}

/// What a diagram that did not render looks like: the source, and a sentence.
class _Failure extends StatelessWidget {
  const _Failure({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 13,
                color: palette.chipInk,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  l10n.markdownMermaidFailed,
                  style: TextStyle(
                    color: palette.mutedInk,
                    fontSize: TextSize.note,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          // The source is NOT dropped: it is the only thing here the reader can
          // act on, and a Mermaid error is usually one character.
          Text(
            source.trim(),
            style: TextStyle(
              color: palette.chipInk,
              fontSize: TextSize.meta,
              height: 1.4,
              fontFamily: HerdrFonts.mono,
              fontFamilyFallback: HerdrFonts.monoFallback,
            ),
          ),
        ],
      ),
    );
  }
}

/// Maps the app's colours onto the Mermaid renderer's theme.
///
/// The renderer ships a default (light) and a dark theme; what is overridden
/// here is everything that touches a surface, so a diagram looks like it was
/// drawn in this app rather than pasted in from mermaid.live. `background` is
/// TRANSPARENT on purpose — the block behind it already owns the surface, and
/// two rectangles in two nearly-identical colours is how a preview gets grey
/// seams at its corners.
mm.MermaidTheme herdrMermaidTheme(HerdrColors colors) {
  final base = colors.isDark
      ? mm.MermaidTheme.darkTheme
      : mm.MermaidTheme.defaultTheme;
  mm.Color c(Color color) => mm.Color(color.toARGB32());

  return base.copyWith(
    background: mm.Color.transparent,
    primaryColor: c(colors.surface),
    primaryTextColor: c(colors.text),
    primaryBorderColor: c(colors.hairline),
    secondaryColor: c(colors.surfaceRaised),
    lineColor: c(colors.textDim),
    arrowheadColor: c(colors.textDim),
    textColor: c(colors.text),
    nodeBorder: c(colors.hairline),
    mainBkg: c(colors.surface),
    clusterBkg: c(colors.surfaceRaised),
    clusterBorder: c(colors.hairline),
    titleColor: c(colors.text),
    edgeLabelBackground: c(colors.surface),
    // The app's ONE face. A diagram's labels are machine content like
    // everything else this app draws, and the bundled face is the only one that
    // is guaranteed to be on the device.
    fontFamily: HerdrFonts.mono,
    fontSize: TextSize.note,
  );
}

/// How tall a diagram may be inside the document before it stops growing.
///
/// A tall flowchart scaled to the column's width can be several screens high,
/// which buries everything after it; capping the height keeps a preview's
/// proportions readable and leaves the full-size version one tap away.
const double _maxInlineHeight = 440;
