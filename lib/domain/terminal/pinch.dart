/// Reading a two-finger pinch out of raw pointer positions.
///
/// WHY THIS IS IN THE DOMAIN: "were those two fingers pulled apart, and by how
/// much" is the part that can be wrong, and it can be tested here without a
/// binding. `dart:ui` is Flutter (the purity test says so, and `Offset` lives
/// there), so positions are plain numbers.
///
/// WHY NOT `ScaleGestureRecognizer`: it enters the gesture arena, and beside the
/// terminal's scroll pan it wins with a SINGLE pointer and starves scrolling —
/// the same reason [TwoFingerSwipeTracker] exists. A `Listener` observes pointers
/// without competing, so the arithmetic has to be done by hand, and this is it.
///
/// WHAT IT REFUSES TO CALL A PINCH. A two-finger swipe (which this app already
/// uses to change panes) moves both fingers the same way, and the platform
/// reports them one at a time: the gap between them therefore wobbles for the
/// whole gesture. Two fingers resting do the same. So a pinch only ARMS when the
/// gap has changed by [armDistance] AND that change is bigger than the distance
/// the pair has TRAVELLED — a pinch moves the fingers apart, a swipe moves them
/// along. From the arming point the reported scale starts at exactly 1.0, so
/// nothing on screen jumps on the frame it begins.
library;

import 'dart:math' as math;

import 'package:herdr_pocket/domain/terminal/swipe.dart';

/// A two-finger pinch, as a scale factor.
class PinchTracker {
  PinchTracker({this.armDistance = 24, this.dominance = 2});

  /// How much the distance between the fingers must change, in logical pixels,
  /// before this is a pinch rather than a two-finger drag.
  ///
  /// Comfortably above the wobble of two fingers travelling together: those
  /// report a few points apart at 60 Hz, not tens.
  final double armDistance;

  /// How much bigger the gap change must be than the pair's own travel.
  ///
  /// Two, not one: while a swipe accelerates, one finger leads and the other
  /// catches up, so the gap change is about half the travel. Two excludes the
  /// swipe without coming near a real pinch, where the fingers move in opposite
  /// directions and the midpoint barely moves at all.
  ///
  /// STRICTLY greater, not "at least": a finger reporting a whole step behind
  /// its partner lands exactly ON that boundary, and a knife-edge comparison is
  /// how a swipe zooms the terminal on one phone and not another.
  final double dominance;

  final Map<int, PointerPoint> _points = {};

  ({double gap, double midX, double midY})? _baseline;

  /// The gap the reported scale is measured against. Non-null IS "this is a
  /// pinch now".
  double? _armedAt;

  /// The most recent two-pointer gap, so a scale read after one finger lifts
  /// still describes the gesture rather than snapping back to 1.
  double? _latest;

  /// The factor the last pinch ended at.
  ///
  /// A caller commits a size change WHEN THE GESTURE ENDS, and "the fingers
  /// lifted" and "read the value" are two different moments. Snapping back to
  /// 1 in between would undo the pinch on every release.
  double? _frozen;

  /// True between the moment the fingers have moved far enough apart (or
  /// together) and the moment one of them lifts.
  bool get isPinching => _armedAt != null;

  /// How much bigger the gap is now than when the pinch armed.
  ///
  /// 1.0 when this is not a pinch. Never zero, never negative: a caller
  /// multiplies a size by it.
  double get scale {
    final armed = _armedAt;
    final latest = _latest;
    if (armed != null && latest != null && armed > 0) return latest / armed;
    return _frozen ?? 1;
  }

  void down(int pointer, PointerPoint at) {
    if (_points.isEmpty) {
      // A fresh gesture: nothing carries over from the last one.
      _baseline = null;
      _armedAt = null;
      _latest = null;
      _frozen = null;
    }
    _points[pointer] = at;
    if (_points.length == 2) _baseline = _geometry;
  }

  void move(int pointer, PointerPoint to) {
    if (!_points.containsKey(pointer)) return;
    _points[pointer] = to;

    // Exactly two, as with the swipe tracker. Three fingers is a different
    // gesture and is not guessed at.
    if (_points.length != 2) return;
    final now = _geometry;
    if (now == null) return;

    if (_armedAt == null) {
      if (!_shouldArm(now)) return;
      _armedAt = now.gap;
    }
    _latest = now.gap;
  }

  void up(int pointer) {
    _points.remove(pointer);
    if (_points.length == 2) {
      // One of three fingers lifted: the two that are left are a new pinch,
      // measured from where they are now.
      _freeze();
      _baseline = _geometry;
      _armedAt = null;
      return;
    }
    if (_points.length < 2) {
      _freeze();
      _baseline = null;
      _armedAt = null;
    }
  }

  /// Remembers the factor this gesture reached, before the tracking is cleared.
  void _freeze() {
    if (_armedAt == null) return;
    _frozen = scale;
  }

  bool _shouldArm(({double gap, double midX, double midY}) now) {
    final baseline = _baseline;
    if (baseline == null) return false;
    final change = (now.gap - baseline.gap).abs();
    if (change < armDistance) return false;
    final travel = math.sqrt(
      math.pow(now.midX - baseline.midX, 2) +
          math.pow(now.midY - baseline.midY, 2),
    );
    return change > travel * dominance;
  }

  /// The gap between the two pointers and where they are centred, or null when
  /// there are not exactly two of them.
  ({double gap, double midX, double midY})? get _geometry {
    if (_points.length != 2) return null;
    final points = _points.values.toList(growable: false);
    final dx = points[0].x - points[1].x;
    final dy = points[0].y - points[1].y;
    return (
      gap: math.sqrt(dx * dx + dy * dy),
      midX: (points[0].x + points[1].x) / 2,
      midY: (points[0].y + points[1].y) / 2,
    );
  }
}
