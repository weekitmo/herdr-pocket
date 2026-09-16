import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_identity.dart';
import 'package:herdr_pocket/ui/components/agent_icon.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Tests for the per-agent brand marks.
///
/// Three things are worth protecting here, and only the first is about drawing:
///
///   1. **An unknown agent still draws something.** herdr's id list has grown
///      with every release and nothing announces it, so "no brand mark" must
///      never become an empty square — the failure mode is that a bug and a new
///      agent look identical.
///   2. **The assets are real.** Every path in the map exists, is an SVG, and
///      actually compiles. A renamed file that ships as a missing asset is not
///      something a reviewer can see.
///   3. **The treatment is uniform.** Every icon — mark or letter — is a black
///      element on a white plate. The first version let each vendor's artwork
///      keep its own colours, which produced seventeen icons that did not look
///      like a set: invisible marks on one ground, brand gradients the app's
///      design rules forbid, and one mark with two halves needing opposite
///      grounds. This test is what stops that creeping back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps [agent] inside the app's real theme. The plate and the ink are
  /// fixed colours, but the plate's BORDER is themed, so the theme is still
  /// needed to cover both modes.
  Future<void> pumpIcon(
    WidgetTester tester,
    String agent, {
    double size = 18,
    HerdrColors colors = HerdrColors.dark,
  }) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HerdrTheme(
          colors: colors,
          child: Center(child: AgentIcon(agent: agent, size: size)),
        ),
      ),
    );
  }

  /// The one rounded-square fill in the tree: the plate. The mark or the
  /// monogram sits inside it, so this finds either.
  Container chipBox(WidgetTester tester) {
    return tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere((c) => c.decoration is BoxDecoration);
  }

  /// The two hex stops of the chip's identity gradient, in order.
  ///
  /// Asserted through the stops rather than through a painted pixel because the
  /// gradient IS the token: `identityFor` already guarantees white ink clears
  /// the floor on both ends (see `test/domain/agent_identity_test.dart`), so
  /// what is left for a widget test to check is that the right pair reached the
  /// right chip.
  List<String> chipStops(Container box) {
    final gradient = (box.decoration! as BoxDecoration).gradient!;
    return [
      for (final color in gradient.colors)
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    ];
  }

  /// Every distinct asset path the map can hand back.
  ///
  /// Derived from [herdrAgentIds], so this never drifts from the map, and the
  /// `withMark` assertion below pins that the two agree on all 17.
  Set<String> assetPaths() => {
        for (final id in herdrAgentIds)
          if (agentIconAsset(id) != null) agentIconAsset(id)!,
      };

  group('coverage', () {    test('every id herdr can report resolves to a mark or to the monogram', () {
      // Iterating the shared list rather than a literal here is the point: an
      // id added to `herdrAgentIds` cannot be forgotten by this test.
      for (final id in herdrAgentIds) {
        final asset = agentIconAsset(id);
        if (asset == null) {
          // The monogram path. agentGlyph has a final `?` branch, so this can
          // never be empty — which is what makes "no mark" safe.
          expect(agentGlyph(id), isNotEmpty, reason: '$id has no glyph');
          continue;
        }
        expect(
          File(asset).existsSync(),
          isTrue,
          reason: '$id maps to $asset, which is not on disk',
        );
      }
      expect(herdrAgentIds, isNotEmpty);
    });

    test('the set of ids with a brand mark is exactly this', () {
      // Deliberately explicit. If a download silently switches an agent from
      // "has a mark" to "monogram", that is a visible product change and it
      // should have to be written down here.
      final withMark = {
        for (final id in herdrAgentIds)
          if (agentIconId(id) != null) agentIconId(id),
      };
      expect(withMark, {
        'amp',
        'antigravity',
        'claude',
        'cline',
        'codex',
        'copilot',
        'cursor',
        'deepseek',
        'devin',
        'gemini',
        'grok',
        'kimi',
        'kiro',
        'mastracode',
        'opencode',
        'pi',
        'qodercli',
        'qwen',
      });
    });

    test('the agents with no public mark fall back rather than guess', () {
      // `hermes` is the interesting one: simple-icons DOES serve a `hermes`
      // slug, but its own `source` field points at myhermes.de — the German
      // parcel company. A wrong brand on a pane is worse than a letter.
      for (final id in ['omp', 'droid', 'kilo', 'hermes', 'maki', 'muse']) {
        expect(herdrAgentIds, contains(id), reason: '$id should be listed');
        expect(
          agentIconAsset(id),
          isNull,
          reason: '$id has no brand mark and must use the monogram',
        );
      }
    });
  });

  group('assets on disk', () {
    test('every asset path in the map exists, is an SVG, and is not empty', () {
      final paths = assetPaths();
      expect(paths, isNotEmpty);

      for (final path in paths) {
        final file = File(path);
        // dart:io, not the asset bundle: a test that resolves assets through
        // the bundle would pass on the machine that built it and prove nothing
        // about the file that actually ships.
        expect(file.existsSync(), isTrue, reason: '$path does not exist');
        final source = file.readAsStringSync();
        expect(source, isNotEmpty, reason: '$path is empty');
        expect(
          source.trimLeft(),
          startsWith('<svg'),
          reason: '$path is not an SVG (an error page saved as .svg?)',
        );
        expect(source, contains('</svg>'), reason: '$path is truncated');
      }
    });

    test('every asset compiles to a non-empty picture', () async {
      for (final path in assetPaths()) {
        final bytes = Uint8List.fromList(File(path).readAsBytesSync());
        // This is the real renderability check: it runs the same
        // vector_graphics compiler the widget does, so an unparseable SVG
        // fails here instead of rendering as an empty box on a phone.
        final info = await vg.loadPicture(SvgBytesLoader(bytes), null);
        addTearDown(info.picture.dispose);
        expect(
          info.size.width,
          greaterThan(0),
          reason: '$path compiles to a zero-width picture',
        );
        expect(info.size.height, greaterThan(0), reason: '$path has no height');
      }
    });

    testWidgets('every asset is registered in the bundle, not just on disk',
        (tester) async {
      // A different failure from "the file is missing": a file that exists but
      // is not listed under `assets:` in pubspec.yaml loads fine in this
      // repository and throws "Unable to load asset" on a phone. Only the
      // bundle can tell us which one we have.
      final paths = assetPaths();
      await tester.runAsync(() async {
        for (final path in paths) {
          final data = await rootBundle.load(path);
          expect(
            data.lengthInBytes,
            greaterThan(0),
            reason: '$path is registered but empty',
          );
        }
      });
    });
  });

  group('aliases', () {
    test('claude-code, agy and antigravity-cli are not new icons', () {
      expect(agentIconAsset('claude-code'), agentIconAsset('claude'));
      expect(agentIconAsset('agy'), agentIconAsset('antigravity-cli'));
      expect(agentIconAsset('agy'), agentIconAsset('antigravity'));
      expect(agentIconAsset('agy'), isNotNull);
      // All three spellings land on ONE canonical id, so one product cannot
      // grow a second icon later.
      expect(agentIconId('agy'), 'antigravity');
      expect(agentIconId('antigravity-cli'), 'antigravity');
      expect(agentIconId('claude-code'), 'claude');
      // Aliasing is not a side effect of whitespace folding: `agy` normalises
      // to itself and only the alias table turns it into `antigravity`.
      expect(normalizeAgentId('agy'), 'agy');
    });

    test("every alias herdr's own manifests declare resolves like its id", () {
      // Straight out of the AgentManifest aliases in the herdr 0.9.0 binary, so
      // these are the spellings the daemon will actually hand us.
      const aliasToId = {
        'antigravity': 'agy',
        'antigravity-cli': 'agy',
        'claude-code': 'claude',
        'cursor-agent': 'cursor',
        'devin-cli': 'devin',
        'grok-build': 'grok',
        'kimi-code': 'kimi',
        'kiro-cli': 'kiro',
        'open-code': 'opencode',
        'qoder': 'qodercli',
        'qodercn': 'qodercli',
        'qwen-code': 'qwen',
        'github-copilot': 'copilot',
        'amp-local': 'amp',
      };
      for (final entry in aliasToId.entries) {
        expect(
          agentIconAsset(entry.key),
          agentIconAsset(entry.value),
          reason: '${entry.key} should resolve like ${entry.value}',
        );
      }
    });

    test('the DeepSeek harness is one mark under every name it ships', () {
      // None of these ids is declared by herdr: they come from a manifest whose
      // author typed them, which is the only way a TUI with no published
      // integration gets detected at all. One product still gets one mark.
      expect(agentIconId('dsh'), 'deepseek');
      expect(agentIconId('deepseek'), 'deepseek');
      expect(agentIconId('deepseek-tui'), 'deepseek');
      expect(agentIconAsset('dsh'), 'assets/agent_icons/deepseek.svg');
      expect(agentIconAsset('deepseek-tui'), agentIconAsset('deepseek'));
      expect(agentIconAsset('deepseek-cli'), agentIconAsset('deepseek'));
      // Folded like every other id: case, padding, `_`, and the `herdr:` prefix
      // a synthetic id carries.
      expect(agentIconAsset('DeepSeek TUI'), agentIconAsset('deepseek'));
      expect(agentIconAsset('deepseek_tui'), agentIconAsset('deepseek'));
      expect(agentIconAsset('herdr:dsh'), agentIconAsset('deepseek'));
    });

    test('`dsh` is an exact alias, the vendor name is a prefix', () {
      // `dsh` is three letters that also name a Unix tool, so an unrelated id
      // beginning with it must fall back to the monogram rather than borrow the
      // whale — the same judgement that rejected `hermes` (see the directory's
      // README). `deepseek` is unambiguous enough to fold by prefix, which is
      // how `deepseek-tui` and the next CLI name are covered without a list
      // that goes stale.
      for (final unrelated in ['dsh-ssh', 'dsh-cli', 'dshtool']) {
        expect(agentIconAsset(unrelated), isNull, reason: unrelated);
      }
      expect(agentIconId('deepseek-anything'), 'deepseek');
    });

    test('case, padding and separators do not produce a second icon', () {
      expect(agentIconAsset('  CLAUDE  '), agentIconAsset('claude'));
      expect(agentIconAsset('Claude-Code'), agentIconAsset('claude'));
      // herdr spells the same product `open-code`, `open_code` and `opencode`
      // depending on whether you are reading a manifest, a field or a pane.
      expect(agentIconAsset('open_code'), agentIconAsset('opencode'));
      expect(agentIconAsset('Open Code'), agentIconAsset('opencode'));
      expect(agentIconAsset('herdr:opencode'), agentIconAsset('opencode'));
      expect(agentIconAsset('herdr:pi'), agentIconAsset('pi'));
      expect(agentIconAsset('kilo code'), agentIconAsset('kilo'));
    });
  });

  group('fallback', () {
    testWidgets('an unknown id draws the monogram and does not throw',
        (tester) async {
      for (final unknown in ['aider', 'some-agent-from-2030', '']) {
        await pumpIcon(tester, unknown);
        expect(tester.takeException(), isNull, reason: 'threw on "$unknown"');

        // No blank box: the glyph is there...
        expect(
          find.text(agentGlyph(unknown)),
          findsOneWidget,
          reason: '"$unknown" drew no glyph',
        );
        // ...and it sits on the same chip as every brand mark, carrying the
        // catch-all identity rather than nothing. An unknown agent must not be
        // the one row that looks different.
        final box = chipBox(tester);
        expect(chipStops(box), identityFor(unknown).stops);
        expect(box.constraints?.maxWidth, 18);
        final text = tester.widget<Text>(find.text(agentGlyph(unknown)));
        expect(text.style?.color, ink);
        // Not the first-class violet of a known agent: "we do not know what
        // this is" has to look like something.
        expect(chipStops(box), isNot(identityFor('claude').stops));
      }
    });

    testWidgets('the monogram chip matches the board chip it replaces',
        (tester) async {
      await pumpIcon(tester, 'omp');
      final box = chipBox(tester);
      expect(
        (box.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(Radii.uniform),
      );
      final text = tester.widget<Text>(find.text(agentGlyph('omp')));
      // Asserted against the token, not a literal: this used to be pinned to
      // `11`, so moving the app onto a type scale turned a design change into a
      // test failure. The test's job is "the monogram uses the app's smallest
      // readable rung", not "the number 11".
      expect(text.style?.fontSize, TextSize.micro);
      expect(text.style?.fontWeight, FontWeight.w600);
      expect(text.style?.height, 1);
      expect(text.style?.color, ink);
    });

    testWidgets('a larger size scales the monogram, not just the box',
        (tester) async {
      await pumpIcon(tester, 'omp', size: 36);
      final text = tester.widget<Text>(find.text(agentGlyph('omp')));
      expect(
        text.style?.fontSize,
        TextSize.micro * 2,
        reason: 'the glyph must scale with the chip, not stay a fixed 11pt',
      );
    });
  });

  group('brand marks', () {
    testWidgets('a known agent draws its asset on the shared chip',
        (tester) async {
      await pumpIcon(tester, 'claude');
      final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(picture.bytesLoader, isA<SvgAssetLoader>());
      expect(
        (picture.bytesLoader as SvgAssetLoader).assetName,
        agentIconAsset('claude'),
      );
      // And no monogram hiding alongside it.
      expect(find.text(agentGlyph('claude')), findsNothing);
      expect(chipStops(chipBox(tester)), identityFor('claude').stops);
    });

    testWidgets('every mark is flattened to one colour', (tester) async {
      // This is what removes the gradients. Four of the assets ship brand
      // gradients, and the app's design rules forbid gradients; stripping them
      // out of the SVG would mean editing vendor artwork and invalidating the
      // SHA-256 provenance the fetch script verifies, so the flattening happens
      // at paint time instead.
      for (final id in herdrAgentIds) {
        if (agentIconAsset(id) == null) continue;
        await pumpIcon(tester, id);
        final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
        final filter = picture.colorFilter;
        expect(filter, isNotNull, reason: '$id is not flattened');
        expect(filter, const ColorFilter.mode(ink, BlendMode.srcIn),
            reason: '$id is flattened to something other than ink');
      }
    });

    testWidgets('the chip carries the same identity on BOTH grounds',
        (tester) async {
      // Not themed, and that is the point. An identity that flipped with the
      // mode would put a dark mark on a dark gradient in the light theme, and
      // the vocabulary would become two vocabularies.
      for (final colors in [HerdrColors.dark, HerdrColors.light]) {
        for (final id in ['cursor', 'kimi', 'claude', 'omp']) {
          await pumpIcon(tester, id, colors: colors);
          expect(
            chipStops(chipBox(tester)),
            identityFor(id).stops,
            reason: '$id on ${colors.brightness}',
          );
        }
      }
    });

    testWidgets('a saturated chip needs no outline on either ground',
        (tester) async {
      // The outline existed because a WHITE chip on a white card is not a chip.
      // A saturated gradient is its own edge in both modes, so the border is
      // gone rather than kept "just in case" — a border that draws nothing
      // useful is a border that will be copy-pasted somewhere it shows.
      for (final colors in [HerdrColors.dark, HerdrColors.light]) {
        await pumpIcon(tester, 'omp', colors: colors);
        expect(
          (chipBox(tester).decoration! as BoxDecoration).border,
          isNull,
          reason: 'on ${colors.brightness}',
        );
      }
    });

    testWidgets('two agents get two different chips', (tester) async {
      // The whole reason identity colour exists: a board of chips has to be
      // scannable by colour before the marks are legible at 18 points.
      await pumpIcon(tester, 'claude');
      final claude = chipStops(chipBox(tester));
      await pumpIcon(tester, 'codex');
      final codex = chipStops(chipBox(tester));
      await pumpIcon(tester, 'omp');
      final unknown = chipStops(chipBox(tester));

      expect(claude, isNot(codex));
      expect(claude, isNot(unknown));
      expect(codex, isNot(unknown));
    });

    testWidgets('a mark is inset so it clears the chip edge', (tester) async {
      await pumpIcon(tester, 'cursor', size: 18);
      final box = chipBox(tester);
      expect(box.constraints?.maxWidth, 18);
      expect(
        (box.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(Radii.uniform),
      );
      final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(picture.width, lessThan(18));
      expect(picture.width, greaterThan(0));
    });

    testWidgets('the monogram and a mark occupy the same footprint',
        (tester) async {
      // A row must not change shape depending on whether herdr taught this
      // build about an agent yet.
      await pumpIcon(tester, 'claude');
      final withMark = tester.getSize(find.byType(Container).first);
      await pumpIcon(tester, 'omp');
      final withMonogram = tester.getSize(find.byType(Container).first);
      expect(withMark, withMonogram);
      expect(withMark, const Size(18, 18));
    });
  });
}
