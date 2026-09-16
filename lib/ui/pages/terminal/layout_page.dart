import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/data/terminal/terminal_control.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/pane_layout.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:xterm/core.dart';

/// The tab as the machine has it laid out, with every pane live.
///
/// WHY THIS IS WORTH THE CHANNELS. The rest of the app shows one pane at a time
/// because that is the only way to READ a terminal on a phone. But herdr's whole
/// model is that a tab is a tiled arrangement — a narrow sidebar column beside an
/// editor, a shell under an agent — and a list of rows cannot express it. Someone
/// who set up three panes wants to see three panes; flattening that is the client
/// disagreeing with the machine.
///
/// So the daemon's own rectangles are mirrored (scaled, never re-derived) and
/// each pane is asked to render at the size its box works out to. The daemon
/// re-renders for the observer without touching the real session — verified
/// against a live daemon, where observing a pane at 40x12 left the pane's own
/// 48-row viewport untouched. That is what makes mirroring safe: the phone is a
/// viewer, never a resize.
///
/// Tapping a cell opens it full screen, because a 20-column terminal is a
/// thumbnail and not a place to type.
class LayoutPage extends ConsumerStatefulWidget {
  const LayoutPage({required this.paneId, required this.title, super.key});

  /// Any pane in the tab to show. `pane.layout` takes a pane and answers about
  /// its tab.
  final String paneId;
  final String title;

  @override
  ConsumerState<LayoutPage> createState() => _LayoutPageState();
}

class _LayoutPageState extends ConsumerState<LayoutPage> {
  TabLayout? _layout;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) {
      if (mounted) setState(() => _error = 'not connected');
      return;
    }
    try {
      final layout = await connection.client.paneLayout(paneId: widget.paneId);
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    // A pane appearing or closing changes the arrangement, and the tree already
    // knows when that happened — so the geometry rides the same signal instead
    // of polling for it.
    ref.listen(navTreeProvider, (_, _) => unawaited(_load()));

    final layout = _layout;
    final failure = _error;

    final Widget body;
    if (failure != null) {
      body = _Message(
        title: l10n.errorGeneric,
        body: '$failure',
        colors: colors,
        l10n: l10n,
        onRetry: () => unawaited(_load()),
      );
    } else if (layout == null) {
      body = _Message(
        title: l10n.layoutLoading,
        body: '',
        colors: colors,
        l10n: l10n,
        onRetry: null,
      );
    } else if (layout.isEmpty || !layout.isSplit) {
      // A one-pane tab has nothing to mirror, and rendering it as a single
      // full-bleed cell would only say "this is a terminal" twice.
      body = _Message(
        title: l10n.layoutEmpty,
        body: '',
        colors: colors,
        l10n: l10n,
        onRetry: () => unawaited(_load()),
      );
    } else {
      body = PaneSplitSurface(
        layout: layout,
        l10n: l10n,
        palette: resolveTerminalColors(ref.watch(selectedThemeProvider)),
        paneBuilder: (paneId, box) => _LivePane(
          paneId: paneId,
          box: box,
          label: paneId.split(':').last,
        ),
        onOpenPane: (paneId) => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => TerminalPage(
              paneId: paneId,
              title: _titleFor(paneId),
            ),
          ),
        ),
      );
    }

    return CupertinoPageScaffold(
      backgroundColor: colors.groundDeep,
      navigationBar: HerdrTopBar(
        // A mirror of the desktop's split layout, drawn to fill the page:
        // there is nothing to scroll, so the bar obstructs rather than floats.
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
        actions: [
          HerdrBarButton(
            label: l10n.actionRefresh,
            onPressed: () => unawaited(_load()),
            child: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ),
      child: SafeArea(child: body),
    );
  }

  String _titleFor(String paneId) {
    final tree = ref.read(navTreeProvider).value;
    final pane = tree?.paneById(paneId);
    return pane?.displayName ?? paneId;
  }
}

/// Lays the panes out where the daemon put them.
///
/// PUBLIC AND INJECTABLE on purpose. The positioning is the part that can be
/// wrong in a way nobody notices — a pane two pixels off, a seam in the wrong
/// place — and the only way to check it is to render it and measure. Taking the
/// pane body as a callback means a test can lay out REAL daemon geometry
/// without opening four SSH channels to draw it.
class PaneSplitSurface extends StatelessWidget {
  const PaneSplitSurface({
    required this.layout,
    required this.l10n,
    required this.paneBuilder,
    this.onOpenPane,
    this.palette = TerminalColors.dark,
    super.key,
  });

  final TabLayout layout;
  final AppLocalizations l10n;

  /// The terminal's colours.
  ///
  /// A parameter with a default rather than a `ref.watch` inside, because this
  /// widget is the one piece of the layout a test can drive with real daemon
  /// geometry and no daemon — and a widget that reads a provider cannot be
  /// built without a `ProviderScope`.
  final TerminalColors palette;

  /// Builds the body of one pane. Defaults to a live read-only observer; tests
  /// substitute a plain box.
  final Widget Function(String paneId, PaneBox box) paneBuilder;

  final ValueChanged<String>? onOpenPane;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final container = (
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );

        return Stack(
          children: [
            // The seams are painted rather than left to the gap between boxes:
            // panes tile exactly, so a gap would have to be manufactured by
            // shrinking them, and a shrunk pane renders fewer columns than its
            // share.
            for (final seam in seamBoxes(layout: layout, container: container))
              Positioned(
                left: seam.left,
                top: seam.top,
                width: seam.width,
                height: seam.height,
                child: ColoredBox(color: colors.hairline),
              ),
            for (final pane in layout.panes)
              _PositionedPane(
                box: scalePaneToBox(
                  pane: pane.rect,
                  area: layout.area,
                  container: container,
                ),
                pane: pane,
                l10n: l10n,
                palette: palette,
                onOpen: onOpenPane == null
                    ? null
                    : () => onOpenPane!(pane.paneId),
                child: paneBuilder(
                  pane.paneId,
                  scalePaneToBox(
                    pane: pane.rect,
                    area: layout.area,
                    container: container,
                  ),
                ),
              ),
            if (layout.zoomed)
              Positioned(
                left: Space.md,
                right: Space.md,
                bottom: Space.md,
                child: IgnorePointer(
                  child: _Chip(text: l10n.layoutZoomed),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PositionedPane extends StatelessWidget {
  const _PositionedPane({
    required this.box,
    required this.pane,
    required this.l10n,
    required this.palette,
    required this.child,
    required this.onOpen,
  });

  final PaneBox box;
  final LayoutPane pane;
  final AppLocalizations l10n;
  final TerminalColors palette;
  final Widget child;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    if (box.width <= 1 || box.height <= 1) return const SizedBox.shrink();

    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        // The key goes on the OUTER box — the one that occupies the pane's
        // rectangle — not on the body inside it. The border is drawn within
        // these bounds, so a key further in would measure a rectangle inset by
        // the border, and a test comparing it against the daemon's geometry
        // would be comparing the wrong thing.
        child: DecoratedBox(
          key: ValueKey<String>('pane-box-${pane.paneId}'),
          decoration: BoxDecoration(
            color: palette.background,
            border: Border.all(
              color: pane.isFocused ? colors.working : colors.hairlineQuiet,
              width: pane.isFocused ? 1.5 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// One pane, rendered live at its own size.
///
/// A READ-ONLY observer, never a controller. Several panes stream at once here,
/// and `control` would mean the phone claimed input on all of them — including
/// the pane the user is typing into on the machine. `observe` is the read-only
/// side of the same endpoint and cannot do that.
class _LivePane extends ConsumerStatefulWidget {
  const _LivePane({
    required this.paneId,
    required this.box,
    required this.label,
  });

  final String paneId;
  final PaneBox box;
  final String label;

  @override
  ConsumerState<_LivePane> createState() => _LivePaneState();
}

class _LivePaneState extends ConsumerState<_LivePane> {
  Terminal _terminal = Terminal(maxLines: 400);
  final _repaint = _Repaint();
  TerminalSession? _session;
  int _cols = 0;
  int _rows = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_attach()));
  }

  @override
  void didUpdateWidget(_LivePane old) {
    super.didUpdateWidget(old);
    if (old.paneId != widget.paneId) {
      unawaited(_reattach());
      return;
    }
    // A rotation or a refresh changes the box, and the daemon has to be told:
    // it renders at the size it was ASKED for, so a stale size means content
    // laid out for a box that no longer exists.
    final grid = _grid();
    if (grid.cols != _cols || grid.rows != _rows) {
      _cols = grid.cols;
      _rows = grid.rows;
      _session?.resize(grid.cols, grid.rows);
    }
  }

  @override
  void dispose() {
    _repaint.dispose();
    unawaited(_session?.close());
    super.dispose();
  }

  PaneGrid _grid() => gridForBox(
        box: widget.box,
        cellWidth: _lastCellWidth,
        cellHeight: _lastCellHeight,
      );

  double _lastCellWidth = 7.2;
  double _lastCellHeight = 15;

  Future<void> _reattach() async {
    final previous = _session;
    _session = null;
    _cols = 0;
    _rows = 0;
    await previous?.close();
    if (!mounted) return;
    _terminal = Terminal(maxLines: 400);
    _repaint.fire();
    await _attach();
  }

  Future<void> _attach() async {
    if (!mounted || _session != null) return;

    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) return;
    final transport = connection.client.transport;
    if (transport is! RemoteStreamRunner) return;

    final grid = _grid();
    _cols = grid.cols;
    _rows = grid.rows;

    try {
      final session = await TerminalControl.observe(
        transport as RemoteStreamRunner,
        paneId: widget.paneId,
        cols: grid.cols,
        rows: grid.rows,
      );
      if (!mounted) {
        await session.close();
        return;
      }
      _terminal.resize(grid.cols, grid.rows);
      session.frames.listen(
        (frame) {
          if (!mounted || _session != session) return;
          if (frame.width != _cols || frame.height != _rows) {
            _terminal.resize(frame.width, frame.height);
            _cols = frame.width;
            _rows = frame.height;
          }
          _terminal.write(frame.data);
          _repaint.fire();
        },
        onError: (Object _) {},
        onDone: () {},
      );
      setState(() => _session = session);
    } on Object {
      // A pane that cannot be observed still gets its frame drawn; the cell
      // shows the pane's name over an empty grid rather than vanishing, which
      // would silently change the arrangement the user is looking at.
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final palette = resolveTerminalColors(ref.watch(selectedThemeProvider));
    final metrics = CellMetrics.measure(
      text: '\u3000',
      style: const TextStyle(
        fontFamily: HerdrFonts.mono,
        fontSize: _paneFontSize,
        height: 1,
      ),
    );
    _lastCellWidth = metrics.width / 2;
    _lastCellHeight = metrics.height;

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: TerminalPainter(
            terminal: _terminal,
            palette: palette,
            cellWidth: _lastCellWidth,
            cellHeight: _lastCellHeight,
            fontFamily: HerdrFonts.mono,
            fontFamilyFallback: HerdrFonts.monoFallback,
            fontSize: _paneFontSize,
            cursorVisible: false,
            scrollOffset: 0,
            selection: null,
            repaint: _repaint,
          ),
        ),
        // The pane's own name, because at this size the contents identify
        // nothing and a wall of four terminals is unreadable without it.
        Positioned(
          left: Space.xs,
          top: Space.xs,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.groundDeep.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(Radii.uniform),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.sm,
                  vertical: 2,
                ),
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: TextSize.micro,
                    fontFamily: HerdrFonts.mono,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Deliberately small. A mirrored pane is a thumbnail — the point is the
  /// arrangement, and text at this size is legible enough to tell a sidebar from
  /// a log. Tapping opens the pane at a size you can actually read.
  static const _paneFontSize = 9.0;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.ground.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(Radii.uniform),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          child: Text(
            text,
            style: TextStyle(color: colors.textDim, fontSize: TextSize.meta),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.body,
    required this.colors,
    required this.l10n,
    required this.onRetry,
  });

  final String title;
  final String body;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: TextSize.strong,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: Space.lg),
              CupertinoButton(
                color: colors.text,
                borderRadius: BorderRadius.circular(Radii.uniform),
                onPressed: onRetry,
                child: Text(
                  l10n.actionRefresh,
                  style: TextStyle(color: colors.ground),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Drives repaints after the terminal model changes.
///
/// xterm's `Terminal` is an `Observable`, not a Flutter `Listenable`, so it
/// cannot be handed to `CustomPainter.repaint` directly.
class _Repaint extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// The panes of a tab that the layout did not place.
///
/// Exposed because a pane that exists but has no rectangle would otherwise be
/// invisible in the one view that claims to show everything — and "invisible in
/// the overview" is the worst place for it to be.
List<PaneInfo> unplacedPanes({
  required TabLayout layout,
  required List<PaneInfo> tabPanes,
}) {
  final placed = {for (final p in layout.panes) p.paneId};
  return [
    for (final pane in tabPanes)
      if (!placed.contains(pane.paneId)) pane,
  ];
}
