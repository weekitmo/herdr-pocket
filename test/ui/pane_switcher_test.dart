import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/pane_switcher.dart';

/// Tests for the pane picker.
///
/// The interesting behaviour is not that it draws: it is WHICH panes it offers
/// and what it hands back. Getting that wrong means tapping another agent's
/// name and being attached to a different one, which is the kind of mistake the
/// user cannot see coming.
void main() {
  PaneInfo pane(String id, {required String tab, String? title, String agent = ''}) =>
      PaneInfo.fromJson({
        'pane_id': id,
        'workspace_id': id.split(':').first,
        'tab_id': tab,
        'agent': agent,
        if (title != null) 'title': title,
      });

  final tree = WorkspaceTree.join(
    workspaces: [
      WorkspaceInfo.fromJson({
        'workspace_id': 'w9',
        'number': 1,
        'label': 'project',
        'tab_count': 2,
        'pane_count': 3,
      }),
    ],
    tabs: [
      TabInfo.fromJson({'tab_id': 'w9:t1', 'workspace_id': 'w9', 'number': 1, 'label': 'tab 1'}),
      TabInfo.fromJson({'tab_id': 'w9:t3', 'workspace_id': 'w9', 'number': 3, 'label': 'tab 3'}),
    ],
    panes: [
      pane('w9:p1', tab: 'w9:t1', title: '主终端', agent: 'pi'),
      pane('w9:p3', tab: 'w9:t1', title: '另一个', agent: 'claude'),
      pane('w9:p6', tab: 'w9:t3', title: '第三个标签页'),
    ],
  );

  Future<PaneInfo?> open(WidgetTester tester, String paneId) async {
    PaneInfo? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The sheet only reads the tree, so overriding the provider with a
          // ready-made one keeps this a test of the sheet rather than a test of
          // the socket.
          navTreeProvider.overrideWith(() => _FixedTree(tree)),
        ],
        child: HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => CupertinoPageScaffold(
                child: CupertinoButton(
                  onPressed: () async {
                    picked = await showPaneSwitcher(context, paneId: paneId);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('offers the panes sharing the tab, current one included',
      (tester) async {
    await open(tester, 'w9:p1');

    expect(find.text('主终端'), findsOneWidget);
    expect(find.text('另一个'), findsOneWidget);
    // The other tab's pane is offered too — switching tabs is the same gesture.
    expect(find.text('第三个标签页'), findsOneWidget);
  });

  testWidgets('returns the pane the user tapped', (tester) async {
    PaneInfo? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [navTreeProvider.overrideWith(() => _FixedTree(tree))],
        child: HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => CupertinoPageScaffold(
                child: CupertinoButton(
                  onPressed: () async {
                    picked = await showPaneSwitcher(context, paneId: 'w9:p1');
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('另一个'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.paneId, 'w9:p3');
  });

  testWidgets('the current pane is labelled, not re-selectable', (tester) async {
    PaneInfo? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [navTreeProvider.overrideWith(() => _FixedTree(tree))],
        child: HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => CupertinoPageScaffold(
                child: CupertinoButton(
                  onPressed: () async {
                    picked = await showPaneSwitcher(context, paneId: 'w9:p1');
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Re-picking the pane already on screen would tear down and rebuild a live
    // terminal for no change.
    await tester.tap(find.text('主终端'));
    await tester.pumpAndSettle();

    expect(picked, isNull);
  });
}

/// A tree that is already joined, so the sheet can be tested without a socket.
class _FixedTree extends NavTreeNotifier {
  _FixedTree(this._tree);

  final WorkspaceTree _tree;

  @override
  Future<WorkspaceTree> build() async => _tree;
}
