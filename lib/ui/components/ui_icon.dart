import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:herdr_pocket/ui/components/ui_icons.g.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The app's own chrome icons, drawn from a themed set.
///
/// WHY NOT `CupertinoIcons`, WHICH IS ALREADY HERE. Cupertino's set is
/// monochrome by design and that is mostly right for this app — colour is
/// meaning here, and exactly four hues carry it. What it cannot do is carry any
/// colour at all, on the surfaces where a little of it would help: the dock's
/// three destinations, the terminal's toolbar, and the way back to the machine.
///
/// So this is an OPT-IN set, not a replacement. [UiIconVariant] decides how much
/// colour an icon is allowed, and it is a parameter rather than a build-time
/// choice so the same screen can be looked at three ways before anybody commits.
///
/// HOW IT WORKS. The vendored files contain no colour — `__C0__`..`__C3__` stand
/// where IconPark's own fills were (see `assets/ui_icons/README.md`). Painting
/// is a string substitution, cached per (icon, palette), and the result goes to
/// `SvgPicture.string`. The alternative, `ColorFilter`, cannot work here: it
/// collapses a picture to one colour, which is the whole point of it and the
/// exact opposite of what a multi-colour icon needs.
enum UiIconName {
  board('Workbench'),
  workspaces('AllApplication'),
  settings('SettingTwo'),
  attach('Paperclip'),
  panes('BlocksAndArrows'),
  split('LayoutFour'),
  more('MoreTwo'),
  machine('Server'),
  folder('Folder'),
  branch('Branch'),
  aim('Aiming');

  UiIconName(this.asset);

  /// The base name in `assets/ui_icons/`, where the audit copy lives. The
  /// template the app actually draws is compiled in — see [uiIconTemplates].
  final String asset;
}

/// How much colour an icon is allowed to carry.
enum UiIconVariant {
  /// Today's behaviour: one flat tint, like every other icon in the app.
  mono,

  /// The set's own idea of multi-colour, but every value taken from the theme.
  ///
  /// Chosen so that the icon cannot disagree with the twelve colour schemes:
  /// change the scheme and the icons change with it, which is what the rest of
  /// the app already does.
  themed,

  /// A fixed, vivid palette — what these icons look like as published.
  ///
  /// Deliberately NOT theme-derived, and that is the thing being compared: a
  /// fixed palette is brighter and more immediately legible as "colourful", and
  /// it is also four hues that no colour scheme asked for.
  showcase,
}

/// One chrome icon.
class UiIcon extends StatelessWidget {
  const UiIcon(
    this.name, {
    this.size = 20,
    this.variant = UiIconVariant.mono,
    this.color,
    this.background,
    this.filled = true,
    super.key,
  });

  final UiIconName name;
  final double size;
  final UiIconVariant variant;

  /// Used by [UiIconVariant.mono] only. Defaults to the app's dim text.
  final Color? color;

  /// What the icon is sitting on.
  ///
  /// Needed even in mono, because the second and third colour slots in this set
  /// are details drawn ON TOP of the first fill — a dot inside a circle, the
  /// dividers inside a box. Painting them in the same ink as the fill makes
  /// them vanish and the icon collapses into a blob. See [iconStops].
  final Color? background;

  /// Whether the shape's body is filled or only outlined.
  ///
  /// ONE ASSET, TWO STATES. The dock marks its selected tab with a FILLED glyph
  /// rather than with a pill, and that decision survives here without a second
  /// file: slot 1 is the body, so painting it the ground colour turns the same
  /// drawing into its own outline version. Fetching a separate outline set would
  /// mean two geometries that can drift apart.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final mono = color ?? colors.textDim;
    final stops = iconStops(
      variant: variant,
      colors: colors,
      mono: mono,
      background: background ?? colors.surface,
      filled: filled,
    );
    return SvgPicture.string(
      themedIcon(name, stops),
      width: size,
      height: size,
      excludeFromSemantics: true,
    );
  }
}

/// The four colours an icon is drawn with, in slot order.
List<Color> iconStops({
  required UiIconVariant variant,
  required HerdrColors colors,
  required Color mono,
  required Color background,
  bool filled = true,
}) {
  switch (variant) {
    case UiIconVariant.mono:
      // NOT all four the same. Slot 0 is the outline and slot 1 the large fill;
      // slots 2 and 3 are details drawn ON that fill, so in mono they have to
      // be the GROUND colour or the detail disappears into the shape it sits
      // on. Painting all four one ink turned the overflow icon into a plain
      // circle and the split icon into a plain square — present, invisible, and
      // only visible on a rendered screen.
      return [mono, mono, background, background];
    case UiIconVariant.themed:
      // Slot 0 is the outline in every icon in the set and slot 1 the large
      // fill; 2 and 3 are small details drawn ON TOP of that fill. So the
      // mapping is structural rather than per-icon, and it has to know which
      // side of the fill the details sit on:
      //
      //   filled  outline in ink, body in accent, details punched out in the
      //           ground colour, because ink-on-accent is mud.
      //   outline body left as ground so only the outline reads, and the
      //           details in ink, because they are now on the ground too.
      return filled
          ? [colors.text, colors.accent, colors.surface, colors.surface]
          : [colors.text, background, colors.text, colors.text];
    case UiIconVariant.showcase:
      return const [
        Color(0xFF1B1B1F),
        Color(0xFF2F88FF),
        Color(0xFFFFFFFF),
        Color(0xFF43CCF8),
      ];
  }
}

/// The resolved SVG for [name], with the colour slots filled in.
///
/// Cached because the substitution is a string operation and a dock rebuilds on
/// every event burst: parsing four hundred bytes of SVG per frame per icon is
/// work nobody asked for on a 2018 device.
String themedIcon(UiIconName name, List<Color> stops) {
  final key = '${name.name}|${stops.map(_hex).join()}';
  return _cache.putIfAbsent(key, () => _resolve(_template(name), stops));
}

/// The vendored template, which is a `const` string in `ui_icons.g.dart`.
///
/// Compiled in rather than read from the bundle, so there is no `await` before
/// an icon can be drawn and no bootstrap step that can be forgotten. The audit
/// copies under `assets/ui_icons/` are deliberately NOT declared in
/// `pubspec.yaml`: they exist to be read by a person and to be hashed by
/// `tool/fetch_ui_icons.py --check`, not to ship.
String _template(UiIconName name) {
  final template = uiIconTemplates[name.asset];
  if (template == null) {
    throw StateError(
      'No template for ${name.name} (${name.asset}). '
      'Re-run tool/fetch_ui_icons.py.',
    );
  }
  return template;
}

String _resolve(String svg, List<Color> stops) {
  var out = svg;
  for (var i = 0; i < stops.length; i++) {
    out = out.replaceAll('__C${i}__', _hex(stops[i]));
  }
  return out;
}

/// Six digits, because that is what the SVGs expect and what compares cleanly.
String _hex(Color color) {
  final value = color.toARGB32() & 0xFFFFFF;
  return '#${value.toRadixString(16).padLeft(6, '0')}';
}

final Map<String, String> _cache = {};

/// Test seam: drop the resolved cache so one test cannot leak into the next.
@visibleForTesting
void resetUiIconCache() => _cache.clear();
