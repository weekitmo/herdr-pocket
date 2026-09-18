import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/window.dart';

/// The arithmetic that decides what the phone asks for and what it shows.
///
/// Worth testing on its own because both answers were WRONG in a way nobody
/// could see in the code: the daemon crops a pane rather than reflowing it, so
/// asking for the widget's height quietly discarded the bottom of it — which is
/// where the agent's input box lives. The measurement behind the rules is
/// recorded in the module's own docs; these tests pin the rules themselves.
void main() {
  group('what to ask for', () {
    test("the pane's own height wins over the widget's", () {
      // The case that was broken: a 46-row pane on a phone whose box fits 24.
      // Asking for 24 rows returns rows 1-24 of the pane — a terminal with its
      // bottom, and therefore its composer, missing.
      expect(rowsToRequest(paneRows: 46, boxRows: 24), 46);
    });

    test('a pane SHORTER than the box is still asked for exactly', () {
      // Not the box's height: the extra rows come back as blank padding, which
      // pushes the pane's real last line further from the key bar.
      expect(rowsToRequest(paneRows: 20, boxRows: 55), 20);
    });

    test('an unknown pane height falls back to the box', () {
      // A tree that could not be read, or a pane that just appeared: correct but
      // keyboard-dependent, which is the old behaviour rather than a crash.
      expect(rowsToRequest(paneRows: 0, boxRows: 40), 40);
      expect(rowsToRequest(paneRows: -3, boxRows: 40), 40);
    });
  });

  group('what to show', () {
    test('a frame shorter than the box gets its spare rows ABOVE it', () {
      // THE PHONE REPORT THIS PINS: 「键盘/聊天窗关闭后…下方似乎占着一段空白」.
      // A 48-row desktop pane on a phone whose box fits 66 left 18 rows of
      // empty terminal under the picture, with the pane's status bar floating
      // in the middle of the screen. The spare rows go at the top, so the
      // pane's last row stays against the key bar — which is also what
      // `rowsToRequest` promises when it refuses to pad the frame from the
      // daemon.
      final placed = framePlacement(
        frameRows: 48,
        boxRows: 66,
        following: true,
      );
      expect(placed.skip, 0);
      expect(placed.pad, 18);
      expect(
        placed.pad + 48,
        66,
        reason: "the pane's last row lands on the box's last row",
      );
    });

    test('a frame taller than the box shows its BOTTOM', () {
      // The keyboard took 11 rows: the pane's last row belongs just above the
      // key bar, not 11 rows below the screen.
      final placed = framePlacement(
        frameRows: 46,
        boxRows: 35,
        following: true,
      );
      expect(placed.skip, 11);
      expect(placed.pad, 0);
    });

    test('exactly fitting needs neither shift nor padding', () {
      final placed = framePlacement(
        frameRows: 35,
        boxRows: 35,
        following: true,
      );
      expect(placed.skip, 0);
      expect(placed.pad, 0);
    });

    test('scrolled back, the top of the frame is where the reader is', () {
      // The frame the daemon sent IS the region they asked for, so shifting it
      // would move the text out from under the eye that asked for it.
      final placed = framePlacement(
        frameRows: 46,
        boxRows: 35,
        following: false,
      );
      expect(placed.skip, 0);
      expect(placed.pad, 0);
    });

    test('scrolled back in a box TALLER than the frame still pads the top', () {
      // Nothing is cropped in this direction, so the reader's position cannot
      // be disturbed by the padding — and leaving it at the top would make the
      // whole picture jump down every time they scrolled back to the live end.
      final placed = framePlacement(
        frameRows: 48,
        boxRows: 66,
        following: false,
      );
      expect(placed.pad, 18);
    });

    test('nonsense in, no shift out', () {
      for (final following in [true, false]) {
        final zero = framePlacement(
          frameRows: 0,
          boxRows: 35,
          following: following,
        );
        expect(zero.skip, 0);
        expect(zero.pad, 0);

        final alsoZero = framePlacement(
          frameRows: 46,
          boxRows: 0,
          following: following,
        );
        expect(alsoZero.skip, 0);
        expect(alsoZero.pad, 0);
      }
    });
  });
}
