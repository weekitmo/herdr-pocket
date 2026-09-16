import 'dart:math' as math;

/// A rectangle in the machine's own terminal cells.
///
/// Not pixels, and not "logical pixels" either: this is what the daemon computed
/// for its own screen, and every pane's position and the area they sit in are in
/// the same units, so the ratios between them survive being scaled to a phone.
class CellRect {
  const CellRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory CellRect.fromJson(Map<String, Object?> json) => CellRect(
        x: _int(json['x']),
        y: _int(json['y']),
        width: _int(json['width']),
        height: _int(json['height']),
      );

  final int x;
  final int y;
  final int width;
  final int height;

  bool get isEmpty => width <= 0 || height <= 0;

  static int _int(Object? v) => v is int ? v : 0;
}

/// One pane's place in a tab.
class LayoutPane {
  const LayoutPane({
    required this.paneId,
    required this.rect,
    this.isFocused = false,
  });

  factory LayoutPane.fromJson(Map<String, Object?> json) => LayoutPane(
        paneId: json['pane_id'] is String ? json['pane_id']! as String : '',
        rect: CellRect.fromJson(_map(json['rect'])),
        isFocused: json['focused'] == true,
      );

  final String paneId;
  final CellRect rect;
  final bool isFocused;
}

/// A split in the tab's tree, carried for the seam it describes.
///
/// The panes' own rectangles are enough to LAY OUT the view; this exists so the
/// seams can be drawn where the daemon put them rather than inferred from where
/// two rectangles happen to touch, which stops being true the moment panes do
/// not tile exactly.
class LayoutSplit {
  const LayoutSplit({required this.direction, required this.rect});

  factory LayoutSplit.fromJson(Map<String, Object?> json) => LayoutSplit(
        direction: json['direction'] == 'down'
            ? SplitAxis.vertical
            : SplitAxis.horizontal,
        rect: CellRect.fromJson(_map(json['rect'])),
      );

  final SplitAxis direction;
  final CellRect rect;
}

/// Which way a split divides its rectangle.
enum SplitAxis {
  /// Side by side — the seam runs top to bottom.
  horizontal,

  /// Stacked — the seam runs left to right.
  vertical,
}

/// One tab's arrangement, as the daemon computed it.
///
/// THE POINT OF THIS TYPE IS THAT IT IS THE MACHINE'S OWN GEOMETRY, not a
/// reconstruction. herdr tiles panes: a tab is a tree of splits, and a pane that
/// is a narrow sidebar column is narrow because the user made it that way. A
/// client that lists panes as rows throws that away — fine for "what needs me?",
/// wrong for "what does my screen look like?". So the daemon's rectangles are
/// carried through and only SCALED, never re-derived.
class TabLayout {
  const TabLayout({
    required this.workspaceId,
    required this.tabId,
    required this.area,
    required this.panes,
    this.focusedPaneId,
    this.zoomed = false,
    this.splits = const [],
  });

  /// Parses the `layout` object from `pane.layout` / `pane.edges`.
  factory TabLayout.fromJson(Map<String, Object?> json) {
    final rawPanes = json['panes'];
    final rawSplits = json['splits'];
    return TabLayout(
      workspaceId: _str(json['workspace_id']),
      tabId: _str(json['tab_id']),
      area: CellRect.fromJson(_map(json['area'])),
      focusedPaneId: json['focused_pane_id'] is String
          ? json['focused_pane_id']! as String
          : null,
      zoomed: json['zoomed'] == true,
      panes: rawPanes is List
          ? rawPanes
              .whereType<Map<Object?, Object?>>()
              .map((e) => LayoutPane.fromJson(e.cast<String, Object?>()))
              .toList(growable: false)
          : const [],
      splits: rawSplits is List
          ? rawSplits
              .whereType<Map<Object?, Object?>>()
              .map((e) => LayoutSplit.fromJson(e.cast<String, Object?>()))
              .toList(growable: false)
          : const [],
    );
  }

  factory TabLayout.empty() => const TabLayout(
        workspaceId: '',
        tabId: '',
        area: CellRect(x: 0, y: 0, width: 1, height: 1),
        panes: [],
      );

  final String workspaceId;
  final String tabId;

  /// The whole tab, in cells. Every pane rectangle sits inside this.
  final CellRect area;

  final List<LayoutPane> panes;
  final List<LayoutSplit> splits;
  final String? focusedPaneId;

  /// True when the user zoomed one pane to fill the tab. The daemon still
  /// reports the other panes' rectangles, so the view has to SAY which of the
  /// two it is showing rather than quietly hiding them.
  final bool zoomed;

  bool get isEmpty => panes.isEmpty || area.isEmpty;

  /// True when there is more than one pane, i.e. the view has something to
  /// mirror. A one-pane tab is not a split.
  bool get isSplit => panes.length > 1;

}

/// Narrows a decoded JSON value to a string-keyed map.
///
/// A file-level helper rather than a private static, because the two nested
/// types need it too and a static on the outer class is not reachable from a
/// sibling's factory.
Map<String, Object?> _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const {};

String _str(Object? v) => v is String ? v : '';

/// An axis-aligned box, in logical pixels.
///
/// A record rather than `dart:ui`'s `Rect`, deliberately: `dart:ui` pulls in the
/// Flutter engine, and this file is the geometry that has to be verifiable
/// without one. The arithmetic is the part worth testing; the container type is
/// not.
typedef PaneBox = ({double left, double top, double width, double height});

/// A width and a height.
typedef BoxSize = ({double width, double height});

/// The grid a pane's terminal should be rendered at.
typedef PaneGrid = ({int cols, int rows});

/// Scales the machine's geometry onto a phone-sized box.
///
/// Two different scalings happen here, and conflating them is the mistake this
/// function exists to prevent:
///
///   * POSITION is scaled so the tab FILLS the available box. The x and y
///     factors are computed separately, because the phone's aspect ratio has
///     nothing to do with the machine's — a 192x48 tab on a portrait phone is
///     stretched vertically. Preserving the machine's aspect would instead
///     letterbox the whole view into a thin strip and waste most of the screen.
///
///   * SIZE is whatever the pane's own box then works out to, in CHARACTERS.
///     The daemon renders at the size it is asked for, so a narrow sidebar
///     column is asked for ~20 columns and its program reflows — which is what a
///     terminal does when you narrow it, and is the whole reason mirroring the
///     geometry is worth anything.
///
/// Both ends use the SAME factors, so a pane keeps its share of the tab whether
/// it is a 47-cell sidebar or a 96-cell editor.
PaneBox scalePaneToBox({
  required CellRect pane,
  required CellRect area,
  required BoxSize container,
}) {
  if (area.isEmpty || container.width <= 0 || container.height <= 0) {
    return (left: 0, top: 0, width: 0, height: 0);
  }
  final sx = container.width / area.width;
  final sy = container.height / area.height;

  return (
    left: (pane.x - area.x) * sx,
    top: (pane.y - area.y) * sy,
    width: pane.width * sx,
    height: pane.height * sy,
  );
}

/// Which cells to ask the daemon to render into [box].
///
/// The floors are deliberate: asking for a size the box cannot show would make
/// the daemon reflow the program to a width that does not fit, and the content
/// would be clipped at the right instead of laid out for the space it has. The
/// minimums keep a sliver of a pane usable rather than a zero-column terminal,
/// which several programs answer with a single column of garbage.
PaneGrid gridForBox({
  required PaneBox box,
  required double cellWidth,
  required double cellHeight,
  int minCols = 8,
  int minRows = 2,
  int maxCols = 400,
  int maxRows = 400,
}) {
  if (cellWidth <= 0 || cellHeight <= 0) {
    return (cols: minCols, rows: minRows);
  }
  return (
    cols: math.max(minCols, math.min(maxCols, (box.width / cellWidth).floor())),
    rows: math.max(minRows, math.min(maxRows, (box.height / cellHeight).floor())),
  );
}

/// The seams between panes, in pixels.
///
/// Returned as one-pixel-thick BOXES to fill, not as lines to stroke: a hairline
/// stroked on a fractional boundary lands on half a device pixel and greys out,
/// which is the difference between "two terminals" and "two terminals someone
/// smudged".
///
/// A split whose rectangle is oriented against its direction is skipped rather
/// than drawn somewhere wrong — a seam in the wrong place reads as a pane
/// boundary that does not exist.
List<PaneBox> seamBoxes({
  required TabLayout layout,
  required BoxSize container,
}) {
  if (layout.area.isEmpty || container.width <= 0 || container.height <= 0) {
    return const [];
  }
  final out = <PaneBox>[];
  for (final split in layout.splits) {
    final box = scalePaneToBox(
      pane: split.rect,
      area: layout.area,
      container: container,
    );
    if (box.width <= 0 || box.height <= 0) continue;

    switch (split.direction) {
      case SplitAxis.horizontal when box.width > 1:
        final x = box.left + box.width / 2;
        out.add((left: x, top: box.top, width: 1, height: box.height));
      case SplitAxis.vertical when box.height > 1:
        final y = box.top + box.height / 2;
        out.add((left: box.left, top: y, width: box.width, height: 1));
      case SplitAxis.horizontal:
      case SplitAxis.vertical:
        break;
    }
  }
  return out;
}
