/// Agent identity — the one place this app is allowed to be decorative.
///
/// WHY THIS EXISTS AT ALL. Everything else in herdr-pocket is achromatic on
/// purpose: exactly four hues carry meaning (waiting, died, working, done) and
/// the rest is indigo-tinted neutral, because a board where colour appears
/// everywhere is a board where colour stops being a signal. The design language
/// carves out exactly one exception —
///
///     "Agent identity gradients — the *one* place colour is allowed to be
///      decorative"  (docs/research/03-design-language.md, from herdrup's
///      DesignSystem.swift:118-131, itself from the Termius reference)
///
/// — and until now that exception went unused. The identity chip drew every
/// agent the same way, so the one sanctioned slot for colour in the whole
/// product was empty.
///
/// WHAT THIS IS NOT. It is not the vendors' artwork. Rendering seventeen brand
/// marks in their own colours was tried and reverted (see
/// `assets/agent_icons/README.md`): six arrived pure black and read as nothing
/// on the dark theme, one was white and vanished on the light theme, four
/// carried gradients in colours from four different palettes, and Qoder had two
/// halves that each needed the opposite ground. Seventeen sources produced
/// seventeen rules and the board read as a collection of logos rather than as a
/// system.
///
/// This is the opposite approach: ONE rule, and the colour comes from OUR
/// vocabulary — a pair of hues per agent, drawn top-left to bottom-right behind
/// a white mark. Two agents are told apart by the colour of their chip and the
/// shape on it, and no vendor gets to decide what this app looks like.
library;

import 'package:herdr_pocket/domain/theme/chrome_tokens.dart';

/// The ink every identity chip is drawn in.
///
/// White, as the design language specifies for this chip. It also happens to be
/// the only value that works over an arbitrary saturated gradient: a fixed dark
/// ink would sink into the indigo and orange ends.
const String identityInkHex = '#FFFFFF';

/// What [identityInkHex] has to clear, on BOTH ends of the gradient.
///
/// 3.0 is the non-text floor, and a brand mark is non-text — it is a shape, and
/// the chip is always accompanied by the agent's name. It is not a lower bar
/// than the app's text tiers out of convenience: the app already holds glyphs
/// to 3.0 (`ContrastFloor.shape`), and identity chips are 18–26 points with a
/// name beside them.
const double identityInkFloor = 3;

/// One agent's gradient, resolved.
class AgentIdentity {
  const AgentIdentity({
    required this.agent,
    required this.from,
    required this.to,
    required this.matched,
  });

  /// The id this was resolved for, kept for tests and for error messages.
  final String agent;

  /// `#rrggbb`, top-leading.
  final String from;

  /// `#rrggbb`, bottom-trailing.
  final String to;

  /// Which entry of the vocabulary matched — `claude`, `codex`, `gemini`,
  /// `pi` or `default`. Exposed because "this agent fell through to the
  /// catch-all" is a fact a screen or a test may legitimately want, and it
  /// cannot be recovered from two hex strings.
  final String matched;

  /// The two stops, in drawing order.
  List<String> get stops => [from, to];
}

/// The vocabulary, keyed by the substring looked for in a herdr agent id.
///
/// The first four pairs are quoted from the design language and are NOT ours to
/// retune in the middle of the gradient — the whole point of a shared identity
/// vocabulary is that the same agent is the same colour in two clients. `pi` is
/// this build's addition, because pi is the agent this workspace actually runs
/// and giving it the catch-all violet would make it indistinguishable from
/// every unknown agent on the board.
///
/// Order matters: the first match wins, so `claude-code` and `claude` land
/// together while `codex-cli` cannot be caught by a broader earlier entry.
const List<(String, String, String)> identityVocabulary = [
  ('claude', '#CE58A4', '#A32E77'), // magenta
  ('codex', '#E8923C', '#C5622A'), // orange
  ('gemini', '#4C6EF5', '#2E44C4'), // indigo, deliberately kept off `working`
  ('pi', '#3FB6A8', '#2A8479'), // teal
  ('', '#8B79F6', '#5B44C9'), // the catch-all violet
];

/// WHY THERE IS EXACTLY ONE CATCH-ALL AND NOT A HUE PER UNKNOWN AGENT.
///
/// It was measured rather than assumed, and the first measurement was the wrong
/// question — recorded here because the correction is the useful part.
///
/// ```text
/// status hues   waiting 36.8   died 4.1   working 212.8   done 142.9
/// identity hues claude 321.4   codex 30.0  gemini 227.9   pi 172.9   default 248.6
/// ```
///
/// Asking for a hue at least 30 degrees from EVERY status hue AND every
/// identity leaves only 59 of 360 degrees, which reads as "there is no room".
/// That is too strict a question. The law constrains identity against the four
/// STATUS hues, not against other identities, and loosening the exclusion to
/// just the status hues reopens a 91-degree arc (242.8 .. 334.1: violet through
/// magenta to pink).
///
/// So room does exist, and the decision not to use it is a judgement rather
/// than a constraint — which is the honest thing to write down:
///
///   * that arc already holds the catch-all violet and `claude`, so anything
///     added is a fourth or fifth purple. Four purples across a wrapping grid
///     are harder to tell apart than one violet plus four different monogram
///     letters, which is exactly the kind of "eight plates and nine bare marks"
///     outcome the first attempt at this ended in.
///   * the monogram already distinguishes unfamiliar agents from one another,
///     so the hue is not the only channel — see [agentGlyph] in the UI layer.
///
/// Known and accepted, measured rather than eyeballed: `codex` at 30.0 sits 6.8
/// degrees from `waiting` at 36.8, and `gemini` at 227.9 sits 15 from `working`
/// at 212.8 — so this vocabulary does not achieve 30-degree separation from the
/// status hues either, upstream does not, and neither is changed. Colour is
/// never the only channel here: status is an 8-point dot under a group heading,
/// identity is an 18-point chip beside the agent's own name.
AgentIdentity identityFor(String agent) {
  final lower = agent.toLowerCase();
  for (final (needle, from, to) in identityVocabulary) {
    if (needle.isEmpty || lower.contains(needle)) {
      return AgentIdentity(
        agent: agent,
        from: enforce(from, identityInkHex, identityInkFloor),
        to: enforce(to, identityInkHex, identityInkFloor),
        matched: needle.isEmpty ? 'default' : needle,
      );
    }
  }
  // Unreachable: the catch-all has an empty needle and matches everything.
  throw StateError('identity vocabulary has no catch-all');
}
