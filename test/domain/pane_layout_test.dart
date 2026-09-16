import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/workspace/pane_layout.dart';

/// The shapes here are trimmed copies of real `pane.layout` output from a live
/// herdr 0.9.0 (protocol 22): a 192x48 machine area, a sidebar tab split
/// 0.4886/0.5114, and a three-pane tab split twice.
///
/// The geometry is worth testing because being wrong does not throw. A pane
/// lands a few pixels off, or a cell too narrow, and the view reads as slightly
/// sloppy rather than broken — which is how a mirroring bug survives a demo.
void main() {
  group('scaling', () {
    const area = CellRect(x: 0, y: 0, width: 192, height: 48);

    test('a pane fills the tab when it is the whole tab', () {
      final box = scalePaneToBox(
        pane: const CellRect(x: 0, y: 0, width: 192, height: 48),
        area: area,
        container: (width: 360, height: 600),
      );
      expect(box.left, 0);
      expect(box.top, 0);
      expect(box.width, 360);
      expect(box.height, 600);
    });

    test('a half-width split keeps its half, in both axes', () {
      // w9:t3: two 96x48 panes side by side.
      final left = scalePaneToBox(
        pane: const CellRect(x: 0, y: 0, width: 96, height: 48),
        area: area,
        container: (width: 360, height: 600),
      );
      final right = scalePaneToBox(
        pane: const CellRect(x: 96, y: 0, width: 96, height: 48),
        area: area,
        container: (width: 360, height: 600),
      );
      expect(left.width, 180);
      expect(right.left, 180);
      expect(right.width, 180);
      // They must meet exactly: a one-pixel gap is a seam nobody drew.
      expect(left.left + left.width, right.left);
    });

    test('a lopsided split keeps its share rather than rounding to even', () {
      // w9:t5: 94/98 and wC:t1's 47/49/96 — the real ratios are not 50/50, and
      // an implementation that quartered the box would look plausible and be
      // wrong for every user who ever dragged a divider.
      final sidebar = scalePaneToBox(
        pane: const CellRect(x: 0, y: 0, width: 47, height: 48),
        area: area,
        container: (width: 400, height: 600),
      );
      expect(sidebar.width, closeTo(400 * 47 / 192, 0.001));
      expect(sidebar.width, lessThan(120));
    });

    test('an offset area is subtracted, not ignored', () {
      // The daemon's area does not have to start at the origin; using the
      // absolute rect would push every pane off by the origin.
      final box = scalePaneToBox(
        pane: const CellRect(x: 10, y: 5, width: 90, height: 43),
        area: const CellRect(x: 10, y: 5, width: 180, height: 90),
        container: (width: 200, height: 100),
      );
      expect(box.left, 0);
      expect(box.top, 0);
      expect(box.width, 100);
    });

    test('a degenerate area or container gives no box rather than NaN', () {
      final zero = scalePaneToBox(
        pane: const CellRect(x: 0, y: 0, width: 10, height: 10),
        area: const CellRect(x: 0, y: 0, width: 0, height: 0),
        container: (width: 100, height: 100),
      );
      expect(zero.width, 0);
      expect(zero.height, 0);

      final noRoom = scalePaneToBox(
        pane: const CellRect(x: 0, y: 0, width: 10, height: 10),
        area: const CellRect(x: 0, y: 0, width: 10, height: 10),
        container: (width: 0, height: 100),
      );
      expect(noRoom.width, 0);
    });
  });

  group('grid size', () {
    test('the cells asked for fit inside the box', () {
      // Asking for a column the box cannot show makes the daemon reflow the
      // program to a width that does not fit, and the right edge is clipped
      // instead of laid out.
      final grid = gridForBox(
        box: (left: 0, top: 0, width: 180, height: 300),
        cellWidth: 7.2,
        cellHeight: 15,
      );
      expect(grid.cols, 25); // 180 / 7.2
      expect(grid.rows, 20); // 300 / 15
      expect(grid.cols * 7.2, lessThanOrEqualTo(180));
    });

    test('a sliver still gets a usable terminal', () {
      final grid = gridForBox(
        box: (left: 0, top: 0, width: 12, height: 8),
        cellWidth: 7.2,
        cellHeight: 15,
      );
      expect(grid.cols, 8);
      expect(grid.rows, 2);
    });

    test('a zero-sized cell does not divide by zero', () {
      final grid = gridForBox(
        box: (left: 0, top: 0, width: 100, height: 100),
        cellWidth: 0,
        cellHeight: 0,
      );
      expect(grid.cols, 8);
      expect(grid.rows, 2);
    });
  });

  group('seams', () {
    test('a left/right split draws one vertical seam at the divider', () {
      final layout = TabLayout.fromJson({
        'workspace_id': 'w9',
        'tab_id': 'w9:t3',
        'area': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
        'panes': [
          {
            'pane_id': 'w9:p3',
            'focused': true,
            'rect': {'x': 0, 'y': 0, 'width': 96, 'height': 48},
          },
          {
            'pane_id': 'w9:p6',
            'rect': {'x': 96, 'y': 0, 'width': 96, 'height': 48},
          },
        ],
        'splits': [
          {
            'id': 'split_0_root',
            'direction': 'right',
            'ratio': 0.5,
            'rect': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
          },
        ],
      });

      final seams = seamBoxes(
        layout: layout,
        container: (width: 360, height: 600),
      );
      expect(seams, hasLength(1));
      expect(seams.single.left, 180);
      expect(seams.single.top, 0);
      expect(seams.single.width, 1);
      expect(seams.single.height, 600);
    });

    test('a top/bottom split draws a horizontal seam', () {
      final layout = TabLayout.fromJson({
        'area': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
        'panes': const [],
        'splits': [
          {
            'direction': 'down',
            'rect': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
          },
        ],
      });

      final seams = seamBoxes(
        layout: layout,
        container: (width: 360, height: 600),
      );
      expect(seams.single.top, 300);
      expect(seams.single.width, 360);
      expect(seams.single.height, 1);
    });

    test('a split with no room is skipped rather than drawn wrong', () {
      final layout = TabLayout.fromJson({
        'area': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
        'panes': const [],
        'splits': [
          {
            'direction': 'right',
            'rect': {'x': 0, 'y': 0, 'width': 1, 'height': 48},
          },
        ],
      });
      expect(
        seamBoxes(layout: layout, container: (width: 1, height: 600)),
        isEmpty,
      );
    });
  });

  group('parsing', () {
    test('a real pane.layout reply round-trips', () {
      final layout = TabLayout.fromJson({
        'workspace_id': 'wC',
        'tab_id': 'wC:t1',
        'zoomed': false,
        'area': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
        'focused_pane_id': 'wC:p1',
        'panes': [
          {
            'pane_id': 'wC:p5',
            'focused': false,
            'rect': {'x': 0, 'y': 0, 'width': 47, 'height': 48},
          },
          {
            'pane_id': 'wC:p1',
            'focused': true,
            'rect': {'x': 47, 'y': 0, 'width': 49, 'height': 48},
          },
          {
            'pane_id': 'wC:p4',
            'focused': false,
            'rect': {'x': 96, 'y': 0, 'width': 96, 'height': 48},
          },
        ],
        'splits': [
          {
            'id': 'split_0_root',
            'direction': 'right',
            'ratio': 0.5,
            'rect': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
          },
          {
            'id': 'split_1_0',
            'direction': 'right',
            'ratio': 0.4946233,
            'rect': {'x': 0, 'y': 0, 'width': 96, 'height': 48},
          },
        ],
      });

      expect(layout.tabId, 'wC:t1');
      expect(layout.panes, hasLength(3));
      expect(layout.splits, hasLength(2));
      expect(layout.focusedPaneId, 'wC:p1');
      expect(layout.isSplit, isTrue);
      expect(layout.isEmpty, isFalse);
      expect(layout.panes[2].rect.width, 96);
      // The nested split's rectangle is the LEFT HALF, so its seam lands at a
      // quarter of the tab rather than in the middle of it.
      final seams = seamBoxes(
        layout: layout,
        container: (width: 400, height: 400),
      );
      expect(seams.map((s) => s.left).toList(), [200, 100]);
    });

    test('a single-pane tab is not a split', () {
      final layout = TabLayout.fromJson({
        'tab_id': 'w9:t1',
        'zoomed': false,
        'area': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
        'panes': [
          {
            'pane_id': 'w9:p1',
            'focused': true,
            'rect': {'x': 0, 'y': 0, 'width': 192, 'height': 48},
          },
        ],
        'splits': const [],
      });
      expect(layout.isSplit, isFalse);
    });

    test('missing and mistyped fields degrade rather than throw', () {
      // The daemon's field set drifts across versions, and a client that
      // crashes on a shape it did not expect is worse than one that shows a
      // slightly poorer screen.
      final layout = TabLayout.fromJson({
        'panes': [
          {'pane_id': 'w9:p1', 'rect': 'not a map'},
          'not a map at all',
          {'rect': {'x': 0, 'y': 0, 'width': 5, 'height': 5}},
        ],
      });
      // An entry that is not an object at all is skipped; one that IS an
      // object with a bad field keeps its place and degrades field by field.
      // Dropping the second kind would move the remaining panes, and the
      // rectangles are the one thing this type exists to get right.
      expect(layout.panes, hasLength(2));
      expect(layout.panes.first.rect.width, 0);
      expect(layout.panes.last.paneId, '');
      expect(layout.area.isEmpty, isTrue);
      expect(layout.tabId, '');
    });
  });
}
