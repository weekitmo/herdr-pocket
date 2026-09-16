import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/theme/chrome_tokens.dart';
import 'package:herdr_pocket/domain/theme/terminal_palette.dart';
import 'package:herdr_pocket/domain/theme/theme_definition.dart';

/// The colour arithmetic, and the promise it makes.
///
/// The reason this is worth testing carefully: the whole "support N themes"
/// feature rests on ONE claim — that a scheme nobody has checked against our
/// layout still cannot produce unreadable text. That claim is arithmetic, so it
/// can be checked rather than hoped for. The last group does exactly that, for
/// every theme we ship.
void main() {
  group('hex arithmetic', () {
    test('reads the three shapes the gallery uses', () {
      expect(rgb('#ff8800'), (255, 136, 0));
      expect(rgb('ff8800'), (255, 136, 0));
      expect(rgb('#f80'), (255, 136, 0));
      // The gallery stores selection colours as rgba(...), alpha and all.
      expect(rgb('rgba(0,255,65,0.25)'), (0, 255, 65));
    });

    test('garbage is black rather than a crash', () {
      expect(rgb('not a colour'), (0, 0, 0));
      expect(rgb(''), (0, 0, 0));
    });

    test('hex always pads to six digits', () {
      // Two colours are compared as strings in places; `#0f0` beside `#00ff00`
      // would make that comparison lie.
      expect(hex(0, 15, 0), '#000f00');
    });

    test('mixing is plain sRGB, not linearised', () {
      // Midpoint between black and white is #808080, NOT the #bcbcbc a
      // gamma-correct blend would give. Designers pick colours by eye in sRGB.
      expect(mix('#000000', '#ffffff', 0.5), '#808080');
      expect(mix('#000000', '#ffffff', 0), '#000000');
      expect(mix('#000000', '#ffffff', 1), '#ffffff');
    });

    test('a blend ratio outside 0..1 is clamped rather than extrapolated', () {
      expect(mix('#000000', '#ffffff', 2), '#ffffff');
      expect(mix('#000000', '#ffffff', -1), '#000000');
    });
  });

  group('contrast', () {
    test('the extremes are 21 and 1', () {
      expect(contrastRatio('#000000', '#ffffff'), closeTo(21, 0.01));
      expect(contrastRatio('#808080', '#808080'), closeTo(1, 0.001));
    });

    test('it is symmetric', () {
      expect(
        contrastRatio('#123456', '#fedcba'),
        closeTo(contrastRatio('#fedcba', '#123456'), 0.0001),
      );
    });
  });

  group('enforce', () {
    test('leaves a colour that already clears the ratio alone', () {
      expect(enforce('#000000', '#ffffff', 7), '#000000');
    });

    test('pushes a too-faint colour until it clears the ratio', () {
      final pushed = enforce('#eeeeee', '#ffffff', 4.5);
      expect(contrastRatio(pushed, '#ffffff'), greaterThanOrEqualTo(4.5));
    });

    test('moves toward black on a light surface, and toward white on a dark one', () {
      final onLight = enforce('#dddddd', '#ffffff', 3);
      expect(luminance(onLight), lessThan(luminance('#dddddd')));

      final onDark = enforce('#111111', '#000000', 3);
      expect(luminance(onDark), greaterThan(luminance('#111111')));
    });

    test('an impossible request returns the best available, not a loop', () {
      // 21:1 is the ceiling; asking for more must terminate.
      final result = enforce('#777777', '#ffffff', 25);
      expect(result, '#000000');
    });
  });

  group('deriveChrome', () {
    // Tokyo Night, whose values the published client documents.
    const tokyo = TerminalPalette(
      background: '#1a1b26',
      foreground: '#c0caf5',
      cursor: '#c0caf5',
      ansi: ['#15161e', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#a9b1d6'],
      bright: ['#414868', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#c0caf5'],
    );

    test('bg-card is the background stepped 3% toward white', () {
      // Cross-check against the documented algorithm: 0x1a + 3% of the way to
      // 0xff is 33 (0x21), and so on. If this drifts, every theme drifts.
      expect(
        deriveChrome(palette: tokyo, isDark: true).bgCard,
        '#21222d',
      );
    });

    test('the three surfaces are ordered outermost to innermost', () {
      final chrome = deriveChrome(palette: tokyo, isDark: true);
      expect(
        luminance(chrome.bgDeep),
        lessThan(luminance(chrome.bgTerm)),
        reason: 'the app ground is darker than the terminal it holds',
      );
      expect(
        luminance(chrome.bgTerm),
        lessThan(luminance(chrome.bgCard)),
        reason: 'the terminal is darker than the cards laid over it',
      );
    });

    test('status colours come from different hues', () {
      // "needs you" and "this crashed" must not be the same colour.
      final chrome = deriveChrome(palette: tokyo, isDark: true);
      final distinct = {
        chrome.waiting,
        chrome.died,
        chrome.working,
        chrome.done,
        chrome.accent,
      };
      expect(distinct.length, 5);
    });

    test('working is NOT the accent', () {
      // The accent is what a button is. A busy agent is not a button, and a
      // shared colour between the two makes both mean less.
      final chrome = deriveChrome(palette: tokyo, isDark: true);
      expect(chrome.working, isNot(chrome.accent));
    });

    test('a scheme with no ANSI still yields a usable chrome', () {
      // Legitimate: the palette may define only a background and a foreground.
      // The fallback is the foreground, which keeps the contrast promise and
      // loses only the hue.
      const bare = TerminalPalette(
        background: '#101010',
        foreground: '#dddddd',
        cursor: '#dddddd',
      );
      final chrome = deriveChrome(palette: bare, isDark: true);
      expect(contrastRatio(chrome.ink, chrome.bgCard), greaterThanOrEqualTo(7));
      expect(contrastRatio(chrome.working, chrome.bgCard), greaterThanOrEqualTo(3));
    });

    test('a light scheme steps the other way', () {
      const light = TerminalPalette(
        background: '#fdf6e3',
        foreground: '#657b83',
        cursor: '#657b83',
        ansi: ['#073642', '#dc322f', '#859900', '#b58900', '#268bd2', '#d33682', '#2aa198', '#eee8d5'],
        bright: ['#002b36', '#cb4b16', '#586e75', '#657b83', '#839496', '#6c71c4', '#93a1a1', '#fdf6e3'],
      );
      final chrome = deriveChrome(palette: light, isDark: false);
      // On a light theme the card is LIGHTER than the ground, which is the
      // reverse of the dark case — hence two constants rather than one sign.
      expect(luminance(chrome.bgCard), greaterThan(luminance(chrome.bgDeep)));
      expect(contrastRatio(chrome.ink, chrome.bgCard), greaterThanOrEqualTo(7));
    });
  });

  group('the catalogue we actually ship', () {
    late List<ThemeDefinition> themes;

    setUpAll(() {
      final file = File('assets/themes/builtin.json');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'assets/themes/builtin.json is the feature',
      );
      themes = parseThemeCatalogue(file.readAsStringSync());
    });

    test('parses every theme', () {
      expect(themes.length, 12);
      expect(themes.map((t) => t.id), contains('nord'));
      expect(themes.map((t) => t.id), contains('catppuccin-mocha'));
    });

    test('ids are unique, because the id is what gets persisted', () {
      final ids = themes.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('both modes are represented', () {
      expect(themes.where((t) => t.isDark).length, greaterThan(4));
      expect(themes.where((t) => !t.isDark).length, greaterThan(2));
    });

    test('the two hand-written chrome blocks parse completely', () {
      final withChrome = themes.where((t) => t.chromeOverride != null).toList();
      expect(withChrome.map((t) => t.id), containsAll(['moshi', 'moshi-light']));
    });

    test('EVERY theme clears the contrast floors', () {
      // This is the test the feature rests on. Without it, "12 themes" would
      // mean "12 themes somebody has to eyeball".
      for (final theme in themes) {
        final chrome = theme.chrome;
        final surface = chrome.bgCard;
        expect(
          contrastRatio(chrome.ink, surface),
          greaterThanOrEqualTo(ContrastFloor.body),
          reason: '${theme.id}: body text must clear ${ContrastFloor.body}:1',
        );
        expect(
          contrastRatio(chrome.inkMid, chrome.bgDeep),
          greaterThanOrEqualTo(ContrastFloor.secondary),
          reason: '${theme.id}: secondary text',
        );
        for (final entry in {
          'accent': chrome.accent,
          'waiting': chrome.waiting,
          'died': chrome.died,
          'working': chrome.working,
          'done': chrome.done,
        }.entries) {
          expect(
            contrastRatio(entry.value, surface),
            greaterThanOrEqualTo(ContrastFloor.shape),
            reason: '${theme.id}: ${entry.key} must be a visible shape',
          );
        }
      }
    });

    test('every theme is legible on its OWN terminal background', () {
      // The terminal is the one surface we do NOT re-derive: its colours are
      // the scheme's, verbatim, and the floor here is deliberately lower than
      // the app's. Solarized is famously low-contrast by design — its author
      // chose those ratios — and "fixing" a borrowed palette would mean
      // shipping a different scheme under somebody else's name.
      for (final theme in themes) {
        expect(
          contrastRatio(theme.palette.foreground, theme.palette.background),
          greaterThanOrEqualTo(ContrastFloor.shape),
          reason: '${theme.id}: terminal text on terminal background',
        );
      }
    });

    test('the text hierarchy survives enforcement', () {
      // Enforcing four steps against the same surface could flatten them into
      // one brightness. The steps ARE the hierarchy, so this checks they are
      // still ordered — on both surfaces text actually sits on.
      for (final theme in themes) {
        final chrome = theme.chrome;
        for (final surface in [chrome.bgCard, chrome.bgDeep]) {
          final steps = [chrome.ink, chrome.inkMid, chrome.inkDim, chrome.inkFaint]
              .map((c) => contrastRatio(c, surface))
              .toList();
          expect(
            steps[0],
            greaterThanOrEqualTo(steps[1]),
            reason: '${theme.id}: ink should not be weaker than inkMid',
          );
          expect(
            steps[1],
            greaterThanOrEqualTo(steps[2]),
            reason: '${theme.id}: inkMid should not be weaker than inkDim',
          );
          expect(
            steps[2],
            greaterThanOrEqualTo(steps[3]),
            reason: '${theme.id}: inkDim should not be weaker than inkFaint',
          );
        }
      }
    });
  });

  group('parseThemeCatalogue refuses to guess', () {
    test('a malformed file is an empty catalogue, not a crash', () {
      expect(parseThemeCatalogue('{ not json'), isEmpty);
      expect(parseThemeCatalogue('[]'), isEmpty);
    });

    test('entries without an id are dropped', () {
      // An id is what gets persisted; an unnamed theme could be selected but
      // never restored.
      final themes = parseThemeCatalogue(
        jsonEncode({
          'themes': [
            {'name': 'Nameless', 'palette': {'background': '#000', 'foreground': '#fff'}},
          ],
        }),
      );
      expect(themes, isEmpty);
    });

    test('a missing palette yields black-on-white rather than a null', () {
      final themes = parseThemeCatalogue(
        jsonEncode({
          'themes': [
            {'id': 'x', 'name': 'X'},
          ],
        }),
      );
      expect(themes.single.palette.background, '#000');
      expect(themes.single.palette.foreground, '#fff');
    });

    test('mode is read, never sniffed from the colours', () {
      // A light-looking dark theme is a theme somebody made on purpose.
      final themes = parseThemeCatalogue(
        jsonEncode({
          'themes': [
            {
              'id': 'x',
              'name': 'X',
              'mode': 'dark',
              'palette': {'background': '#ffffff', 'foreground': '#000000'},
            },
          ],
        }),
      );
      expect(themes.single.isDark, isTrue);
    });
  });
}
