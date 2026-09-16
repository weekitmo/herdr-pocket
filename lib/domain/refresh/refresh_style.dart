import 'dart:math' as math;

/// The three refresh animations, in the order the user named them.
///
/// PURE DATA ON PURPOSE. Which animation plays is not a drawing decision — it
/// is a sequence with a rule ("never the same twice in a row, all three before
/// any repeats"), and that rule is arithmetic nobody can eyeball. Keeping it
/// here means it is testable without a widget, without a pull gesture and
/// without a clock.
enum RefreshStyle {
  /// A plane climbing through cloud — `TaurusHeader` in easy_refresh, ported
  /// there from SmartRefreshLayout's `TaurusHeader`. "冲上云霄".
  soaring,

  /// A body circling a star, with the pull angle driving the orbit.
  /// "太空轨道" — the original is a Rive animation in `easy_refresh_space`.
  orbit,

  /// A parcel swinging under balloons. `DeliveryHeader`, "气球快递".
  delivery,
}

/// Hands out one style per pull.
///
/// TWO REQUIREMENTS THAT PULL IN OPPOSITE DIRECTIONS, which is why this is a
/// deck rather than either simple thing:
///
///   * "a DIFFERENT one each time" — so a plain `random()` is out, it repeats;
///   * "cycles through all three" — so a fixed rotation is out, it is
///     predictable to the point of being furniture.
///
/// A shuffled deck gives both: every cycle contains each style exactly once, in
/// an order nobody can guess — and the seam between cycles is guarded, because
/// the one repetition a shuffled deck CAN produce is the last style of one
/// cycle followed by the first of the next. That is the only "same animation
/// twice in a row" a user would ever notice, and it is the one this prevents.
class RefreshStyleDeck {
  RefreshStyleDeck({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;
  final List<RefreshStyle> _remaining = <RefreshStyle>[];
  RefreshStyle? _last;

  /// The number of styles, so a test can say "a full cycle" without importing
  /// the enum's length from two places.
  static int get deckSize => RefreshStyle.values.length;

  /// The next style to play.
  RefreshStyle next() {
    if (_remaining.isEmpty) _refill();
    final style = _remaining.removeAt(0);
    _last = style;
    return style;
  }

  /// The style most recently handed out, or null before the first pull.
  RefreshStyle? get last => _last;

  void _refill() {
    _remaining
      ..clear()
      ..addAll(RefreshStyle.values)
      ..shuffle(_random);

    // THE SEAM. Swapping the first entry with a random LATER one rather than
    // re-shuffling: a re-shuffle could come back with the same opener and loop
    // forever in a pathological Random, and this cannot.
    final last = _last;
    if (last != null && _remaining.length > 1 && _remaining.first == last) {
      final swapWith = 1 + _random.nextInt(_remaining.length - 1);
      _remaining[0] = _remaining[swapWith];
      _remaining[swapWith] = last;
    }
  }
}
