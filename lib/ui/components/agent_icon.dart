import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:herdr_pocket/domain/agent/agent_identity.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Agent id (or one of its aliases) -> its brand mark.
///
/// Keys are canonical ids; every asset is named after its key, so the map and
/// the directory cannot drift apart unnoticed (and `test/ui/agent_icon_test.dart`
/// fails if one does).
///
/// The files are the vendors' own artwork, straight from Lobehub. They are NOT
/// rendered in the vendors' colours: see [AgentIcon] for why, and
/// `assets/agent_icons/README.md` for what that means for each asset.
const Map<String, String> _marks = {
  'amp': 'assets/agent_icons/amp.svg',
  'antigravity': 'assets/agent_icons/antigravity.svg',
  'claude': 'assets/agent_icons/claude.svg',
  'cline': 'assets/agent_icons/cline.svg',
  'codex': 'assets/agent_icons/codex.svg',
  'copilot': 'assets/agent_icons/copilot.svg',
  'cursor': 'assets/agent_icons/cursor.svg',
  'deepseek': 'assets/agent_icons/deepseek.svg',
  'devin': 'assets/agent_icons/devin.svg',
  'gemini': 'assets/agent_icons/gemini.svg',
  'grok': 'assets/agent_icons/grok.svg',
  'kimi': 'assets/agent_icons/kimi.svg',
  'kiro': 'assets/agent_icons/kiro.svg',
  'mastracode': 'assets/agent_icons/mastracode.svg',
  'opencode': 'assets/agent_icons/opencode.svg',
  'pi': 'assets/agent_icons/pi.svg',
  'qodercli': 'assets/agent_icons/qodercli.svg',
  'qwen': 'assets/agent_icons/qwen.svg',
};

/// Aliases the daemon itself declares, mapped to the canonical id.
///
/// Taken from the `aliases = [...]` line of each `AgentManifest` inside the
/// herdr 0.9.0 binary, so this is herdr's own spelling of the rule rather than
/// a guess. One product gets one mark: `claude-code` is not a second Claude.
const Map<String, String> _aliases = {
  // `agy` is the manifest id and `antigravity-cli` the integration name.
  'agy': 'antigravity',
  'antigravity-cli': 'antigravity',
  'claude-code': 'claude',
  'cursor-agent': 'cursor',
  'devin-cli': 'devin',
  'grok-build': 'grok',
  'kilo-code': 'kilo',
  'kimi-code': 'kimi',
  'kiro-cli': 'kiro',
  'open-code': 'opencode',
  'qoder': 'qodercli',
  'qodercn': 'qodercli',
  'qoderclicn': 'qodercli',
  'qwen-code': 'qwen',
  'github-copilot': 'copilot',
  'ghcs': 'copilot',
  'amp-local': 'amp',
};

/// Aliases this build declares, because the daemon declares none for them.
///
/// [_aliases] above is transcribed from herdr's own manifests — every spelling
/// in it is a spelling herdr ships. This table is the other kind of id, and it
/// is the reason the mark map has an entry no integration installs.
///
/// **herdr detects an agent from a manifest, and a manifest's `id` is whatever
/// its author typed.** A TUI with no published integration is detected by a
/// manifest its own author wrote, so it reaches the daemon under a name no
/// vendor list can predict — the live example on this workstation is the
/// DeepSeek harness, whose `dsh-agent-state` plugin reports its pane as `dsh`.
/// Three spellings of it are known: `dsh`, `deepseek-tui` (the package name),
/// and `deepseek` itself, which is the canonical id and owns the file.
///
/// `dsh` is spelled out rather than handled as a prefix on purpose. It is three
/// letters that also name an unrelated Unix tool (the `dsh` distributed shell),
/// and the rule this whole directory follows is that a plausible wrong brand is
/// worse than a letter — see the `hermes` rejection in
/// `assets/agent_icons/README.md`. The unambiguous vendor prefix is handled by
/// [_familyPrefixes] instead.
const Map<String, String> _localAliases = {'dsh': 'deepseek'};

/// Vendor families: every id under the prefix is one product.
///
/// Nobody tells this app what the next DeepSeek CLI will be called — a manifest
/// author types the id by hand — so `deepseek-tui`, `deepseek-cli` and a future
/// `deepseek-r2` are one prefix rather than a list that goes stale. Only ids
/// that still have no mark reach here, so a prefix can never take an id away
/// from the two tables above it, and a prefix only ever redirects to a mark
/// that exists.
const List<(String, String)> _familyPrefixes = [('deepseek', 'deepseek')];

/// Every agent id this build knows a daemon can hand it.
///
/// The first two sources are herdr's own, and neither is complete on its own:
/// the 17 integrations in `herdr integration list`, and the ids carrying an
/// `AgentManifest` in `herdr api` — the second adds `gemini`, `agy`, `cline`,
/// `amp`, `kiro`, and also `maki` and `muse`, which no integration installs yet.
///
/// `deepseek` is the third, and it is not a list herdr ships at all: no
/// integration installs it and no bundled manifest declares it. It arrives
/// because herdr detects an agent from a manifest, and a manifest's id is
/// written by whoever authored it — see [_localAliases]. It is listed here so
/// the coverage tests in `test/ui/agent_icon_test.dart` reach its asset too.
///
/// The list is deliberately open: a future herdr release WILL add an id, that
/// id WILL land on the monogram, and that is a correct outcome — an unknown
/// agent draws a letter, never a blank square.
const List<String> herdrAgentIds = [
  'pi',
  'omp',
  'claude',
  'codex',
  'copilot',
  'devin',
  'droid',
  'kimi',
  'opencode',
  'kilo',
  'hermes',
  'qodercli',
  'qwen',
  'cursor',
  'mastracode',
  'antigravity-cli',
  'grok',
  'gemini',
  'cline',
  'agy',
  'amp',
  'kiro',
  'maki',
  'muse',
  'deepseek',
];

/// Canonicalises an agent id exactly as it comes off the wire.
///
/// Returns null when there is nothing to identify. Three drifts are folded in:
/// the daemon's own `herdr:` prefix on synthetic ids, case, and separators —
/// herdr spells the same product `open-code`, `open_code` and `opencode`
/// depending on whether you are reading a manifest, a struct field or a pane.
///
/// This does NOT apply the alias table: `agy` and `antigravity-cli` normalise
/// to themselves here. Use [agentIconId] for the id that owns a file.
String? normalizeAgentId(String agent) {
  var id = agent.trim().toLowerCase();
  if (id.startsWith('herdr:')) id = id.substring('herdr:'.length);
  id = id.replaceAll(RegExp(r'[\s_]+'), '-').trim();
  return id.isEmpty ? null : id;
}

/// The canonical id whose mark stands for [agent], or null if nobody publishes
/// one.
///
/// The single place aliases are resolved, so `agy`, `antigravity` and
/// `antigravity-cli` can never grow two icons for one product — and neither can
/// `dsh`, `deepseek-tui` and `deepseek`.
String? agentIconId(String agent) {
  final id = normalizeAgentId(agent);
  if (id == null) return null;
  final canonical = _aliases[id] ?? _localAliases[id] ?? _familyOf(id) ?? id;
  return _marks.containsKey(canonical) ? canonical : null;
}

/// The family a vendor-prefixed id belongs to, or null when it is not one.
String? _familyOf(String id) {
  for (final (prefix, canonical) in _familyPrefixes) {
    if (id.startsWith(prefix)) return canonical;
  }
  return null;
}

/// The asset path for an agent, or null when it has no brand mark.
///
/// A null answer is not a failure: it is the signal to draw the monogram.
String? agentIconAsset(String agent) {
  final id = agentIconId(agent);
  return id == null ? null : _marks[id];
}

/// The mark for one agent, at one size, on any ground.
///
/// ONE TREATMENT FOR EVERYTHING: a chip carrying the agent's identity gradient
/// with a solid white mark on it. There is no third outcome and no per-asset
/// special case — a real brand mark where one exists, the letter monogram
/// everywhere else, and both drawn the same way.
///
/// THE COLOUR IS OURS, NOT THE VENDORS'. Three versions of this have now been
/// built, and the order they happened in is the argument:
///
///   1. **Each vendor's artwork as published.** Reverted. Six marks were pure
///      black and rendered as literally nothing on the dark theme, one was
///      white and vanished on the light theme, four carried gradients in four
///      unrelated palettes, and Qoder had two halves that each needed the
///      opposite ground. Seventeen sources, seventeen rules, and the board read
///      as a collection of logos rather than as a system.
///   2. **A white plate with a black mark.** One rule, and it worked — but it
///      made the identity chip achromatic, which is a strange thing for the one
///      element the design language sets aside for decorative colour.
///   3. **This.** The chip carries a gradient from [identityFor] and the mark
///      is white. Still one rule; now the rule has the colour in it.
///
/// WHAT MADE 3 POSSIBLE when 1 failed is that the gradient is OURS. It comes
/// from the design language's identity vocabulary (`claude` magenta, `codex`
/// orange, `gemini` indigo, violet for everything else), so the palette is
/// already this app's, and every chip is guaranteed to carry white ink by
/// construction rather than by inspection. The vendor files still supply only
/// the SHAPE.
///
/// FLATTENING IS THE POINT, not a leftover. `BlendMode.srcIn` paints the
/// rendered picture in one colour, which is what removes the vendors' own
/// gradients — stripping them out of the SVG instead would mean editing vendor
/// artwork and invalidating the SHA-256 provenance the fetch script checks.
class AgentIcon extends StatelessWidget {
  /// Draws [agent]'s mark, or its monogram, in a [size] x [size] box.
  const AgentIcon({required this.agent, this.size = 18, super.key});

  /// herdr's agent id, e.g. `claude`, `codex`, `antigravity-cli`.
  final String agent;

  /// Width and height of the box. 18 matches the board's identity chip.
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = agentIconAsset(agent);

    return _Plate(
      size: size,
      identity: identityFor(agent),
      child: asset == null
          ? _Monogram(agent: agent, size: size)
          : SvgPicture.asset(
              asset,
              width: size * _markScale,
              height: size * _markScale,
              excludeFromSemantics: true,
              // Flattens fills, strokes and the vendor's own gradients to one
              // colour in a single pass, so no asset needs preprocessing.
              colorFilter: const ColorFilter.mode(ink, BlendMode.srcIn),
              errorBuilder: (_, _, _) =>
                  _Monogram(agent: agent, size: size),
            ),
    );
  }
}

/// The mark's colour, fixed rather than themed.
///
/// The chip must look the same in both modes. A mark that flipped to dark in
/// the light theme would need a second, darker gradient set to stay legible on,
/// and the identity vocabulary would become two vocabularies.
const Color ink = Color(0xFFFFFFFF);

/// The identity chip. Also the monogram's chip, so the two outcomes have the
/// same footprint and a missing asset cannot change a row's shape.
class _Plate extends StatelessWidget {
  const _Plate({
    required this.size,
    required this.identity,
    required this.child,
  });

  final double size;
  final AgentIdentity identity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Top-leading to bottom-trailing, as the design language specifies for
        // this chip. Same direction as the terminal's specular edge, so the
        // whole app reads as lit from the same corner.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HerdrColors.colorFromHex(identity.from),
            HerdrColors.colorFromHex(identity.to),
          ],
        ),
        borderRadius: BorderRadius.circular(Radii.uniform),
      ),
      child: child,
    );
  }
}

/// The letter chip: same plate, same ink, a glyph instead of a mark.
///
/// Not `SizedBox.shrink()` for an empty id, which is what the board used to do:
/// an unidentifiable agent shows `?` rather than nothing, so "we have no mark"
/// never looks like "the layout broke".
class _Monogram extends StatelessWidget {
  const _Monogram({required this.agent, required this.size});

  final String agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      agentGlyph(agent),
      style: TextStyle(
        color: ink,
        fontSize: _monogramFontSize * size / _monogramFontSizeAt,
        fontWeight: FontWeight.w600,
        height: 1,
      ),
    );
  }
}

/// A mark is inset so it does not touch the plate's edge — the same optical
/// weight the 11pt monogram glyph has in an 18pt chip.
const double _markScale = 0.62;

/// The board chip's glyph size, and the box it was designed for. Kept as a
/// ratio so a caller passing a larger [AgentIcon.size] gets a proportional
/// monogram rather than an 11pt glyph adrift in a big square.
const double _monogramFontSize = TextSize.micro;
const double _monogramFontSizeAt = 18;
