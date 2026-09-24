import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';
import 'package:herdr_pocket/ui/markdown/markdown_palette.dart';

/// The syntax palette's contrast, recomputed from the constants.
///
/// A comment that claims "measured, all above 4.5:1" is worth nothing a week
/// later: one darkened green for a different reason and the comment stays while
/// the number does not. Every role is measured here against the surface it is
/// actually painted on, so a change that makes a comment invisible in sunlight
/// fails the build instead of shipping — the same discipline as
/// `workspace_palette_test.dart`, for the same reason.
void main() {
  group('the code palette clears AA as text, in both brightnesses', () {
    for (final colors in [HerdrColors.dark, HerdrColors.light]) {
      final palette = CodePalette.of(colors.brightness);
      final surface = MarkdownPalette(colors: colors, code: palette).surface;

      // A Map rather than a list of pairs so a failure names the role.
      final roles = <String, Color>{
        'plain': palette.plain,
        'keyword': palette.keyword,
        'string': palette.string,
        'number': palette.number,
        'comment': palette.comment,
        'function': palette.function,
        'type': palette.type,
        'attribute': palette.attribute,
        'punctuation': palette.punctuation,
        'inserted': palette.inserted,
        'deleted': palette.deleted,
      };

      for (final entry in roles.entries) {
        test('${colors.brightness.name}: ${entry.key}', () {
          final ratio = _contrast(entry.value, surface);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${entry.key} is ${_hex(entry.value)} on ${_hex(surface)} — '
                '${ratio.toStringAsFixed(2)}:1, below AA for text.',
          );
        });
      }
    }
  });

  test('the same palette is legible on the PAGE, where the code viewer paints', () {
    // The Markdown code block paints the palette on `surfaceRaised`; the file
    // preview paints it straight onto the page's `ground`. The measured numbers
    // above are the block's, so the page's are recomputed here rather than
    // assumed: a palette that is only legible on one of the two surfaces is a
    // palette that was checked once.
    for (final colors in [HerdrColors.dark, HerdrColors.light]) {
      final palette = CodePalette.of(colors.brightness);
      for (final entry in <String, Color>{
        'plain': palette.plain,
        'keyword': palette.keyword,
        'string': palette.string,
        'number': palette.number,
        'comment': palette.comment,
        'function': palette.function,
        'type': palette.type,
        'attribute': palette.attribute,
        'punctuation': palette.punctuation,
        'inserted': palette.inserted,
        'deleted': palette.deleted,
      }.entries) {
        final ratio = _contrast(entry.value, colors.ground);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: '${colors.brightness.name} ${entry.key} on the page: '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    }
  });

  test('inline code is readable on its own background', () {
    for (final colors in [HerdrColors.dark, HerdrColors.light]) {
      final palette = MarkdownPalette(
        colors: colors,
        code: CodePalette.of(colors.brightness),
      );
      final ratio = _contrast(palette.codeInk, palette.codeBackground);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: '${colors.brightness.name}: ${ratio.toStringAsFixed(2)}:1',
      );
      // And the inline background must be DISTINGUISHABLE from the page, or the
      // command inside a sentence has no shape at all.
      expect(
        _contrast(palette.codeBackground, palette.colors.ground),
        greaterThan(1.05),
        reason: '${colors.brightness.name}: the inline code surface is the page',
      );
    }
  });

  test('body, muted and link text clear AA on the page', () {
    for (final colors in [HerdrColors.dark, HerdrColors.light]) {
      final palette = MarkdownPalette(
        colors: colors,
        code: CodePalette.of(colors.brightness),
      );
      for (final (name, color) in [
        ('ink', palette.ink),
        ('mutedInk', palette.mutedInk),
        ('link', palette.link),
      ]) {
        expect(
          _contrast(color, palette.colors.ground),
          greaterThanOrEqualTo(4.5),
          reason: '${colors.brightness.name}: $name',
        );
      }
    }
  });
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Relative luminance, WCAG 2.1.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = channel(((c.toARGB32() >> 16) & 0xFF) / 255);
  final g = channel(((c.toARGB32() >> 8) & 0xFF) / 255);
  final b = channel((c.toARGB32() & 0xFF) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}
