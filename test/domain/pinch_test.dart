import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/pinch.dart';

/// The two-finger pinch, without a widget or a binding.
///
/// Every case here is a way the terminal could resize somebody's window by
/// accident. They all look the same on screen — a terminal that reflows at the
/// wrong moment — so the arithmetic is pinned down where it can be read.
void main() {
  test('does nothing until the fingers move far enough', () {
    final hand = _Hand(200);
    final t = hand.tracker;

    hand.spread(12);
    expect(t.isPinching, isFalse, reason: '12 points is under the arm');
    expect(t.scale, 1);

    hand.spread(7);
    expect(
      t.isPinching,
      isFalse,
      reason: 'a hand settling is not a pinch',
    );
    expect(t.scale, 1);
  });

  test('pulling the fingers apart scales up, from exactly 1.0', () {
    final hand = _Hand(200);
    final t = hand.tracker;

    hand.spread(24);
    expect(t.isPinching, isTrue);
    expect(
      t.scale,
      closeTo(1, 1e-9),
      reason: 'the scale is measured from where the pinch armed — the fingers '
          'are 224 apart here — so the frame the gesture starts never jumps the '
          'text size',
    );

    // 448 apart: twice the gap the pinch armed at, so exactly twice the size.
    hand.spread(224);
    expect(t.scale, closeTo(2, 1e-9));
  });

  test('pushing them together scales down', () {
    final hand = _Hand(400);
    final t = hand.tracker;

    hand.spread(-24);
    expect(t.isPinching, isTrue);
    expect(t.scale, closeTo(1, 1e-9));

    hand.spread(-188); // half the gap it armed at
    expect(t.scale, closeTo(0.5, 1e-9));
  });

  test('two fingers travelling together are NOT a pinch', () {
    // The pane switch. Both fingers move 240px sideways without the user
    // changing the gap: if this armed, every swipe would resize the terminal.
    final hand = _Hand(200);
    final t = hand.tracker;
    for (var i = 1; i <= 40; i++) {
      // 6 points per event per finger: 240px of travel at 60 Hz.
      t.move(1, (x: 100 + i * 6, y: 300));
      t.move(2, (x: 300 + i * 6, y: 300));
    }
    expect(t.isPinching, isFalse);
    expect(t.scale, 1);
  });

  test('a swipe whose fingers lag each other is still not a pinch', () {
    // The same swipe, but one finger reporting a whole step behind the other —
    // what a real finger does while the hand accelerates. This is the case the
    // arming rule's second half exists for: the gap HAS changed by a lot, and
    // the pair has travelled just as far.
    final hand = _Hand(200);
    final t = hand.tracker;
    for (var i = 1; i <= 12; i++) {
      t.move(1, (x: 100 + i * 30, y: 300));
      t.move(2, (x: 300 + (i - 1) * 30, y: 300));
    }
    expect(t.isPinching, isFalse);
    expect(t.scale, 1);
  });

  test('a third finger ends the reading rather than guessing', () {
    final hand = _Hand(200);
    final t = hand.tracker;
    hand.spread(24);
    expect(t.isPinching, isTrue);
    hand.spread(40);
    final spread = t.scale;
    expect(spread, greaterThan(1));

    t.down(3, (x: 200, y: 500));
    t.move(1, (x: 20, y: 300));
    expect(
      t.scale,
      spread,
      reason: 'three pointers is not a pinch, and the last two-finger reading '
          'is what a caller mid-gesture should still see',
    );

    // Back to two: that is a new pinch, from where the two remaining fingers
    // are now, not a resumption of the old one.
    t.up(3);
    expect(t.isPinching, isFalse);
  });

  test('lifting a finger ends the pinch, and the scale stops there', () {
    final hand = _Hand(200);
    final t = hand.tracker;
    hand.spread(24);
    hand.spread(56); // 280 apart: a quarter bigger than the armed 224
    final scale = t.scale;
    expect(scale, closeTo(1.25, 1e-9));
    expect(t.isPinching, isTrue);

    hand.tracker.up(2);
    expect(t.isPinching, isFalse);
    expect(
      t.scale,
      scale,
      reason: 'a caller reading the scale as the gesture ends must get the '
          'value the user let go at, not 1.0',
    );
  });

  test('a new gesture starts from scratch', () {
    final first = _Hand(200);
    first.spread(24);
    expect(first.tracker.isPinching, isTrue);
    first.tracker
      ..up(1)
      ..up(2);

    // Fingers land again, closer together than the last gesture ended. Nothing
    // from the previous pinch may leak into this one.
    final second = _Hand(100);
    final t = second.tracker;
    expect(t.isPinching, isFalse);
    expect(t.scale, 1);

    second.spread(24);
    expect(t.isPinching, isTrue);
    expect(t.scale, closeTo(1, 1e-9));
    second.spread(124); // gap 248 = 2x where this one armed
    expect(t.scale, closeTo(2, 1e-9));
  });
}

/// Two fingers on a screen, moved the way the platform reports them.
///
/// ONE POINTER PER EVENT, and that is the whole point of the helper: two fingers
/// travelling together report a few points apart, so the gap wobbles for the
/// entire gesture, and that wobble is what the arming rule has to survive.
class _Hand {
  _Hand(double gap) : _gap = gap {
    tracker
      ..down(1, (x: 200 - gap / 2, y: 300))
      ..down(2, (x: 200 + gap / 2, y: 300));
  }

  final PinchTracker tracker = PinchTracker();
  double _gap;

  /// Changes the distance between the fingers by [amount], symmetrically.
  void spread(double amount) {
    _gap += amount;
    tracker.move(1, (x: 200 - _gap / 2, y: 300));
    tracker.move(2, (x: 200 + _gap / 2, y: 300));
  }
}
