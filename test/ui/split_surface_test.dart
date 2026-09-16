import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/workspace/pane_layout.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/layout_page.dart';

/// The size the surface is given in every test, so the expected pixel numbers
/// are a property of the fixture rather than of the test window.
const double _surfaceWidth = 768;
const double _surfaceHeight = 384;

/// The split view has to put each pane where the MACHINE put it.
///
/// The geometry itself is unit-tested in `test/domain/pane_layout_test.dart`.
/// What is checked here is the next hop: that those numbers actually reach the
/// screen. A view that computes a perfect rectangle and then positions every
/// pane at the origin looks like a working split view containing one terminal,
/// which is precisely the kind of bug that survives a screenshot.
void main() {
  /// Real `pane.layout` output from a live herdr 0.9.0: a 192x48 tab split
  /// 47/49/96, with a nested split in the left half.
  TabLayout threePaneTab() => TabLayout.fromJson({
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

  /// Pumps the surface at a size the assertions can predict.
  ///
  /// The surface has no intrinsic size — it fills whatever it is given — so the
  /// test gives it one rather than inheriting the 800x600 test window, which
  /// would make the expected numbers depend on the harness.
  Future<void> pumpSurface(WidgetTester tester, TabLayout layout) async {
    await tester.pumpWidget(
      HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: _surfaceWidth,
                height: _surfaceHeight,
                child: Builder(
                  builder: (context) => PaneSplitSurface(
                    layout: layout,
                    l10n: AppLocalizations.of(context),
                    paneBuilder: (paneId, box) =>
                        const ColoredBox(color: Color(0xFF000000)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every pane is positioned at its own rectangle', (tester) async {
    final layout = threePaneTab();
    await pumpSurface(tester, layout);

    const sx = _surfaceWidth / 192;
    const sy = _surfaceHeight / 48;
    // `getRect` answers in GLOBAL coordinates, and the surface is centred in
    // the test window — so the origin has to come off before the numbers can be
    // compared against the daemon's own geometry.
    final origin = tester.getTopLeft(find.byType(PaneSplitSurface));

    for (final pane in layout.panes) {
      final finder = find.byKey(ValueKey<String>('pane-box-${pane.paneId}'));
      expect(finder, findsOneWidget, reason: '${pane.paneId} was not placed');

      final rect = tester.getRect(finder);
      expect(rect.left - origin.dx, closeTo(pane.rect.x * sx, 0.01));
      expect(rect.top - origin.dy, closeTo(pane.rect.y * sy, 0.01));
      expect(rect.width, closeTo(pane.rect.width * sx, 0.01));
      expect(rect.height, closeTo(pane.rect.height * sy, 0.01));
    }
  });

  testWidgets('the panes tile the tab with no gap and no overlap',
      (tester) async {
    await pumpSurface(tester, threePaneTab());

    final left = tester.getRect(find.byKey(const ValueKey('pane-box-wC:p5')));
    final middle = tester.getRect(find.byKey(const ValueKey('pane-box-wC:p1')));
    final right = tester.getRect(find.byKey(const ValueKey('pane-box-wC:p4')));

    // Exact adjacency, because the arrangement claims to be a partition. A gap
    // would be a seam nobody drew; an overlap would clip a neighbour.
    expect(left.right, closeTo(middle.left, 0.01));
    expect(middle.right, closeTo(right.left, 0.01));
    // And the widest pane really is twice the narrowest, not rounded to even.
    expect(right.width / left.width, closeTo(96 / 47, 0.01));
  });

  testWidgets('a stacked split puts panes one above the other', (tester) async {
    final layout = TabLayout.fromJson({
      'area': {'x': 0, 'y': 0, 'width': 100, 'height': 50},
      'panes': [
        {
          'pane_id': 'top',
          'focused': true,
          'rect': {'x': 0, 'y': 0, 'width': 100, 'height': 20},
        },
        {
          'pane_id': 'bottom',
          'rect': {'x': 0, 'y': 20, 'width': 100, 'height': 30},
        },
      ],
      'splits': [
        {
          'direction': 'down',
          'rect': {'x': 0, 'y': 0, 'width': 100, 'height': 50},
        },
      ],
    });
    await pumpSurface(tester, layout);

    final top = tester.getRect(find.byKey(const ValueKey('pane-box-top')));
    final bottom = tester.getRect(find.byKey(const ValueKey('pane-box-bottom')));
    expect(top.left, bottom.left);
    expect(top.width, bottom.width);
    expect(top.bottom, closeTo(bottom.top, 0.01));
    expect(bottom.height / top.height, closeTo(30 / 20, 0.01));
  });

  testWidgets('tapping a pane reports the pane that was tapped',
      (tester) async {
    // Getting this wrong means tapping one agent and opening another, which is
    // the kind of mistake the user cannot see coming.
    String? opened;
    await tester.pumpWidget(
      HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: _surfaceWidth,
                height: _surfaceHeight,
                child: Builder(
                  builder: (context) => PaneSplitSurface(
                    layout: threePaneTab(),
                    l10n: AppLocalizations.of(context),
                    paneBuilder: (paneId, box) => const SizedBox.expand(),
                    onOpenPane: (paneId) => opened = paneId,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pane-box-wC:p4')));
    await tester.pumpAndSettle();
    expect(opened, 'wC:p4');
  });

  testWidgets('a degenerate pane rectangle is not drawn', (tester) async {
    final layout = TabLayout.fromJson({
      'area': {'x': 0, 'y': 0, 'width': 100, 'height': 50},
      'panes': [
        {
          'pane_id': 'real',
          'rect': {'x': 0, 'y': 0, 'width': 100, 'height': 50},
        },
        {
          'pane_id': 'sliver',
          'rect': {'x': 0, 'y': 0, 'width': 0, 'height': 0},
        },
      ],
    });
    await pumpSurface(tester, layout);

    expect(find.byKey(const ValueKey('pane-box-real')), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-box-sliver')), findsNothing);
  });
}
