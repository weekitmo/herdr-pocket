import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/workspace_palette.dart';

/// The three claims `WorkspacePalette`'s doc comment makes, re-derived here.
///
/// A comment that says "checked for pairwise distance and text contrast" is a
/// comment that was true once, when somebody ran the numbers by hand. These
/// tests compute them from the constants, so the claim fails the build the moment
/// a colour is edited rather than the day a user notices that workspaces 2 and 7
/// look the same.
///
/// THE MATHS IS IN THIS FILE ON PURPOSE. Converting sRGB to CIE Lab is twenty
/// lines, and the alternative — adding a colour-science package to a client whose
/// whole dependency budget is a terminal emulator — would be a worse trade.
void main() {
  group('the chip a workspace wears', () {
    test('is a function of the workspace NUMBER, so it survives a rebuild', () {
      // The daemon numbers workspaces from 1. The same number must give the same
      // entry every time: a colour that re-rolls on rebuild is noise, not
      // identity.
      for (var n = 1; n <= WorkspacePalette.size; n++) {
        expect(WorkspacePalette.indexOf(n), n - 1);
        expect(WorkspacePalette.indexOf(n), WorkspacePalette.indexOf(n));
      }
      // It cycles rather than running off the end: workspace 11 wears what 1
      // wears. Ten distinct colours is the whole budget; a table that grew with
      // the machine would end in two shades of the same purple.
      expect(WorkspacePalette.indexOf(11), 0);
      expect(WorkspacePalette.indexOf(14), 3);
    });

    test('gives the synthetic zero-numbered tab a chip rather than an index '
        'error', () {
      // `workspaces_page` synthesises a tab with number 0 for panes whose tab
      // the daemon did not list. It has no badge today, and this is here so that
      // giving it one is a two-line change rather than a crash.
      expect(WorkspacePalette.indexOf(0), 0);
      expect(WorkspacePalette.indexOf(-3), 0);
    });

    test('the two modes are different colours, not the same table twice', () {
      // A deep fill on a dark ground and a mid fill on white are different
      // problems; if these lists ever become equal, somebody collapsed them.
      expect(WorkspacePalette.light, isNot(equals(WorkspacePalette.dark)));
      expect(WorkspacePalette.backgroundFor(
        number: 1,
        brightness: Brightness.light,
      ), WorkspacePalette.light[0]);
      expect(WorkspacePalette.backgroundFor(
        number: 1,
        brightness: Brightness.dark,
      ), WorkspacePalette.dark[0]);
      // An unset/unusual brightness must not fall off the table.
      expect(
        WorkspacePalette.backgroundFor(number: 4, brightness: Brightness.light),
        WorkspacePalette.light[3],
      );
    });
  });

  group('the claims in the doc comment are true of the constants', () {
    test('white digits are legible on every chip, in both modes', () {
      for (final entry in {
        'light': WorkspacePalette.light,
        'dark': WorkspacePalette.dark,
      }.entries) {
        for (var i = 0; i < entry.value.length; i++) {
          final ratio = _contrast(WorkspacePalette.foreground, entry.value[i]);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key}[$i] ${_hex(entry.value[i])} gives white '
                '${ratio.toStringAsFixed(2)}:1 — below the 4.5:1 floor for '
                'text this size',
          );
        }
      }
    });

    test('no two chips are close enough to confuse', () {
      // ΔE 12 is well clear of the ~2.3 "just noticeable" threshold and covers
      // the real question — telling two chips apart across a room, on a phone,
      // in peripheral vision.
      for (final entry in {
        'light': WorkspacePalette.light,
        'dark': WorkspacePalette.dark,
      }.entries) {
        final table = entry.value;
        for (var i = 0; i < table.length; i++) {
          for (var j = i + 1; j < table.length; j++) {
            final distance = _deltaE(table[i], table[j]);
            expect(
              distance,
              greaterThanOrEqualTo(12),
              reason: '${entry.key}[$i] and [$j] are ΔE '
                  '${distance.toStringAsFixed(1)} apart',
            );
          }
        }
      }
    });

    test('neighbouring workspaces get colours nobody could confuse', () {
      // THE COMPARISON THE READER ACTUALLY MAKES IS BETWEEN NEIGHBOURS: two
      // group headers a screen apart, or the one above and the one below. The
      // floor here is deliberately much higher than the all-pairs one — the
      // table's ORDER exists to buy exactly this, and walking the hues in order
      // would fail this test at ΔE 14.7.
      const floor = 40.0;
      for (final entry in {
        'light': WorkspacePalette.light,
        'dark': WorkspacePalette.dark,
      }.entries) {
        final table = entry.value;
        for (var i = 0; i < table.length; i++) {
          // The cyclic pair matters: index 9 and index 0 are workspace 10 and
          // workspace 11, which a machine with eleven workspaces shows together.
          final next = table[(i + 1) % table.length];
          final distance = _deltaE(table[i], next);
          expect(
            distance,
            greaterThanOrEqualTo(floor),
            reason: '${entry.key}[$i] ${_hex(table[i])} and the next chip '
                '${_hex(next)} are only ΔE ${distance.toStringAsFixed(1)} apart',
          );
        }
      }
    });

    test('no chip can be mistaken for a status colour', () {
      // THE RULE THIS PALETTE IS ONLY ALLOWED TO EXIST UNDER. If a workspace
      // chip ever lands on the amber that means "an agent is waiting for you",
      // the colour stops meaning one thing and starts meaning two.
      final statuses = <String, Color>{
        'waiting': HerdrColors.dark.waiting,
        'died': HerdrColors.dark.died,
        'working': HerdrColors.dark.working,
        'done': HerdrColors.dark.done,
      };
      for (final table in [
        WorkspacePalette.light,
        WorkspacePalette.dark,
      ]) {
        for (final chip in table) {
          for (final status in statuses.entries) {
            final distance = _deltaE(chip, status.value);
            expect(
              distance,
              greaterThanOrEqualTo(15),
              reason: 'chip ${_hex(chip)} is ΔE '
                  '${distance.toStringAsFixed(1)} from the '
                  '${status.key} status colour',
            );
          }
        }
      }
    });
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

/// CIE76 ΔE — the plain Euclidean distance in Lab.
///
/// CIE76 rather than CIEDE2000 because this is a floor, not a colour-matching
/// study: a palette that clears ΔE 12 by CIE76 is unambiguously distinguishable,
/// and CIEDE2000's extra terms would only matter for a palette that is already
/// failing.
double _deltaE(Color a, Color b) {
  final la = _lab(a);
  final lb = _lab(b);
  final dl = la[0] - lb[0];
  final da = la[1] - lb[1];
  final db = la[2] - lb[2];
  return math.sqrt(dl * dl + da * da + db * db);
}

List<double> _lab(Color c) {
  double linear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(((c.toARGB32() >> 16) & 0xFF) / 255);
  final g = linear(((c.toARGB32() >> 8) & 0xFF) / 255);
  final b = linear((c.toARGB32() & 0xFF) / 255);

  final x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047;
  final y = r * 0.2126 + g * 0.7152 + b * 0.0722;
  final z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883;

  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  final fx = f(x);
  final fy = f(y);
  final fz = f(z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
