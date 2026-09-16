import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/jump_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The sheet that answers "take me to the agent that is waiting on me".
///
/// The order is the point, and it must be the BOARD's order — a second opinion
/// here would mean two screens disagreeing about what needs attention.

class _FixedTree extends NavTreeNotifier {
  _FixedTree(this._tree);

  final WorkspaceTree _tree;

  @override
  Future<WorkspaceTree> build() async => _tree;
}

class _FixedBoard extends BoardNotifier {
  _FixedBoard(this._agents);

  final List<AgentInfo> _agents;

  @override
  Future<AgentList> build() async => AgentList(agents: _agents);

  @override
  Future<void> refresh() async {}
}

AgentInfo _agent({
  required String paneId,
  required String status,
  String? title,
  String workspace = 'w1',
  String tab = 'w1:t1',
}) =>
    AgentInfo.fromJson({
      'pane_id': paneId,
      'agent': 'claude',
      'agent_status': status,
      'workspace_id': workspace,
      'tab_id': tab,
      if (title != null) 'title': title,
    });

WorkspaceTree _tree() => WorkspaceTree.join(
      workspaces: [
        WorkspaceInfo.fromJson(
          const {'workspace_id': 'w1', 'label': 'repo', 'number': 1},
        ),
      ],
      tabs: [
        TabInfo.fromJson(
          const {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'Agent', 'number': 1},
        ),
      ],
      panes: [
        PaneInfo.fromJson(
          const {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        ),
        PaneInfo.fromJson(
          const {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        ),
      ],
    );

Widget _host(List<AgentInfo> agents, {WorkspaceTree? tree}) => ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        navTreeProvider.overrideWith(() => _FixedTree(tree ?? _tree())),
        boardProvider.overrideWith(() => _FixedBoard(agents)),
        // No connection: the sheet reads the tree and the board, and tapping a
        // row without a client still opens the terminal.
        connectionProvider.overrideWith(_OfflineConnection.new),
      ],
      child: const HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: _Opener(),
        ),
      ),
    );

class _OfflineConnection extends ConnectionNotifier {
  @override
  Future<ConnectionStatus> build() async => const Disconnected();
}

/// Opens the sheet once, so the test can assert on what it rendered.
class _Opener extends StatefulWidget {
  const _Opener();

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showJumpSheet(context));
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// The injected settings store.
///
/// `main()` awaits `SharedPreferences.getInstance()` before `runApp` and
/// injects it, and `SettingsNotifier` reads it while building — so any widget
/// tree containing a page that reads settings needs one here too.
late SharedPreferences _prefs;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('lists every pane, most urgent first', (tester) async {
    await tester.pumpWidget(
      _host([
        _agent(paneId: 'w1:p1', status: 'idle', title: 'quiet one'),
        _agent(paneId: 'w1:p2', status: 'blocked', title: 'stuck one'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('stuck one'), findsOneWidget);
    expect(find.text('quiet one'), findsOneWidget);

    // The blocked one is above the idle one. Comparing positions rather than
    // document order, because that is what the user sees.
    final stuck = tester.getTopLeft(find.text('stuck one')).dy;
    final quiet = tester.getTopLeft(find.text('quiet one')).dy;
    expect(stuck, lessThan(quiet));
  });

  testWidgets('heads the sheet with how many are waiting', (tester) async {
    await tester.pumpWidget(
      _host([
        _agent(paneId: 'w1:p1', status: 'blocked', title: 'a'),
        _agent(paneId: 'w1:p2', status: 'blocked', title: 'b'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('2'), findsWidgets);
  });

  testWidgets('each row says where it goes', (tester) async {
    await tester.pumpWidget(
      _host([_agent(paneId: 'w1:p1', status: 'working', title: 'worker')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('repo › Agent'), findsWidgets);
  });

  testWidgets('an empty machine says so instead of showing a blank sheet',
      (tester) async {
    await tester.pumpWidget(
      _host(
        const [],
        tree: WorkspaceTree.join(
          workspaces: const <WorkspaceInfo>[],
          tabs: const <TabInfo>[],
          panes: const <PaneInfo>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('no panes'), findsOneWidget);
  });

  testWidgets('a pane with nothing in it is still reachable', (tester) async {
    // Only p1 has an agent; p2 is an empty shell and must still be listed —
    // a list that omits it is a list that looks broken.
    await tester.pumpWidget(
      _host([_agent(paneId: 'w1:p1', status: 'idle', title: 'a')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('w1:p2'), findsOneWidget);
  });

  testWidgets('tapping a row closes the sheet', (tester) async {
    await tester.pumpWidget(
      _host([_agent(paneId: 'w1:p1', status: 'blocked', title: 'stuck one')]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('stuck one'));
    await tester.pumpAndSettle();

    // The terminal it opens has no session here, but the SHEET is gone — which
    // is the part this test is about.
    expect(find.text('Jump to'), findsNothing);
  });
}
