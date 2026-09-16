import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/domain/theme/terminal_palette.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// A colour scheme as a thumbnail: its ground, its ink, and five of its hues.
///
/// Shared between the picker and the settings row that opens it, because those
/// two swatches are the same claim — "this is what the app looks like" — and
/// two drawings of one claim drift apart. It is drawn from the scheme's OWN
/// values rather than hand-painted, so changing the data changes the picture.
///
/// Fixed size, not scaled to whatever row it sits in: a picker is a comparison,
/// and a column of thumbnails at different widths cannot be compared.
class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch({
    required this.ground,
    required this.ink,
    required this.hues,
    this.edge,
    super.key,
  });

  /// One from a terminal scheme, using that scheme's own twenty colours.
  ///
  /// Missing values fall back to the built-in palette rather than to a blank
  /// chip: a swatch that renders as nothing reads as a broken asset, which is a
  /// worse lie than a slightly off-palette preview.
  factory ThemeSwatch.fromPalette(TerminalPalette palette, {Color? edge}) {
    Color of(String hex, Color fallback) =>
        hex.trim().isEmpty ? fallback : HerdrColors.colorFromHex(hex);
    return ThemeSwatch(
      edge: edge,
      ground: of(palette.background, HerdrColors.dark.groundMachine),
      ink: of(palette.foreground, HerdrColors.dark.text),
      hues: [
        for (final name in const ['red', 'yellow', 'green', 'cyan', 'blue'])
          of(palette.hue(name), HerdrColors.dark.textFaint),
      ],
    );
  }

  /// The app's own design, previewed from its own tokens.
  ///
  /// Dark, always, even on the light theme: the built-in palette's dark ground
  /// is what this app looks like in the screenshots, and the row already says
  /// which one you are on with a tick.
  factory ThemeSwatch.builtIn({Color? edge}) => ThemeSwatch(
        edge: edge,
        ground: HerdrColors.dark.ground,
        ink: HerdrColors.dark.text,
        hues: [
          HerdrColors.dark.waiting,
          HerdrColors.dark.died,
          HerdrColors.dark.working,
          HerdrColors.dark.done,
        ],
      );

  final Color ground;
  final Color ink;
  final List<Color> hues;

  /// Border colour, from the CARD's theme rather than the scheme's.
  ///
  /// A light scheme's ground is close to the card it sits on, and without an
  /// edge those rows look like the preview failed to load.
  final Color? edge;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 32,
      decoration: BoxDecoration(
        color: ground,
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: edge == null ? null : Border.all(color: edge!),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Two bars of ink. A scheme whose foreground is unreadable on its own
          // background is a scheme that will be unreadable, and this says so
          // before the user commits rather than after.
          for (final width in const [26.0, 17.0])
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Container(
                width: width,
                height: 3,
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final hue in hues)
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(color: hue, shape: BoxShape.circle),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
