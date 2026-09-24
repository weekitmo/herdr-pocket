import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// One picture, fitted to the page, with a tap that opens it full screen.
///
/// It takes a CHILD rather than bytes because two kinds of picture arrive here:
/// a PNG/JPEG/GIF, whose bytes the engine decodes, and an SVG, whose text the
/// SVG renderer draws. Both want the same frame — centred, fitted, tappable,
/// with the same full-screen viewer behind them — and only the widget in the
/// middle differs.
///
/// Fitted rather than cropped, because the case this exists for is a screenshot
/// an agent produced: a phone screenshot is taller than the page and a wide
/// diagram is wider, and one rule ("show all of it") answers both. A viewer that
/// cropped would make the reader hunt for the edges of a picture whose size they
/// cannot see.
class ImagePreview extends StatelessWidget {
  /// Frames [child], which must be the picture itself.
  const ImagePreview({required this.child, super.key});

  /// The widest decode this app will make, in pixels.
  ///
  /// About the DECODE, not the transfer: a 48-megapixel photo is 190 MB of
  /// bitmap, and a phone that is also holding an SSH session and a terminal will
  /// be killed for asking. 4096 px is wider than any phone's screen, so the cap
  /// costs nothing visible; what it prevents is the app dying on the one
  /// screenshot that happened to come off a camera. The engine does not upscale,
  /// so a small image is passed through untouched.
  static const maxDecodeWidth = 4096;

  /// The picture. A `Image.memory` or an `SvgPicture.string`.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final insets = MediaQuery.paddingOf(context);

    return Padding(
      padding: EdgeInsets.only(
        top: insets.top + Space.md,
        bottom: insets.bottom + Space.xl,
        left: Space.md,
        right: Space.md,
      ),
      // EXPANDED, and that is about the tap target rather than about layout. An
      // `Image` with no dimensions of its own sits in a box the size of its
      // decoded bitmap, and before the decode finishes that box is ZERO — so a
      // `Center` around it leaves a picture whose tap target does not exist
      // yet. Filling the area and letting `BoxFit.contain` do the fitting paints
      // the same pixels and makes the whole frame tappable, which is also the
      // forgiving behaviour a photo viewer is expected to have.
      child: Semantics(
        button: true,
        label: l10n.fileImageZoom,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: SizedBox.expand(child: child),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => ImageViewerPage(child: child)),
    );
  }
}

/// The same picture, on its own screen, with pan and zoom.
///
/// `constrained: true` (the default) rather than the Mermaid viewer's
/// `constrained: false`: a diagram has a size of its own and wants the viewer to
/// pan over it, while a picture has a size measured in PIXELS and wants to start
/// fitted to the screen. Zooming in then scales the fitted widget, and the
/// detail comes from the decoded texture rather than from a re-decode.
class ImageViewerPage extends StatelessWidget {
  /// Shows one picture full screen.
  const ImageViewerPage({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      // One shade under the page's ground, so the picture is the only thing on
      // the screen that is not the app — the same move the diagram viewer makes.
      backgroundColor: colors.groundDeep,
      navigationBar: HerdrTopBar(
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          l10n.fileImageZoom,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
      ),
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 8,
        child: Center(child: child),
      ),
    );
  }
}
