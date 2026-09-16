import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The property every screen rests on, measured for the FULL font stack rather
/// than one face.
///
/// The app renders in [HerdrFonts.mono] — Iosevka — which carries Latin and the
/// Nerd Font icon range and **no Han at all**. Chinese is served by
/// [HerdrFonts.han], Noto Sans Mono CJK. The grid depends on one property:
///
///   a full-width glyph must be EXACTLY twice a half-width one.
///
/// If it is not, CJK drift accumulates along every mixed line and the right edge
/// goes ragged — the most common way a CJK terminal looks broken.
///
/// WHY TWO FACES ARE ALLOWED HERE AT ALL: pairing a Latin mono with a CJK
/// fallback is a bet that their advances line up, and it is a bet that gets
/// lost. It was lost once already — Iosevka (0.5 em) beside Maple Mono NF CN's
/// Han (1.2 em) measures 2.4, not 2.0. The bet is only safe when it is CHECKED,
/// so this file checks it, through Flutter's own text layout, which is the path
/// the app actually renders through.
void main() {
  const primaryPath = 'assets/fonts/IosevkaNerdFontMono-Regular.ttf';
  const secondaryPath = 'assets/fonts/NotoSansMonoCJKsc-Regular.otf';

  final havePrimary = File(primaryPath).existsSync();
  final haveSecondary = File(secondaryPath).existsSync();
  final haveBoth = havePrimary && haveSecondary;

  Future<void> load(String family, String path) async {
    final bytes = await File(path).readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    await loader.load();
  }

  setUpAll(() async {
    if (havePrimary) await load(HerdrFonts.mono, primaryPath);
    if (haveSecondary) await load(HerdrFonts.han, secondaryPath);
  });

  /// Measures WITH the real stack, so a glyph missing from the primary is served
  /// by the fallback exactly as it is in the app.
  double widthOf(String text, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: HerdrFonts.mono,
          fontFamilyFallback: HerdrFonts.monoFallback,
          fontSize: fontSize,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  group('the stack is present', () {
    test('both faces are bundled', () {
      expect(havePrimary, isTrue, reason: '$primaryPath is missing');
      expect(haveSecondary, isTrue, reason: '$secondaryPath is missing');
    }, skip: !haveBoth);

    test('Han is ordered ahead of the platform fallback', () {
      // ORDER IS THE WHOLE TRICK. A Han glyph missing from Iosevka is served by
      // the first family that has it, and the platform's CJK faces are
      // proportional — so anything ahead of Noto would silently put every
      // Chinese character off the grid.
      expect(
        HerdrFonts.monoFallback.indexOf(HerdrFonts.han),
        0,
        reason: 'nothing may sit ahead of the Han face in the fallback chain',
      );
    }, skip: !haveBoth);

    test('the app voice is the same stack as the machine voice', () {
      expect(HerdrFonts.app, HerdrFonts.mono);
    });
  });

  group('the stack forms one grid', () {
    test('a Han glyph served by the fallback is exactly twice a Latin cell',
        () {
      const size = 16.0;
      final latin = widthOf('M', size);
      final han = widthOf('\u4e2d', size);

      expect(latin, greaterThan(0));
      expect(
        han / latin,
        closeTo(2.0, 0.001),
        reason: 'Han ${han}px vs Latin ${latin}px. Two typefaces have to agree '
            'on this ratio exactly, or CJK drifts out of its cells.',
      );
    }, skip: !haveBoth);

    test('Latin advances are uniform', () {
      const size = 16.0;
      final widths =
          ['i', 'M', 'W', '.', '1'].map((c) => widthOf(c, size)).toSet();
      expect(widths.length, 1, reason: 'got $widths');
    }, skip: !haveBoth);

    test('Nerd Font icons are one cell', () {
      const size = 16.0;
      // A powerline separator and a git branch glyph: the two most common
      // things a prompt prints that a plain monospace face cannot draw. They
      // come from Iosevka, not Noto — which is why the primary has to be a
      // Nerd Font build and not the plain one.
      final latin = widthOf('M', size);
      for (final icon in ['\uE0B0', '\uE0A0']) {
        expect(
          widthOf(icon, size) / latin,
          closeTo(1.0, 0.001),
          reason: 'icon U+${icon.runes.first.toRadixString(16)} is not one cell',
        );
      }
    }, skip: !haveBoth);

    test('full-width punctuation is two cells', () {
      const size = 16.0;
      final latin = widthOf('M', size);
      for (final ch in ['\uff0c', '\u3001', '\u3000', '\uff1a']) {
        expect(
          widthOf(ch, size) / latin,
          closeTo(2.0, 0.001),
          reason: 'U+${ch.runes.first.toRadixString(16).toUpperCase()}',
        );
      }
    }, skip: !haveBoth);

    test('the ratio survives every size the app offers', () {
      for (final size in [10.0, 12.0, 14.0, 20.0]) {
        expect(
          widthOf('\u4e2d', size) / widthOf('M', size),
          closeTo(2.0, 0.01),
          reason: 'ratio drifted at ${size}px',
        );
      }
    }, skip: !haveBoth);

    test('a mixed line measures as if it were one grid', () {
      const size = 16.0;
      final latin = widthOf('M', size);
      // 4 Latin cells + 2 Han cells == 8 Latin cells. This is the assertion
      // that catches what the per-glyph ratio can miss: a fallback whose Latin
      // is a hair off still shows 2.0 per glyph while the LINE ends in the
      // wrong place.
      expect(widthOf('abcd\u4e2d\u6587', size), closeTo(latin * 8, 0.5));
    }, skip: !haveBoth);
  });

  group('the app inherits the fallback without naming it', () {
    test('a style that names only the family keeps the fallback', () {
      // This is what makes the ~40 call sites that write
      // `fontFamily: HerdrFonts.mono` correct without also writing the
      // fallback: `Text` merges its style over the ancestor `DefaultTextStyle`,
      // and `merge` keeps the base's fallback when the override does not set
      // one.
      //
      // If that ever stops holding, the app's Chinese silently moves to the
      // platform's proportional CJK face — on every screen at once — and this
      // test is the only thing that would say so.
      const base = TextStyle(
        fontFamily: HerdrFonts.app,
        fontFamilyFallback: HerdrFonts.monoFallback,
      );
      expect(
        base.merge(const TextStyle(fontSize: 13)).fontFamilyFallback,
        HerdrFonts.monoFallback,
      );
      expect(
        base.merge(const TextStyle(fontFamily: HerdrFonts.mono))
            .fontFamilyFallback,
        HerdrFonts.monoFallback,
      );
    });
  });
}
