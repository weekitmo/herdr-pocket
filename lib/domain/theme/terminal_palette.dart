/// The 20 colours a terminal colour scheme is made of.
///
/// A leaf file: the chrome derivation and the theme definition both need this
/// type, and neither needs the other.
library;

/// The 20 colours a terminal scheme is made of.
class TerminalPalette {
  const TerminalPalette({
    required this.background,
    required this.foreground,
    required this.cursor,
    this.selectionBackground,
    this.ansi = const [],
    this.bright = const [],
  });

  /// Parses one theme's `palette` object.
  ///
  /// Tolerant in the same direction as everything else that reads the wire:
  /// a missing colour is ABSENT, never guessed, and the caller degrades. A
  /// scheme with no ANSI at all is legitimate — the terminal then keeps its own
  /// defaults, which is what the desktop client does too.
  factory TerminalPalette.fromJson(Map<String, Object?> json) {
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return TerminalPalette(
      background: str(json['background']) ?? '#000000',
      foreground: str(json['foreground']) ?? '#ffffff',
      cursor: str(json['cursor']) ?? str(json['foreground']) ?? '#ffffff',
      selectionBackground: str(json['selectionBackground']),
      ansi: [
        for (final key in ansiKeys) str(json[key]) ?? '',
      ],
      bright: [
        for (final key in brightKeys) str(json[key]) ?? '',
      ],
    );
  }

  final String background;
  final String foreground;
  final String cursor;

  /// May be `rgba(...)` rather than hex — the gallery uses both.
  final String? selectionBackground;

  /// ANSI 0–7, in order. An empty string means "not specified".
  final List<String> ansi;

  /// ANSI 8–15, in order.
  final List<String> bright;

  bool get hasAnsi => ansi.length == 8 && ansi.every((c) => c.isNotEmpty);
  bool get hasBright => bright.length == 8 && bright.every((c) => c.isNotEmpty);

  /// One of the eight base hues, by name.
  ///
  /// A scheme with no ANSI at all still has to yield a usable chrome, and the
  /// honest fallback is the foreground: the promise (readable) is kept, only
  /// the hue is lost. Guessing a hue would be inventing a colour the scheme
  /// never chose.
  String hue(String name) {
    final index = ansiKeys.indexOf(name);
    final value = index >= 0 && index < ansi.length ? ansi[index] : '';
    return value.isNotEmpty ? value : foreground;
  }

  static const ansiKeys = [
    'black',
    'red',
    'green',
    'yellow',
    'blue',
    'magenta',
    'cyan',
    'white',
  ];

  static const brightKeys = [
    'brightBlack',
    'brightRed',
    'brightGreen',
    'brightYellow',
    'brightBlue',
    'brightMagenta',
    'brightCyan',
    'brightWhite',
  ];
}
