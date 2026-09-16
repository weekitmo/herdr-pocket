/// Terminal colour schemes, and the app chrome derived from them.
///
/// ONE PALETTE DRIVES EVERYTHING. That is the idea worth taking from the
/// product this was studied from: a terminal scheme is 20 colours somebody has
/// already tuned to be legible together, and deriving the app's surfaces and
/// text from those 20 is what stops the chrome and the terminal from being two
/// unrelated designs stapled together.
///
/// The derivation is WCAG-based rather than eyeballed — see [deriveChrome] — so
/// a scheme nobody has ever tested against our layout still cannot produce
/// unreadable text. That property is the reason this is worth doing at all:
/// without it, "support 12 themes" means "hand-check 12 themes".
///
/// Everything here works on hex STRINGS. `dart:ui` is Flutter and the domain
/// layer is not allowed to import it (see `test/architecture/domain_purity_test.dart`),
/// so the UI layer converts to `Color` at the edge.
library;

import 'dart:convert';

import 'package:herdr_pocket/domain/theme/chrome_tokens.dart';
import 'package:herdr_pocket/domain/theme/terminal_palette.dart';

/// A scheme, plus an optional hand-written chrome.
///
/// The override exists because not every theme derives its chrome: the source
/// gallery ships a couple whose app colours were chosen by hand, and running
/// them through the derivation would produce a *different* look from the one
/// those themes are known for. When the chrome is given, it is used verbatim.
class ThemeDefinition {
  ThemeDefinition({
    required this.id,
    required this.name,
    required this.palette,
    this.isDark = true,
    this.chromeOverride,
  });

  factory ThemeDefinition.fromJson(Map<String, Object?> json) {
    final palette = json['palette'];
    final chrome = json['chrome'];
    return ThemeDefinition(
      id: _str(json['id']) ?? '',
      name: _str(json['name']) ?? '',
      isDark: (_str(json['mode']) ?? 'dark') != 'light',
      palette: palette is Map
          ? TerminalPalette.fromJson(palette.cast<String, Object?>())
          : const TerminalPalette(background: '#000', foreground: '#fff', cursor: '#fff'),
      chromeOverride: chrome is Map
          ? ChromeTokens.fromJson(chrome.cast<String, Object?>())
          : null,
    );
  }

  final String id;
  final String name;

  /// Which way round the scheme is. EXPLICIT, never sniffed from the colours:
  /// a light-looking dark theme is a theme somebody made on purpose, and
  /// guessing it away would be us overriding a decision that is not ours.
  final bool isDark;

  final TerminalPalette palette;
  final ChromeTokens? chromeOverride;

  /// The chrome this theme should be drawn with.
  ///
  /// Derived for most themes; used verbatim for the few whose colours were
  /// chosen by hand upstream — except that the text floors still apply, so
  /// "every theme we ship is readable" has no exceptions.
  ChromeTokens get chrome {
    final override = chromeOverride;
    if (override == null) {
      return deriveChrome(palette: palette, isDark: isDark);
    }
    return enforceTextFloors(override);
  }

  @override
  String toString() => 'ThemeDefinition($id, ${isDark ? 'dark' : 'light'})';
}

/// Every theme in a bundled catalogue file.
List<ThemeDefinition> parseThemeCatalogue(String json) {
  final decoded = _decode(json);
  final themes = decoded?['themes'];
  if (themes is! List) return const [];
  return [
    for (final entry in themes)
      if (entry is Map) ThemeDefinition.fromJson(entry.cast<String, Object?>()),
  ].where((t) => t.id.isNotEmpty).toList(growable: false);
}

Map<String, Object?>? _decode(String json) {
  try {
    final decoded = jsonDecode(json);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on Object {
    // A malformed catalogue is an empty catalogue, not a crash: the app still
    // has its built-in default to fall back on.
    return null;
  }
}

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
