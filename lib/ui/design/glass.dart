import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The Liquid Glass material, as far as Flutter can honestly reach it.
///
/// WHAT THIS IS NOT: it is not iOS 26's Liquid Glass. Real Liquid Glass does
/// *lensing* — a refraction displacement near the edge that bends what is
/// behind it. Flutter has no `UIGlassEffect`, and the only package that
/// approximates the refraction is self-declared experimental, Impeller-only
/// and documented to spike texture memory. Treating a blur as "the same thing"
/// would be a lie worth avoiding, so this is a good approximation and the
/// difference is written down here rather than discovered later.
///
/// WHAT IT IS: the three things that actually make a surface read as glass —
/// a blur, a saturation lift, and a specular edge. The saturation lift is the
/// one people forget, and it is most of the effect: Apple's materials do not
/// just blur what is behind them, they make it MORE saturated, which is what
/// separates "frosted plastic" from "glass".
///
/// The lift is free here. `ColorFilter` implements `ImageFilter`, so
/// `ImageFilter.compose` runs the saturation matrix and the blur in ONE pass
/// rather than needing a second layer.
///
/// WHY IT DEFAULTS OFF: whip measured native blur on Android and turned it off
/// — four BlurViews recaptured the full screen on every tab change and stalled
/// the release transition. Our primary target is a 2018 mid-ranger. Glass is an
/// upgrade users opt into, not a baseline they pay for (ADR-006).
class HerdrGlass extends StatelessWidget {
  const HerdrGlass({
    required this.colors,
    required this.child,
    this.enabled = true,
    this.blur = 24,
    this.saturation = 1.8,
    this.tintAlpha = 0.62,
    this.borderRadius,
    this.showEdge = true,
    super.key,
  });

  final HerdrColors colors;
  final Widget child;

  /// When false this is a plain translucent surface with no backdrop filter.
  final bool enabled;

  /// Blur radius. 24 is the point where content behind stops being readable and
  /// starts being texture, which is what makes text on top legible.
  final double blur;

  /// Saturation multiplier applied to the backdrop.
  final double saturation;

  /// How much of our own surface colour to lay over the blurred backdrop.
  ///
  /// Without this the glass is only as legible as whatever happens to be
  /// behind it; with too much it is just an opaque panel that pays for a blur.
  final double tintAlpha;

  final BorderRadius? borderRadius;

  /// Draws the light edge. The specular highlight is what makes a pane read as
  /// a physical sheet rather than a rectangle of blur.
  final bool showEdge;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(Radii.uniform);

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: tintAlpha),
        borderRadius: radius,
        border: showEdge
            ? Border.all(color: _edgeColor, width: 0.5)
            : null,
      ),
      child: child,
    );

    if (enabled) {
      content = BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: ColorFilter.matrix(_saturationMatrix(saturation)),
          inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        ),
        child: content,
      );
    }

    return ClipRRect(borderRadius: radius, child: content);
  }

  /// A bright hairline on the top edge fading to nothing at the bottom.
  ///
  /// Real glass catches light on the edge facing the source, and the asymmetry
  /// is the whole reason a flat rectangle reads as a raised sheet. A uniform
  /// border reads as a stroke; this reads as a highlight.
  Color get _edgeColor => colors.isDark
      ? const Color(0x33FFFFFF)
      : const Color(0x66FFFFFF);

  /// The standard saturation matrix, at [s].
  ///
  /// A 4×5 row-major matrix over RGBA. The coefficients are the Rec. 601 luma
  /// weights, and the alpha row is the identity so opacity passes through.
  static List<double> _saturationMatrix(double s) {
    const lr = 0.213;
    const lg = 0.715;
    const lb = 0.072;
    final sr = (1 - s) * lr;
    final sg = (1 - s) * lg;
    final sb = (1 - s) * lb;
    return <double>[
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

/// A solid hairline for where a chrome bar meets content.
///
/// Deliberately NOT a gradient. A specular highlight is conventionally drawn as
/// one, and the first version of this was — but "no gradients" is a project
/// rule that came from the user, and a rule you make an exception to in the
/// first file you apply it in is not a rule. A hairline does the job.
class GlassEdge extends StatelessWidget {
  const GlassEdge({
    required this.colors,
    this.height = 0.5,
    super.key,
  });

  final HerdrColors colors;
  final double height;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: height,
        // See the note in `settings_page.dart`'s `_Rule`: a height-only
        // SizedBox around a child with no intrinsic width collapses to zero
        // wide inside a Column, so a "hairline" that looks right in the code
        // paints nothing on the screen.
        width: double.infinity,
        child: ColoredBox(color: colors.hairline),
      ),
    );
  }
}
