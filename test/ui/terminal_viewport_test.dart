import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';

/// Tests for the viewport arithmetic behind terminal scrolling.
///
/// This is worth testing because it is the kind of code that reads as obviously
/// correct and is off by one in three places at once: the window is anchored to
/// the END of the buffer, the offset counts backwards, and both ends clamp. A
/// wrong answer here does not throw — it silently shows the wrong slice of
/// history, which is exactly the sort of bug that survives a demo.
void main() {
  group('following the live screen (offset 0)', () {
    test('shows the LAST viewHeight lines', () {
      final v = terminalViewport(
        totalLines: 1000,
        viewHeight: 24,
        scrollOffset: 0,
      );
      expect(v.start, 976);
      expect(v.rowCount, 24);
    });

    test('a buffer shorter than the viewport starts at zero', () {
      final v = terminalViewport(
        totalLines: 10,
        viewHeight: 24,
        scrollOffset: 0,
      );
      expect(v.start, 0);
      // Only what exists, so the painter does not walk off the end.
      expect(v.rowCount, 10);
    });
  });

  group('scrolled back', () {
    test('one line back shifts the window up by one', () {
      final v = terminalViewport(
        totalLines: 1000,
        viewHeight: 24,
        scrollOffset: 1,
      );
      expect(v.start, 975);
      expect(v.rowCount, 24);
    });

    test('scrolling back never runs off the top of the buffer', () {
      final v = terminalViewport(
        totalLines: 100,
        viewHeight: 24,
        scrollOffset: 100000,
      );
      // Clamped to the earliest full window, not to a negative start.
      expect(v.start, 0);
      expect(v.rowCount, 24);
    });

    test('the whole history is reachable', () {
      final v = terminalViewport(
        totalLines: 100,
        viewHeight: 24,
        scrollOffset: 76,
      );
      // 100 - 24 = 76, so this is the very first screenful.
      expect(v.start, 0);
      expect(v.rowCount, 24);
    });
  });

  group('degenerate inputs', () {
    test('an empty buffer produces an empty window', () {
      final v = terminalViewport(
        totalLines: 0,
        viewHeight: 24,
        scrollOffset: 0,
      );
      expect(v.rowCount, 0);
    });

    test('a zero-height viewport produces an empty window', () {
      // Happens for one frame while a keyboard animation is running.
      final v = terminalViewport(
        totalLines: 100,
        viewHeight: 0,
        scrollOffset: 0,
      );
      expect(v.rowCount, 0);
    });

    test('a negative offset is treated as following', () {
      // The drag code clamps, but a negative here would silently show a window
      // past the end of the buffer.
      final v = terminalViewport(
        totalLines: 100,
        viewHeight: 24,
        scrollOffset: -5,
      );
      expect(v.start, 76);
    });
  });

  group('the property that makes scrolling usable', () {
    test('the window is anchored to the bottom, so new lines do not move it',
        () {
      // Reading history while output arrives is the common case. With the
      // window anchored to the end of the buffer, the SAME offset always means
      // the same distance back from the present — the caller compensates the
      // offset as lines arrive, and this asserts the arithmetic it relies on.
      final before = terminalViewport(
        totalLines: 1000,
        viewHeight: 24,
        scrollOffset: 10,
      );
      final after = terminalViewport(
        // Ten new lines arrived and the caller added 10 to the offset.
        totalLines: 1010,
        viewHeight: 24,
        scrollOffset: 20,
      );
      expect(after.start, before.start);
    });
  });
}
