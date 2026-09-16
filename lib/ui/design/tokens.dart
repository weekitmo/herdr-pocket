import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/domain/theme/chrome_tokens.dart';

/// Design tokens for herdr-pocket.
///
/// Ported from `herdrup/App/DesignSystem.swift` (Apache-2.0) for the dark
/// palette, and solved numerically for light (herdrup has none — it hard-pins
/// `.preferredColorScheme(.dark)`). Contrast figures are recorded so the next
/// person does not have to re-derive them.
///
/// The three load-bearing rules from the Claude Design kit:
///
///   1. A deep desaturated indigo ground, NEVER black.
///   2. Colour is MEANING, not decoration — the four status hues are the only
///      colour in the product. Even the primary button is filled with ink, not
///      a brand colour. There is deliberately no accent for decoration.
///   3. Monospace is the MACHINE voice, a proportional face is the APP voice.
@immutable
class HerdrColors {
  const HerdrColors({
    required this.ground,
    required this.groundMachine,
    required this.groundDeep,
    required this.surface,
    required this.surfaceRaised,
    required this.hairline,
    required this.hairlineQuiet,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.waiting,
    required this.died,
    required this.working,
    required this.done,
    required this.statusTextWaiting,
    required this.statusTextDied,
    required this.statusTextWorking,
    required this.statusTextDone,
    required this.brightness,
  });

  /// Builds the app's colours from a theme's chrome.
  ///
  /// The mapping is not one-to-one, because the two token sets answer different
  /// questions. Ours has names for things this app actually draws (a terminal
  /// strip, a raised card, four status meanings); a scheme's chrome has names
  /// for surfaces and text. Where they overlap the theme wins outright; where
  /// ours is more specific, the value is derived from the theme's own scale
  /// rather than reusing one of its colours twice.
  ///
  /// THE STATUS COLOURS COME FROM THE THEME'S STATUS TOKENS, never from its
  /// accent. That rule survives the theme system unchanged: whatever a user
  /// picks, "this needs you" is not "this is a button".
  factory HerdrColors.fromChrome(
    ChromeTokens chrome, {
    required Brightness brightness,
  }) {
    final isDark = brightness == Brightness.dark;
    Color c(String hex) => colorFromHex(hex);

    return HerdrColors(
      brightness: brightness,
      ground: c(chrome.bgDeep),
      // The terminal strip and the deepest shelf are steps in the theme's own
      // scale, not new colours: a machine surface is "further back", and the
      // theme already says what further back looks like.
      groundMachine: c(chrome.bgTerm),
      groundDeep: c(mix(chrome.bgDeep, '#000000', isDark ? 0.4 : 0.0)),
      surface: c(chrome.bgCard),
      surfaceRaised: c(
        mix(chrome.bgCard, isDark ? '#ffffff' : '#000000', 0.06),
      ),
      hairline: c(chrome.line),
      hairlineQuiet: c(chrome.lineSoft),
      text: c(chrome.ink),
      textDim: c(chrome.inkMid),
      textFaint: c(chrome.inkFaint),
      accent: c(chrome.accent),
      waiting: c(chrome.waiting),
      died: c(chrome.died),
      working: c(chrome.working),
      done: c(chrome.done),
      // Status text is the same hue pushed until it is readable AS TEXT, which
      // is a higher bar than the shape it sits beside.
      statusTextWaiting: c(
        enforce(chrome.waiting, chrome.bgCard, ContrastFloor.secondary),
      ),
      statusTextDied: c(
        enforce(chrome.died, chrome.bgCard, ContrastFloor.secondary),
      ),
      statusTextWorking: c(
        enforce(chrome.working, chrome.bgCard, ContrastFloor.secondary),
      ),
      statusTextDone: c(
        enforce(chrome.done, chrome.bgCard, ContrastFloor.secondary),
      ),
    );
  }

  /// App ground — the surface everything floats on.
  final Color ground;

  /// Terminal ONLY — its own ground, one shade under [ground].
  final Color groundMachine;

  /// Behind everything (device edges / safe-area fill).
  final Color groundDeep;

  /// Cards, fields, rows.
  final Color surface;

  /// Active tab, pressed state, key panel.
  final Color surfaceRaised;

  /// Rule — hairline around a surface.
  final Color hairline;

  /// Rule-quiet — section rules and dividers.
  final Color hairlineQuiet;

  /// What matters. ALSO the only fill on acting controls.
  final Color text;

  /// Supporting text, terminal body.
  final Color textDim;

  /// Machine metadata, ages, folder names.
  final Color textFaint;

  /// Interactive text (links). herdrup calls its brand violet "retired" while
  /// still using it as the link tint, so it is promoted to a real token here
  /// rather than left as a comment that contradicts the code.
  final Color accent;

  // --- Status = meaning. The ONLY palette that carries colour. -------------
  /// Amber — an agent is asking you.
  final Color waiting;

  /// Red — exited / crashed.
  final Color died;

  /// Blue — running.
  final Color working;

  /// Green — finished.
  final Color done;

  // --- Status hues adjusted for use AS TEXT ---------------------------------
  // The four above clear 3:1 against their ground, which is the bar for
  // non-text UI (WCAG 1.4.11). Body text needs 4.5:1, so anything that renders
  // a status as a *word* uses these instead. Using the plain hue for text is
  // the single easiest accessibility regression to ship by accident.
  final Color statusTextWaiting;
  final Color statusTextDied;
  final Color statusTextWorking;
  final Color statusTextDone;

  final Brightness brightness;

  bool get isDark => brightness == Brightness.dark;

  /// The edge of a card that is DOING something — working, or asking for you.
  ///
  /// A quiet card has no edge at all — it is separated from the ground by a
  /// colour step and a shadow, and an outline on top of that is a third way of
  /// saying the same thing. This is the opposite: the card is live, and it says
  /// so the way a control does, with a full ring rather than the status spine
  /// the cards used to carry.
  ///
  /// A LIGHT TINT of the working blue rather than the status hue at strength.
  /// The ring is one pixel, so it cannot be read as a status fill, and a
  /// full-strength `working` would force a "needs you" card to choose between
  /// losing its amber or wearing a colour that means something else. The dot
  /// inside the card keeps carrying the status; the edge carries "live".
  Color get cardEdgeActive => isDark
      // Lit rather than outlined: on a near-black ground a pale ring glows,
      // which is louder than "this one is running".
      ? const Color(0xFF3D5F8F)
      : const Color(0xFFACCEF4);


  /// `#rrggbb` to an opaque [Color].
  static Color colorFromHex(String hex) {
    final (r, g, b) = rgb(hex);
    return Color.fromARGB(0xFF, r, g, b);
  }

  /// Deep desaturated indigo. Never black.
  static const dark = HerdrColors(
    brightness: Brightness.dark,
    ground: Color(0xFF13162A),
    groundMachine: Color(0xFF0B0D1C),
    groundDeep: Color(0xFF0A0C18),
    surface: Color(0xFF1D2038),
    surfaceRaised: Color(0xFF262A45),
    hairline: Color(0xFF2E3358),
    hairlineQuiet: Color(0xFF232742),
    text: Color(0xFFEEF0F7),
    textDim: Color(0xFF99A0BC),
    // herdrup ships #666D91 here, which measures 3.16:1 on `surface` — that
    // FAILS AA for body text. Lightened to clear it.
    textFaint: Color(0xFF8A92B2),
    accent: Color(0xFF7A6FF0),
    waiting: Color(0xFFE9A63C),
    died: Color(0xFFE2584E),
    working: Color(0xFF5B9BE8),
    done: Color(0xFF5FB37F),
    statusTextWaiting: Color(0xFFE9A63C),
    // herdrup ships #E2584E, which measures 4.36:1 — a hair under AA.
    statusTextDied: Color(0xFFF0705F),
    statusTextWorking: Color(0xFF7FB4F0),
    statusTextDone: Color(0xFF7FC99B),
  );

  /// Light mode is derived, not ported: herdrup has no light mode at all.
  /// Every text token was solved to clear 4.5:1 on [surface]; every status
  /// token clears 3:1 for non-text use.
  static const light = HerdrColors(
    brightness: Brightness.light,
    ground: Color(0xFFF2F3F9),
    groundMachine: Color(0xFF0B0D1C),
    groundDeep: Color(0xFFE8EAF4),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFE8EAF4),
    hairline: Color(0xFFD4D8E8),
    hairlineQuiet: Color(0xFFE4E7F2),
    text: Color(0xFF171A2E),
    textDim: Color(0xFF5A6079),
    textFaint: Color(0xFF6B7291),
    accent: Color(0xFF3B4BC8),
    waiting: Color(0xFFC4830F),
    died: Color(0xFFD9453A),
    working: Color(0xFF3C86D8),
    done: Color(0xFF3D9E68),
    statusTextWaiting: Color(0xFF7E5209),
    statusTextDied: Color(0xFFB02B23),
    statusTextWorking: Color(0xFF2568AE),
    statusTextDone: Color(0xFF23754A),
  );
}

/// Font families.
///
/// The app voice is the platform's own proportional face — Flutter resolves it
/// per platform and the system CJK fallback is good enough for prose, which is
/// not grid-aligned.
///
/// The machine voice is BUNDLED. A terminal is a fixed grid, and a full-width
/// Han glyph has to be exactly two cells; whether that holds is a property of
/// the font's advances, not of the platform. Android's monospace family has no
/// CJK glyphs at all, so the system would fall back to a proportional face and
/// every mixed line would drift. One font, verified 2:1 — see
/// test/ui/terminal_font_metrics_test.dart.
abstract final class HerdrFonts {
  /// Latin, and the Nerd Font icon range.
  ///
  /// Iosevka, not Maple: Iosevka is the face the user reads every day in their
  /// own terminal, and matching it is what makes this app feel like the tool it
  /// talks to rather than a lookalike.
  ///
  /// It has NO Han coverage at all — 18239 glyphs and not one Chinese
  /// character — so Chinese comes from [hanFallback] and the two are only
  /// allowed to be paired because their advances agree exactly.
  static const String mono = 'IosevkaNerdFontMono';

  /// Han, from Noto Sans Mono CJK.
  ///
  /// Ordered BEFORE the platform fallback, and that ordering is the whole
  /// trick: a Han glyph missing from Iosevka is served by Noto at 1.0000 em,
  /// which is exactly twice Iosevka's 0.5000 em — so Chinese lands on the grid
  /// instead of drifting through it. Any family listed ahead of this one would
  /// break that, because the platform's CJK faces are proportional.
  ///
  /// Verified from the font files (cmap + hmtx) AND through Flutter's own text
  /// layout in test/ui/terminal_font_metrics_test.dart.
  static const String han = 'NotoSansMonoCJKsc';

  /// The app's voice IS the machine's voice — same family, same stack.
  static const String app = mono;

  /// Only for whatever neither carries — emoji, chiefly.
  static const monoFallback = <String>[han, 'monospace'];
}

/// The type scale.
///
/// A LADDER, not a per-widget decision. Before this there were 119 hard-coded
/// font sizes across the app — fourteen distinct values between 10 and 34 — and
/// the result read as "everything is slightly too big" because every screen had
/// made its own call. Naming seven rungs is what makes the app feel set rather
/// than assembled, and it is what makes a global change like this one possible
/// at all.
///
/// The sizes are deliberately smaller than the proportional face they replaced.
/// A monospace glyph is WIDER at the same point size, so keeping 16 would have
/// made every label bigger than it already was — the exact complaint.
abstract final class TextSize {
  /// A page's large title.
  static const double largeTitle = 26;

  /// An inline navigation title, an empty-state headline, an avatar glyph.
  static const double title = 16;

  /// A card's or row's own name — the thing you are reading for.
  static const double strong = 14;

  /// Prose the user actually reads, and form values.
  static const double body = 13;

  /// The sentence under a row, and group footnotes.
  static const double note = 12;

  /// Machine metadata: paths, model names, versions, counts.
  static const double meta = 11;

  /// Badges, pane ids, the smallest labels that still have to be read.
  static const double micro = 10;

  /// Labels drawn ON something — dock captions, split-view pane names — where
  /// the text competes with the content behind it.
  static const double tiny = 9;
}

/// Spacing scale. 4-based, matching iOS rhythm rather than Material's 8-grid.
abstract final class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double xxxl = 40;
}

/// Corner radius.
///
/// ONE value, used by every rounded rectangle in the app — cards, fields,
/// sheets, chips and buttons alike. A scale (chips tighter than cards, sheets
/// rounder than both) reads as a system assembled from unrelated parts; a
/// single radius is what makes an interface look deliberate.
///
/// This replaced a five-step scale at the user's request after the first
/// on-device review.
abstract final class Radii {
  /// The only corner radius.
  static const double uniform = 14;
}

/// Elevation recipes.
///
/// Light mode cannot lean on a colour step: `ground` and `surface` differ by
/// about 1.11:1, which is deliberate — a stark white card floating on grey
/// reads as Material, not as iOS — but a 1.11:1 step is not enough on its own
/// to separate a card from its ground. So light mode carries a shadow instead.
/// Dark mode carries none: the surface step is already legible and a shadow on
/// a dark ground just muddies it.
abstract final class Elevation {
  static const List<BoxShadow> none = [];

  /// Tight and faint rather than wide and grey.
  ///
  /// The previous recipe (14px blur, -2 spread, 7.8% ink) put a visible grey
  /// band under every card, which on a screenful of cards reads as dirt rather
  /// than as depth. A shorter blur keeps the shadow inside the card's own
  /// footprint, where it lifts the edge instead of smudging the ground — and
  /// since a quiet card no longer has a border, a *crisp* edge is now the only
  /// thing telling it apart from the ground.
  static List<BoxShadow> card(HerdrColors c) => c.isDark
      ? none
      : const [
          BoxShadow(
            color: Color(0x0F171A2E),
            blurRadius: 8,
            offset: Offset(0, 2),
            spreadRadius: -1,
          ),
        ];
}

/// Motion. Apple-style: short, spring-ish, never showy.
abstract final class Motion {
  /// Press feedback.
  static const Duration press = Duration(milliseconds: 120);

  /// Default UI transition.
  static const Duration standard = Duration(milliseconds: 250);

  /// Sheet presentation.
  static const Duration sheet = Duration(milliseconds: 400);

  /// The live-turn indicator. Linear and repeatForever — it says "alive"
  /// without claiming a duration.
  static const Duration spinner = Duration(milliseconds: 900);

  /// Pulse for the working status dot.
  static const Duration pulse = Duration(milliseconds: 800);
}

/// Provides [HerdrColors] down the tree without Material's ThemeData.
///
/// An InheritedWidget rather than a Riverpod provider for one reason: a
/// `BuildContext`-scoped lookup works inside `build` without a binding, so a
/// widget test can pump a subtree with explicit colours and nothing else.
class HerdrTheme extends InheritedWidget {
  const HerdrTheme({
    required this.colors,
    required super.child,
    super.key,
  });

  final HerdrColors colors;

  static HerdrColors of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<HerdrTheme>();
    assert(theme != null, 'No HerdrTheme above this widget.');
    return theme!.colors;
  }

  @override
  bool updateShouldNotify(HerdrTheme oldWidget) => oldWidget.colors != colors;
}
