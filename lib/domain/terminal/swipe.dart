/// Reading a two-finger horizontal swipe out of raw pointer positions.
///
/// WHY THIS IS IN THE DOMAIN: the decision — "were those two fingers travelling
/// together sideways, and which way" — is the part that can be wrong, and it
/// can be tested here without a binding. `dart:ui` is Flutter (the purity test
/// says so, and `Offset` lives there), so positions are plain numbers.
///
/// WHY IT EXISTS AT ALL: a `ScaleGestureRecognizer` beside the terminal's
/// scroll pan wins the arena with a SINGLE pointer and starves scrolling. A
/// [Listener] does not enter the arena at all — it only observes — so the
/// recognition has to be done by hand, and that is what this class is.
/// It also answers the question the gesture layer cannot: whether MORE THAN ONE
/// pointer was ever down, which is how the one-finger swipe avoids firing during
/// a two-finger gesture.
library;

/// A pointer position, as two numbers rather than an `Offset`.
typedef PointerPoint = ({double x, double y});

/// Recognises a two-finger horizontal swipe.
///
/// Deliberately strict. A two-finger switch is a big, deliberate movement, and
/// the cost of a false positive is a terminal that jumps to another agent while
/// somebody is pinching or resting a thumb on the screen.
class TwoFingerSwipeTracker {
  TwoFingerSwipeTracker({
    this.minDistance = 40,
    this.axisRatio = 2.0,
  });

  /// How far both fingers must travel before it counts, in logical pixels.
  final double minDistance;

  /// How much more horizontal than vertical the travel must be.
  ///
  /// Two, not one: a 45° drag is somebody being sloppy, not somebody swiping
  /// sideways, and the terminal's own vertical scroll is the thing this must not
  /// steal from.
  final double axisRatio;

  final Map<int, PointerPoint> _starts = {};
  final Map<int, PointerPoint> _current = {};
  bool _sawMultiple = false;
  bool _fired = false;
  int? _pending;

  /// True once two or more pointers have been down at the same time during the
  /// current gesture (i.e. until every pointer is lifted).
  ///
  /// This is the guard that keeps a two-finger swipe from ALSO being read as a
  /// one-finger one: both fingers land within milliseconds of each other, but
  /// the first can move far enough to satisfy the single-finger recogniser
  /// before the second arrives. Timing cannot fix that; this can.
  bool get sawMultiplePointers => _sawMultiple;

  /// True while at least one pointer is down.
  bool get isTracking => _starts.isNotEmpty;

  void down(int pointer, PointerPoint at) {
    if (_starts.isEmpty) {
      // A fresh gesture: the latch and the multi-pointer flag start over.
      _fired = false;
      _pending = null;
      _sawMultiple = false;
    }
    _starts[pointer] = at;
    _current[pointer] = at;
    if (_starts.length > 1) _sawMultiple = true;
  }

  void move(int pointer, PointerPoint to) {
    if (!_starts.containsKey(pointer)) return;
    _current[pointer] = to;
    if (_fired) return;
    // Exactly two. Three fingers is a different gesture (and never a pane
    // switch), so it is not guessed at.
    if (_starts.length != 2) return;

    final pointers = _starts.keys.toList(growable: false);
    final dxs = <double>[];
    for (final id in pointers) {
      final start = _starts[id]!;
      final now = _current[id]!;
      final dx = now.x - start.x;
      final dy = now.y - start.y;
      if (dx.abs() < minDistance) return;
      if (dx.abs() <= axisRatio * dy.abs()) return;
      dxs.add(dx);
    }

    if (dxs.length != 2) return;
    if (dxs[0].isNegative != dxs[1].isNegative) return;

    _fired = true;
    // Swiping LEFT moves forward, the way paging works everywhere else.
    _pending = dxs[0].isNegative ? 1 : -1;
  }

  void up(int pointer) {
    _starts.remove(pointer);
    _current.remove(pointer);
    if (_starts.isEmpty) _sawMultiple = false;
  }

  /// The direction of the swipe, taken exactly once.
  ///
  /// +1 is "forward" (the fingers went left), -1 is "back".
  int? takeDirection() {
    final direction = _pending;
    _pending = null;
    return direction;
  }
}
