import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_identity.dart';
import 'package:herdr_pocket/domain/theme/chrome_tokens.dart';

/// The identity vocabulary.
///
/// The property this file exists to protect is not "claude is magenta" — it is
/// "EVERY chip carries white ink". That one is checkable for any agent, in any
/// future version of the vocabulary, and it is the reason the palette could be
/// taken from a design document without each entry being inspected by hand.
void main() {
  test('every chip carries white ink on BOTH ends of its gradient', () {
    // Far more than the five the vocabulary holds, because the guarantee has to
    // survive the next person adding an agent — including one whose colour they
    // pick by eye.
    const agents = [
      'claude', 'claude-code', 'codex', 'codex-cli', 'gemini',
      'pi', 'omp', 'qodercli', 'antigravity-cli', 'kimi', 'grok',
      'mastracode', 'opencode', 'cursor', 'devin', 'copilot',
      'kiro', 'amp', 'qwen', '', 'zed',
    ];
    for (final agent in agents) {
      final identity = identityFor(agent);
      for (final stop in identity.stops) {
        expect(
          contrastRatio(identityInkHex, stop),
          greaterThanOrEqualTo(identityInkFloor - 0.005),
          reason: '$agent: white on ${identity.from} -> ${identity.to}',
        );
      }
    }
  });

  test("the vocabulary is the design language's, unmodified where it passes", () {
    // These three already clear the floor at the published values, so they must
    // come back byte-identical. If enforcement ever starts nudging colours that
    // were fine, every agent's chip silently changes and nobody knows why.
    expect(identityFor('claude').stops, ['#CE58A4', '#A32E77']);
    expect(identityFor('gemini').stops, ['#4C6EF5', '#2E44C4']);
    expect(identityFor('omp').stops, ['#8B79F6', '#5B44C9']);
  });

  test('the two that failed the floor are corrected, not replaced', () {
    // codex `#E8923C` measures 2.45:1 and pi `#3FB6A8` 2.50:1 as published.
    // They are darkened toward black, which preserves the hue, rather than
    // swapped for a different colour that would no longer be the design
    // language's `codex orange`.
    final codex = identityFor('codex');
    final pi = identityFor('pi');
    expect(codex.from, isNot('#E8923C'));
    expect(pi.from, isNot('#3FB6A8'));

    // Same hue: every channel of the corrected value still points the same way
    // and the ordering of the channels is preserved (orange stays red>green>blue).
    (int, int, int) channels(String hex) => rgb(hex);
    final (r, g, b) = channels(codex.from);
    expect(r, greaterThan(g));
    expect(g, greaterThan(b));
    expect(r, lessThanOrEqualTo(0xE8));
    expect(r, greaterThan(0xB0));
  });

  test('every agent id gets a chip — there is no "no colour" outcome', () {
    for (final agent in ['claude', 'omp', 'zed', '']) {
      expect(identityFor(agent).matched, isNotEmpty);
    }
    // The catch-all is what makes the above true, so it must exist and must be
    // last: an empty needle in the middle of the list would swallow everything
    // after it.
    expect(identityVocabulary.last.$1, isEmpty);
    expect(identityVocabulary.where((e) => e.$1.isEmpty), hasLength(1));
  });

  test('an unknown agent is distinguishable from a known one', () {
    // Otherwise the board's "we do not know what this is" would look identical
    // to a first-class agent, and the fail-closed grouping would have no
    // visual counterpart.
    expect(identityFor('zed').stops, isNot(identityFor('claude').stops));
    expect(identityFor('zed').stops, isNot(identityFor('pi').stops));
  });
}
