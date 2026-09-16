import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/swipe.dart';

/// Reading a two-finger swipe by hand, because a scale recogniser would starve
/// the scroll pan.
///
/// Most of these tests are about NOT firing: the cost of a false positive is a
/// terminal that jumps to another agent while somebody is reading.
void main() {
  PointerPoint p(double x, double y) => (x: x, y: y);

  test('two fingers travelling left together go forward', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(100, 300));
    tracker.down(2, p(140, 400));
    tracker.move(1, p(40, 305));
    tracker.move(2, p(80, 404));

    expect(tracker.takeDirection(), 1);
    // Taken once: a gesture is one navigation, not one per move event.
    expect(tracker.takeDirection(), isNull);
  });

  test('two fingers travelling right go back', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(100, 300));
    tracker.down(2, p(140, 400));
    tracker.move(1, p(200, 300));
    tracker.move(2, p(240, 400));

    expect(tracker.takeDirection(), -1);
  });

  test('fingers travelling OPPOSITE ways is not a swipe', () {
    // That is a pinch, or somebody's two hands. Neither is a navigation.
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(100, 300));
    tracker.down(2, p(240, 300));
    tracker.move(1, p(40, 300));
    tracker.move(2, p(300, 300));

    expect(tracker.takeDirection(), isNull);
  });

  test('a short movement is not a swipe', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(100, 300));
    tracker.down(2, p(140, 300));
    tracker.move(1, p(80, 300));
    tracker.move(2, p(120, 300));

    expect(tracker.takeDirection(), isNull);
  });

  test('a diagonal drag is not a swipe', () {
    // 45° is somebody being sloppy, not somebody swiping sideways — and the
    // terminal's vertical scroll is what this must not steal from.
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(300, 100));
    tracker.down(2, p(300, 200));
    tracker.move(1, p(240, 160));
    tracker.move(2, p(240, 260));

    expect(tracker.takeDirection(), isNull);
  });

  test('only ONE of the two fingers travelling is not a swipe', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(300, 100));
    tracker.down(2, p(300, 200));
    tracker.move(1, p(200, 100));
    // The second finger has not moved yet.
    expect(tracker.takeDirection(), isNull);
  });

  test('one finger never fires', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(300, 100));
    tracker.move(1, p(100, 100));
    expect(tracker.takeDirection(), isNull);
  });

  test('three fingers are not guessed at', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(300, 100));
    tracker.down(2, p(300, 200));
    tracker.down(3, p(300, 300));
    tracker.move(1, p(100, 100));
    tracker.move(2, p(100, 200));
    tracker.move(3, p(100, 300));
    expect(tracker.takeDirection(), isNull);
  });

  group('sawMultiplePointers is what protects the one-finger swipe', () {
    test('a second finger landing marks the gesture as multi-pointer', () {
      // Both fingers land within milliseconds, but the FIRST can move far
      // enough to satisfy the single-finger recogniser before the second
      // arrives. Timing cannot fix that; this flag can.
      final tracker = TwoFingerSwipeTracker();
      tracker.down(1, p(300, 100));
      tracker.move(1, p(200, 100));
      expect(tracker.sawMultiplePointers, isFalse);

      tracker.down(2, p(300, 200));
      expect(tracker.sawMultiplePointers, isTrue);
    });

    test('it clears only when every pointer is up', () {
      final tracker = TwoFingerSwipeTracker();
      tracker.down(1, p(300, 100));
      tracker.down(2, p(300, 200));
      tracker.up(1);
      expect(tracker.sawMultiplePointers, isTrue);
      tracker.up(2);
      expect(tracker.sawMultiplePointers, isFalse);
    });

    test('a cancelled pointer counts as lifted', () {
      final tracker = TwoFingerSwipeTracker();
      tracker.down(1, p(300, 100));
      tracker.down(2, p(300, 200));
      tracker.up(1);
      tracker.up(2);
      expect(tracker.isTracking, isFalse);
      expect(tracker.sawMultiplePointers, isFalse);
    });
  });

  test('the latch resets when a new gesture starts', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.down(1, p(300, 100));
    tracker.down(2, p(300, 200));
    tracker.move(1, p(100, 100));
    tracker.move(2, p(100, 200));
    expect(tracker.takeDirection(), 1);
    tracker.up(1);
    tracker.up(2);

    tracker.down(1, p(300, 100));
    tracker.down(2, p(300, 200));
    tracker.move(1, p(500, 100));
    tracker.move(2, p(500, 200));
    expect(tracker.takeDirection(), -1);
  });

  test('a move for a pointer that never went down is ignored', () {
    final tracker = TwoFingerSwipeTracker();
    tracker.move(9, p(0, 0));
    expect(tracker.isTracking, isFalse);
    expect(tracker.takeDirection(), isNull);
  });
}
