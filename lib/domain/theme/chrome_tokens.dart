/// Deriving an app's chrome from a terminal palette.
///
/// THE POINT OF THIS FILE: it makes "support N themes" cheap and safe. Every
/// surface, line and text colour is computed from the 20 colours of a terminal
/// scheme, and every text colour is pushed until it clears a WCAG contrast
/// ratio against the surface it sits on. A scheme nobody has ever tested
/// against our layout therefore cannot produce unreadable text — the worst case
/// is a theme that looks plain, not a theme that cannot be read.
///
/// The arithmetic is the published client's (see
/// `docs/research/09-moshi-theme-colors.md`), reimplemented here because the
/// *rules* are worth keeping even where the values are not:
///
///  * [mix] works in plain sRGB, NOT linearised. Designers pick colours by eye
///    in sRGB, and blending in linear space moves every mid-tone away from what
///    they chose.
///  * [luminance] and [contrastRatio] ARE gamma-correct, because WCAG says so.
///  * [enforce] walks toward black or white by bisection until the ratio is met
///    — bisection rather than a formula because the luminance curve bends, and
///    an approximate answer here would be an approximate promise about
///    readability.
///
/// One deliberate difference from the source: the STATUS colours here are never
/// borrowed from the accent. This app's rule is that a status colour means a
/// status and nothing else, so `warn`/`danger`/`working` come from the
/// scheme's own yellow/red/blue.
library;

import 'dart:math' as math;

import 'package:herdr_pocket/domain/theme/terminal_palette.dart';

/// Every colour the app chrome is made of, as hex strings.
///
/// Named after ROLES rather than appearances (`bgDeep` is "the furthest-back
/// surface", not "the dark grey"), so a light theme and a dark theme share one
/// name set without either of them lying.
class ChromeTokens {
  const ChromeTokens({
    required this.bgDeep,
    required this.bgCard,
    required this.bgTerm,
    required this.line,
    required this.lineSoft,
    required this.lineFrame,
    required this.ink,
    required this.inkMid,
    required this.inkDim,
    required this.inkFaint,
    required this.accent,
    required this.accentDim,
    required this.warn,
    required this.danger,
    required this.diffAdd,
    required this.diffDel,
    required this.syntaxPurple,
    required this.syntaxBlue,
    required this.syntaxOrange,
    required this.syntaxYellow,
    required this.syntaxTeal,
    required this.waiting,
    required this.died,
    required this.working,
    required this.done,
  });

  /// Reads a `chrome` override block from a theme file.
  ///
  /// Every field is required even though the palette's are not: a
  /// half-specified chrome would silently mix hand-picked colours with derived
  /// ones, and the result would be a theme that is neither. A theme that wants
  /// an override supplies all of it.
  factory ChromeTokens.fromJson(Map<String, Object?> json) => ChromeTokens(
        bgDeep: _required(json, 'bgDeep'),
        bgCard: _required(json, 'bgCard'),
        bgTerm: _required(json, 'bgTerm'),
        line: _required(json, 'line'),
        lineSoft: _required(json, 'lineSoft'),
        lineFrame: _required(json, 'lineFrame'),
        ink: _required(json, 'ink'),
        inkMid: _required(json, 'inkMid'),
        inkDim: _required(json, 'inkDim'),
        inkFaint: _required(json, 'inkFaint'),
        accent: _required(json, 'accent'),
        accentDim: _required(json, 'accentDim'),
        warn: _required(json, 'warn'),
        danger: _required(json, 'danger'),
        diffAdd: _required(json, 'diffAdd'),
        diffDel: _required(json, 'diffDel'),
        syntaxPurple: _required(json, 'syntaxPurple'),
        syntaxBlue: _required(json, 'syntaxBlue'),
        syntaxOrange: _required(json, 'syntaxOrange'),
        syntaxYellow: _required(json, 'syntaxYellow'),
        syntaxTeal: _required(json, 'syntaxTeal'),
        waiting: _required(json, 'waiting'),
        died: _required(json, 'died'),
        working: _required(json, 'working'),
        done: _required(json, 'done'),
      );

  final String bgDeep;
  final String bgCard;
  final String bgTerm;
  final String line;
  final String lineSoft;
  final String lineFrame;
  final String ink;
  final String inkMid;
  final String inkDim;
  final String inkFaint;
  final String accent;
  final String accentDim;
  final String warn;
  final String danger;
  final String diffAdd;
  final String diffDel;
  final String syntaxPurple;
  final String syntaxBlue;
  final String syntaxOrange;
  final String syntaxYellow;
  final String syntaxTeal;

  /// The four agent states, each from the scheme's own hue.
  ///
  /// Separate fields rather than the UI reaching for `syntaxYellow` when it
  /// wants "waiting": a colour that means a MEANING and a colour that means a
  /// LANGUAGE both get reused eventually, and the meaning is the one that must
  /// not drift.
  final String waiting;
  final String died;
  final String working;
  final String done;

  /// The contrasts this theme actually achieves.
  ///
  /// Read by the theme test (every bundled theme must clear the floors) and by
  /// anything that wants to explain why a theme looks the way it does.
  Map<String, double> get keyContrasts => {
        'ink/bgDeep': contrastRatio(ink, bgDeep),
        'ink/bgCard': contrastRatio(ink, bgCard),
        'inkMid/bgDeep': contrastRatio(inkMid, bgDeep),
        'accent/bgCard': contrastRatio(accent, bgCard),
        'warn/bgCard': contrastRatio(warn, bgCard),
        'danger/bgCard': contrastRatio(danger, bgCard),
      };
}

/// Minimum ratios, by what the text is FOR.
///
/// Not one number: body text at 3:1 is unreadable, and a decorative rule at
/// 7:1 is a black line. These tiers are why a derived theme is legible instead
/// of merely present.
abstract final class ContrastFloor {
  /// Primary body text. WCAG AAA.
  static const double body = 7;

  /// Secondary text, labels, hints. WCAG AA.
  static const double secondary = 4.5;

  /// Status colours, icons and other large shapes.
  static const double shape = 3;

  /// Syntax highlighting — dense and small, so a little above [shape].
  static const double syntax = 3.2;

  /// Tertiary text: timestamps, counts, captions. Deliberately below AA,
  /// because the point of a third step is that it recedes.
  static const double dim = 3.2;

  /// Quaternary text: the quietest label the app still means to be read.
  static const double faint = 2.4;
}

/// Builds the chrome for [palette].
///
/// [isDark] decides the direction. The two directions are separate constants
/// rather than one sign flip on purpose: in a dark theme the card steps 3%
/// toward white, and in a light one it steps 60% — the same distance in the
/// opposite direction would be invisible on one side and blinding on the other.
ChromeTokens deriveChrome({
  required TerminalPalette palette,
  required bool isDark,
}) {
  final background = palette.background;
  final card = isDark
      ? mix(background, '#ffffff', 0.03)
      : mix(background, '#ffffff', 0.6);
  final deep = isDark
      ? mix(background, '#000000', 0.22)
      : mix(background, '#ffffff', 0.3);

  // THE HARDER OF THE TWO SURFACES, which is not the same one in both modes.
  //
  // In a dark theme text is light, so the LIGHTER surface (the card) is the
  // hard one. In a light theme text is dark, so the DARKER surface (the app
  // ground) is. Enforcing against the card alone left three light themes at
  // 4.3-4.4:1 on the ground — found by the bundled-theme contrast test, and the
  // kind of thing nobody notices until somebody reads a timestamp outdoors.
  final hardest = isDark ? card : deep;
  final ink = enforce(
    mix(palette.foreground, isDark ? '#ffffff' : '#000000', isDark ? 0.5 : 0.45),
    hardest,
    ContrastFloor.body,
  );

  final blue = palette.hue('blue');
  final yellow = palette.hue('yellow');
  final red = palette.hue('red');
  final green = palette.hue('green');
  final cyan = palette.hue('cyan');
  final magenta = palette.hue('magenta');

  final accent = enforce(blue, card, ContrastFloor.shape);

  return ChromeTokens(
    bgTerm: background,
    bgDeep: deep,
    bgCard: card,
    ink: ink,
    // Every text step is enforced against [hardest] (see above).
    //
    // Plain mixing alone was not enough — this was found by a bundled theme
    // (Solarized Light) where a 36%-toward-background blend lands at 2.3:1.
    inkMid: enforce(mix(ink, background, isDark ? 0.36 : 0.55), hardest, ContrastFloor.secondary),
    // The last two steps carry a weaker floor ON PURPOSE: they are meta text
    // and timestamps, and forcing them to 4.5:1 would erase the hierarchy they
    // exist to express. 3.2 keeps them dim without being decorative.
    inkDim: enforce(mix(ink, background, isDark ? 0.66 : 0.55), hardest, ContrastFloor.dim),
    inkFaint: enforce(mix(ink, background, isDark ? 0.76 : 0.68), hardest, ContrastFloor.faint),
    line: mix(deep, ink, isDark ? 0.11 : 0.14),
    lineSoft: mix(deep, ink, isDark ? 0.065 : 0.08),
    lineFrame: mix(deep, ink, isDark ? 0.16 : 0.2),
    accent: accent,
    accentDim: isDark
        ? mix(accent, background, 0.25)
        : enforce(blue, card, ContrastFloor.secondary),

    // Status colours, each from its OWN hue. Deliberately never the accent:
    // "this needs you" and "this is the primary action" must not be the same
    // colour, or one of the two meanings is lost.
    warn: enforce(yellow, card, ContrastFloor.shape),
    danger: enforce(red, card, ContrastFloor.shape),
    diffAdd: isDark
        ? mix(green, '#ffffff', 0.35)
        : enforce(green, card, ContrastFloor.secondary),
    diffDel: isDark
        ? mix(red, '#ffffff', 0.35)
        : enforce(red, card, ContrastFloor.secondary),
    syntaxPurple: enforce(isDark ? mix(magenta, '#ffffff', 0.1) : magenta, card, ContrastFloor.syntax),
    syntaxBlue: enforce(isDark ? mix(blue, '#ffffff', 0.1) : blue, card, ContrastFloor.syntax),
    syntaxOrange: enforce(
      isDark ? mix(mix(red, yellow, 0.5), '#ffffff', 0.1) : mix(red, yellow, 0.5),
      card,
      ContrastFloor.syntax,
    ),
    syntaxYellow: enforce(isDark ? mix(yellow, '#ffffff', 0.1) : yellow, card, ContrastFloor.syntax),
    syntaxTeal: enforce(isDark ? mix(cyan, '#ffffff', 0.1) : cyan, card, ContrastFloor.syntax),
    waiting: enforce(yellow, card, ContrastFloor.shape),
    died: enforce(red, card, ContrastFloor.shape),
    // `working` takes the scheme's CYAN, not its blue.
    //
    // The accent is the blue, and deriving both from it with the same floor
    // makes them the same colour — which this app does not allow: a status
    // colour means a status, and the accent means "this is a button". Cyan is
    // adjacent enough to read as the same cool "active" family and far enough
    // to be told apart at dot size. Found by the distinctness test below, not
    // by looking at it.
    working: enforce(cyan, card, ContrastFloor.shape),
    done: enforce(green, card, ContrastFloor.shape),
  );
}

/// Applies the TEXT floors to a hand-written chrome.
///
/// An override is used verbatim with exactly one exception: the two text
/// colours are pushed if they miss the floors everything else is held to. The
/// bundled override misses by 0.07 of a ratio — imperceptible — and the
/// alternative is a theme exempt from the one promise this whole feature makes.
/// Accents and status colours are left alone: they are shapes, and their
/// contrast is the theme's own business.
///
/// Both surfaces are checked, because secondary text sits on cards AND on the
/// app ground, and pushing for one can leave the other short.
ChromeTokens enforceTextFloors(ChromeTokens chrome) {
  var ink = enforce(chrome.ink, chrome.bgCard, ContrastFloor.body);
  ink = enforce(ink, chrome.bgDeep, ContrastFloor.body);

  var inkMid = enforce(chrome.inkMid, chrome.bgCard, ContrastFloor.secondary);
  inkMid = enforce(inkMid, chrome.bgDeep, ContrastFloor.secondary);

  return ChromeTokens(
    bgDeep: chrome.bgDeep,
    bgCard: chrome.bgCard,
    bgTerm: chrome.bgTerm,
    line: chrome.line,
    lineSoft: chrome.lineSoft,
    lineFrame: chrome.lineFrame,
    ink: ink,
    inkMid: inkMid,
    inkDim: chrome.inkDim,
    inkFaint: chrome.inkFaint,
    accent: chrome.accent,
    accentDim: chrome.accentDim,
    warn: chrome.warn,
    danger: chrome.danger,
    diffAdd: chrome.diffAdd,
    diffDel: chrome.diffDel,
    syntaxPurple: chrome.syntaxPurple,
    syntaxBlue: chrome.syntaxBlue,
    syntaxOrange: chrome.syntaxOrange,
    syntaxYellow: chrome.syntaxYellow,
    syntaxTeal: chrome.syntaxTeal,
    waiting: chrome.waiting,
    died: chrome.died,
    working: chrome.working,
    done: chrome.done,
  );
}

/// Blends [a] toward [b] by [t] in plain sRGB.
String mix(String a, String b, double t) {
  final ar = rgb(a);
  final br = rgb(b);
  final clamped = t.clamp(0.0, 1.0);
  return hex(
    (ar.$1 + (br.$1 - ar.$1) * clamped).round(),
    (ar.$2 + (br.$2 - ar.$2) * clamped).round(),
    (ar.$3 + (br.$3 - ar.$3) * clamped).round(),
  );
}

/// WCAG relative luminance. Gamma-correct, unlike [mix].
double luminance(String color) {
  final (r, g, b) = rgb(color);
  double channel(int v) {
    final s = v / 255;
    return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

/// WCAG contrast ratio, 1.0 (identical colours) to 21.0 (black on white).
double contrastRatio(String a, String b) {
  final la = luminance(a);
  final lb = luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Pushes [color] toward black or white until it clears [ratio] against
/// [background].
String enforce(String color, String background, double ratio) {
  if (contrastRatio(color, background) >= ratio) return color;
  final toward = luminance(background) > 0.5 ? '#000000' : '#ffffff';
  // If even the extreme cannot reach the ratio, the extreme is the best there
  // is; returning it beats looping forever or returning something worse.
  if (contrastRatio(toward, background) < ratio) return toward;

  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 18; i++) {
    final mid = (low + high) / 2;
    if (contrastRatio(mix(color, toward, mid), background) >= ratio) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return mix(color, toward, high);
}

/// `#rgb`, `#rrggbb` and `rgba(...)` — the gallery uses all three.
(int, int, int) rgb(String value) {
  final text = value.trim();
  if (text.startsWith('rgb')) {
    final open = text.indexOf('(');
    final close = text.lastIndexOf(')');
    if (open < 0 || close <= open) return (0, 0, 0);
    final parts = text.substring(open + 1, close).split(',');
    if (parts.length < 3) return (0, 0, 0);
    int channel(String s) =>
        (double.tryParse(s.trim()) ?? 0).round().clamp(0, 255);
    return (channel(parts[0]), channel(parts[1]), channel(parts[2]));
  }

  var body = text.startsWith('#') ? text.substring(1) : text;
  if (body.length == 3) {
    body = body.split('').map((c) => '$c$c').join();
  }
  if (body.length < 6) return (0, 0, 0);
  final packed = int.tryParse(body.substring(0, 6), radix: 16);
  if (packed == null) return (0, 0, 0);
  return ((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF);
}

/// The inverse, always six digits so two colours compare as strings.
String hex(int r, int g, int b) {
  String two(int v) => v.clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(r)}${two(g)}${two(b)}';
}

String _required(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw ArgumentError.value(
    key,
    'chrome.$key',
    'a chrome override must be complete',
  );
}
