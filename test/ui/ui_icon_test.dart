import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/components/ui_icons.g.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The themed icon set.
///
/// The bug this file was written after is the reason it exists: in the mono
/// variant every colour slot was painted the same ink, and because slots 2 and
/// 3 are details drawn ON TOP of slot 1's fill, three icons silently became
/// blobs — the overflow icon lost its dots, the split icon lost its dividers,
/// the server lost its lights. Nothing threw, `flutter analyze` was clean, and
/// it was only visible on a rendered screen.
void main() {
  const colors = HerdrColors.dark;

  setUp(resetUiIconCache);

  List<Color> stops(
    UiIconVariant variant, {
    Color? background,
    bool filled = true,
  }) => iconStops(
    variant: variant,
    colors: colors,
    mono: const Color(0xFF99A0BC),
    background: background ?? colors.surface,
    filled: filled,
  );

  test('every named icon has a template', () {
    for (final name in UiIconName.values) {
      expect(
        uiIconTemplates[name.asset],
        isNotNull,
        reason: '${name.name} has no template — re-run tool/fetch_ui_icons.py',
      );
    }
  });

  test('no template ships an unresolved colour slot', () {
    for (final name in UiIconName.values) {
      for (final variant in UiIconVariant.values) {
        final svg = themedIcon(name, stops(variant));
        expect(
          svg.contains('__C'),
          isFalse,
          reason: '${name.name} / ${variant.name} kept a placeholder',
        );
        expect(svg, contains('<svg'));
      }
    }
  });

  test('mono paints the detail slots in the GROUND, not in the ink', () {
    // The regression above. Slots 2 and 3 sit on top of slot 1's fill, so
    // painting them the same ink erases them.
    const ground = Color(0xFF123456);
    final result = stops(UiIconVariant.mono, background: ground);
    expect(result[0], result[1], reason: 'outline and fill are one ink');
    expect(result[2], ground);
    expect(result[3], ground);
    expect(result[2], isNot(result[1]));
  });

  test('the themed variant introduces no hue the app does not already have',
      () {
    final filled = stops(UiIconVariant.themed);
    expect(filled[0], colors.text);
    expect(filled[1], colors.accent);
    // The details sit ON the accent body, so they are the ground colour rather
    // than a fourth hue — there is no fourth hue in this app's palette to
    // reach for, and ink on accent is mud.
    expect(filled[2], colors.surface);
    expect(filled[3], colors.surface);
  });

  test('outline mode empties the body and inks the details', () {
    // The dock marks its selected tab with a filled glyph and the rest with an
    // outline, from the SAME asset: slot 1 is the body, so painting it the
    // ground turns the drawing into its own outline version.
    const ground = Color(0xFF123456);
    final outline = stops(UiIconVariant.themed, background: ground, filled: false);
    expect(outline[0], colors.text);
    expect(outline[1], ground, reason: 'the body must not be filled');
    expect(outline[2], colors.text, reason: 'details are on the ground now');
    expect(outline[3], colors.text);
    expect(outline, isNot(stops(UiIconVariant.themed, background: ground)));
  });

  test('the fixed variant is fixed', () {
    // Not theme-derived, and that is the thing being compared — so a change to
    // it is a change of mind, not a refactor.
    final dark = stops(UiIconVariant.showcase);
    expect(dark.first, const Color(0xFF1B1B1F));
    expect(stops(UiIconVariant.showcase), dark);
  });

  test('resolution is cached per icon and palette', () {
    final a = themedIcon(UiIconName.more, stops(UiIconVariant.mono));
    final b = themedIcon(UiIconName.more, stops(UiIconVariant.mono));
    final c = themedIcon(UiIconName.more, stops(UiIconVariant.showcase));
    expect(identical(a, b), isTrue, reason: 'the cache missed');
    expect(a, isNot(c));
  });
}
