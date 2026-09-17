import 'package:flutter/widgets.dart';

/// The colour a workspace's number is drawn in.
///
/// WHY THIS EXISTS, GIVEN THE HOUSE RULE. `HerdrColors` states the product's
/// first design law: colour is MEANING, not decoration, and the four status hues
/// are meant to be the only colour in the app. This is not a hole in that rule —
/// it is the one thing the rule was missing. On a machine with ten workspaces,
/// every group header looks identical, and "which group am I looking at" is a
/// question the number alone answers only if you read it. A hue answers it in
/// peripheral vision, and identity is a meaning.
///
/// THE RULE THAT KEEPS IT HONEST: **this palette may only ever be used for
/// IDENTITY, and identity is a NUMBERED CHIP.** It is deliberately kept out of
/// the status vocabulary — every entry sits at least ΔE 21 from all four status
/// colours, which is roughly twice the "clearly different" threshold, and no
/// entry is ever a dot, a border, or a bar. A coloured square with a digit in it
/// that could be mistaken for the amber "needs you" alarm would be worse than no
/// colour at all.
///
/// NOT RANDOM, AND THAT IS THE POINT. "Pick a colour at random" is the obvious
/// reading of the request and the wrong implementation: a colour that changes on
/// every rebuild, or that changes when the daemon renumbers a workspace, is noise
/// rather than identity. The colour is a pure function of the workspace NUMBER,
/// so a given workspace wears the same colour for as long as it has that number —
/// across restarts, theme changes and reconnects.
///
/// WHY A TABLE AND NOT A HUE ROTATION. Ten hues spaced 36° apart with equal
/// relative luminance reads as ten colours of the same weight. Generating them
/// from HSL at a fixed lightness does not: yellow at the same lightness is nearly
/// twice as luminous as blue, so a yellow chip shouts and a blue chip whispers.
/// The tables below were solved for a constant luminance per mode (Y = 0.16 light,
/// 0.115 dark) and checked for pairwise distance and text contrast — see
/// `test/ui/workspace_palette_test.dart`, which re-derives all three numbers from
/// the constants rather than trusting this comment.
abstract final class WorkspacePalette {
  /// How many colours there are before the cycle repeats.
  static const int size = 10;

  /// Which entry a workspace number wears.
  ///
  /// Numbered from 1 by the daemon. Zero or negative is not a workspace — the
  /// workspaces page synthesises a zero-numbered tab for panes whose tab the
  /// daemon did not list — so it takes the first entry rather than crashing or
  /// going negative.
  static int indexOf(int number) =>
      number <= 0 ? 0 : (number - 1) % size;

  /// The digits, on every chip, in both modes.
  ///
  /// White rather than a tint of the chip for a measurable reason: white on
  /// these backgrounds is at least 5:1, and tinting the text toward its own
  /// background would spend most of that on a difference nobody can see.
  static const Color foreground = Color(0xFFFFFFFF);

  /// Light-mode chips: white text on a mid-tone fill, min contrast 5.0:1.
  ///
  /// THE ORDER IS NOT THE HUE ORDER, and that is the point of the table: these
  /// are assigned by workspace NUMBER, and the comparison a reader actually makes
  /// is between two numbers that sit near each other on a page. Walking the hues
  /// in order put workspace 9 and workspace 10 in two neighbouring pinks — ΔE
  /// 14.7, distinguishable and not obviously different. This order was chosen to
  /// maximise the distance between CONSECUTIVE entries instead, which takes the
  /// worst adjacent pair from ΔE 14.7 to **ΔE 78.7** (and that floor includes the
  /// wrap from the tenth chip back to the first, which is what workspace 11
  /// wears). The all-pairs floor is unchanged at 14.7.
  static const List<Color> light = <Color>[
    Color(0xFFB0562F),
    Color(0xFF22802B),
    Color(0xFF5865D3),
    Color(0xFF7A7120),
    Color(0xFF8F4FD0),
    Color(0xFF4E7B21),
    Color(0xFFBC32AE),
    Color(0xFF217D62),
    Color(0xFFCA3662),
    Color(0xFF297799),
  ];

  /// Dark-mode chips: the same ten hues, deeper, min contrast 6.3:1.
  ///
  /// Deeper rather than identical because a screen at night has no white behind
  /// the chip to compete with, and the light set glares on a dark ground.
  static const List<Color> dark = <Color>[
    Color(0xFF924C2E),
    Color(0xFF226D2A),
    Color(0xFF4653C5),
    Color(0xFF686121),
    Color(0xFF7E3CC0),
    Color(0xFF456921),
    Color(0xFF9D3292),
    Color(0xFF226B55),
    Color(0xFFA83557),
    Color(0xFF286680),
  ];

  /// The chip for one workspace, in one mode.
  static Color backgroundFor({
    required int number,
    required Brightness brightness,
  }) {
    final table = brightness == Brightness.dark ? dark : light;
    return table[indexOf(number)];
  }
}
