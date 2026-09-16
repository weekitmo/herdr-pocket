import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/refresh/refresh_style.dart';

/// The rule that decides which refresh animation plays.
///
/// Two promises were made to the user in one sentence — "a different one each
/// time" and "all three, in turn" — and they are the two ways a naive
/// implementation fails:
///
///   * `values[count % 3]` is perfectly even and completely predictable, which
///     is furniture rather than a delight;
///   * `values[random()]` is unpredictable and repeats, which is the one thing
///     the user asked it not to do.
///
/// A shuffled deck does both, and the interesting case is the seam between two
/// cycles: the last style of one deck and the first of the next CAN be the same,
/// and that is the only repetition a person would notice.
void main() {
  test('a full cycle contains every style exactly once', () {
    final deck = RefreshStyleDeck(random: math.Random(1));

    final cycle = [for (var i = 0; i < RefreshStyleDeck.deckSize; i++) deck.next()];

    expect(cycle.toSet(), RefreshStyle.values.toSet());
    expect(cycle.length, RefreshStyle.values.length);
  });

  test('it never plays the same animation twice in a row', () {
    // Thirty pulls is ten full cycles, so the seam is crossed nine times. A
    // deck that only shuffled would fail this roughly two times in three.
    for (var seed = 0; seed < 50; seed++) {
      final deck = RefreshStyleDeck(random: math.Random(seed));
      var previous = deck.next();
      for (var i = 0; i < 30; i++) {
        final next = deck.next();
        expect(
          next,
          isNot(previous),
          reason: 'seed $seed repeated $next at pull $i',
        );
        previous = next;
      }
    }
  });

  test('the order is not fixed', () {
    // The failure mode of a deck built too carefully: sorting it, or seeding it
    // from a constant, and shipping a rotation that looks random to its author
    // and like clockwork to everyone else.
    final orders = <String>{};
    for (var seed = 0; seed < 12; seed++) {
      final deck = RefreshStyleDeck(random: math.Random(seed));
      orders.add([
        for (var i = 0; i < RefreshStyleDeck.deckSize; i++) deck.next().name,
      ].join(','));
    }
    expect(orders.length, greaterThan(1));
  });

  test('a seeded deck is reproducible', () {
    List<RefreshStyle> run() {
      final deck = RefreshStyleDeck(random: math.Random(7));
      return [for (var i = 0; i < 6; i++) deck.next()];
    }

    expect(run(), run());
  });
}
