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
    test('a frame that fits is drawn from the top', () {
      expect(
        firstVisibleRow(frameRows: 20, boxRows: 40, following: true),
        0,
      );
    });

    test('a frame taller than the box shows its BOTTOM', () {
      // The keyboard took 11 rows: the pane's last row belongs just above the
      // key bar, not 11 rows below the screen.
      expect(
        firstVisibleRow(frameRows: 46, boxRows: 35, following: true),
        11,
      );
    });

    test('exactly fitting needs no shift', () {
      expect(
        firstVisibleRow(frameRows: 35, boxRows: 35, following: true),
        0,
      );
    });

    test('scrolled back, the top of the frame is where the reader is', () {
      // The frame the daemon sent IS the region they asked for, so shifting it
      // would move the text out from under the eye that asked for it.
      expect(
        firstVisibleRow(frameRows: 46, boxRows: 35, following: false),
        0,
      );
    });

    test('nonsense in, no shift out', () {
      expect(firstVisibleRow(frameRows: 0, boxRows: 35, following: true), 0);
      expect(firstVisibleRow(frameRows: 46, boxRows: 0, following: true), 0);
    });
  });
}
