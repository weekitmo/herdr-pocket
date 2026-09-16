import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/workspace/jump_target.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';

/// Flattening the session into one ordered list.
///
/// Two properties matter, and both are about not losing things: nothing the
/// daemon reported may be dropped, and the urgency order must be the BOARD's
/// order rather than a second opinion.
void main() {
  AgentInfo agent({
    required String paneId,
    String? workspaceId = 'w1',
    String? tabId = 'w1:t1',
    String? status = 'idle',
    String? label,
  }) =>
      AgentInfo.fromJson({
        'pane_id': paneId,
        'agent': 'claude',
        'agent_status': status,
        'workspace_id': workspaceId,
        'tab_id': tabId,
        if (label != null) 'title': label,
      });

  WorkspaceTree tree({
    List<Map<String, Object?>> workspaces = const [
      {'workspace_id': 'w1', 'label': 'repo', 'number': 1},
    ],
    List<Map<String, Object?>> tabs = const [
      {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'Agent', 'number': 1},
    ],
    List<Map<String, Object?>> panes = const [
      {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
    ],
  }) =>
      WorkspaceTree.join(
        workspaces: workspaces.map(WorkspaceInfo.fromJson).toList(),
        tabs: tabs.map(TabInfo.fromJson).toList(),
        panes: panes.map(PaneInfo.fromJson).toList(),
      );

  test('every pane is a target, whether or not anything is running in it', () {
    // An empty shell is a legitimate place to go. A list that omitted it would
    // be a list that looks broken.
    final list = JumpList.join(
      tree: tree(panes: const [
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      ]),
      agents: AgentList(
        agents: [
          agent(paneId: 'w1:p1', status: 'working'),
        ],
      ),
    );

    expect(list.targets.length, 2);
    expect(list.targets.map((t) => t.paneId), contains('w1:p2'));
  });

  test('a pane with no agent sorts LAST', () {
    // It is not something that needs you; it is a place you might want.
    final list = JumpList.join(
      tree: tree(panes: const [
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      ]),
      agents: AgentList(
        agents: [agent(paneId: 'w1:p2', status: 'idle')],
      ),
    );

    // The agent is in p2, so p2 is the one with urgency and p1 is the place.
    expect(list.targets.first.paneId, 'w1:p2');
    expect(list.targets.first.group, isNotNull);
    expect(list.targets.last.paneId, 'w1:p1');
    expect(list.targets.last.group, isNull);
  });

  test('urgency order is the board order, unknown included', () {
    final list = JumpList.join(
      tree: tree(panes: const [
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p3', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p4', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p5', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      ]),
      agents: AgentList(
        agents: [
          agent(paneId: 'w1:p1', status: 'idle'),
          agent(paneId: 'w1:p2', status: 'working'),
          agent(paneId: 'w1:p3', status: 'blocked'),
          agent(paneId: 'w1:p4', status: 'gibberish_from_the_future'),
          agent(paneId: 'w1:p5', status: 'done'),
        ],
      ),
    );

    // needsYou, unrecognised (fail-closed: ABOVE working), working, then idle
    // with `done` folded into it — the same ranking the board uses.
    expect(
      list.targets.map((t) => t.paneId),
      ['w1:p3', 'w1:p4', 'w1:p2', 'w1:p1', 'w1:p5'],
    );
  });

  test('sections skip empty groups entirely', () {
    final list = JumpList.join(
      tree: tree(),
      agents: AgentList(
        agents: [agent(paneId: 'w1:p1', status: 'working')],
      ),
    );

    expect(list.sections.length, 1);
    expect(list.sections.single.group, AgentGroup.working);
  });

  test('an agent whose pane the tree does not know is still reachable', () {
    // `workspace.list`, `tab.list` and `pane.list` are three separate requests,
    // so a pane created in between is visible in one and not the others.
    // Dropping it would hide an agent that is running RIGHT NOW.
    final list = JumpList.join(
      tree: tree(),
      agents: AgentList(
        agents: [
          agent(paneId: 'w1:p1', status: 'idle'),
          agent(paneId: 'w7:p9', workspaceId: 'w7', tabId: 'w7:t2', status: 'blocked'),
        ],
      ),
    );

    expect(list.targets.length, 2);
    final extra = list.targets.firstWhere((t) => t.paneId == 'w7:p9');
    expect(extra.workspaceLabel, 'w7');
    expect(extra.tabLabel, 'w7:t2');
  });

  test('an orphan pane keeps its workspace label, not its raw id', () {
    final list = JumpList.join(
      // The pane claims w1 but its tab is missing from the tab list.
      tree: tree(
        tabs: const [],
        panes: const [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t9'},
        ],
      ),
      agents: AgentList(agents: const []),
    );

    expect(list.targets.single.workspaceLabel, 'repo');
    expect(list.targets.single.tabLabel, 'w1:t9');
  });

  test('the breadcrumb names where the row goes', () {
    final list = JumpList.join(
      tree: tree(),
      agents: AgentList(agents: [agent(paneId: 'w1:p1')]),
    );
    expect(list.targets.single.breadcrumb, 'repo › Agent');
  });

  test('counts are about attention, per workspace', () {
    final list = JumpList.join(
      tree: tree(workspaces: const [
        {'workspace_id': 'w1', 'label': 'repo', 'number': 1},
        {'workspace_id': 'w2', 'label': 'other', 'number': 2},
      ], tabs: const [
        {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'Agent', 'number': 1},
        {'tab_id': 'w2:t1', 'workspace_id': 'w2', 'label': 'Agent', 'number': 1},
      ], panes: const [
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w2:p1', 'workspace_id': 'w2', 'tab_id': 'w2:t1'},
      ]),
      agents: AgentList(
        agents: [
          agent(paneId: 'w1:p1', status: 'blocked'),
          agent(paneId: 'w1:p2', status: 'blocked'),
          agent(paneId: 'w2:p1', status: 'working'),
        ],
      ),
    );

    expect(list.needsYouCount, 2);
    expect(list.waitingByWorkspace, {'repo': 2});
  });

  test('within a section the order is stable, not reshuffled per build', () {
    final list = JumpList.join(
      tree: tree(panes: const [
        {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      ]),
      agents: AgentList(
        agents: [
          agent(paneId: 'w1:p1', status: 'working'),
          agent(paneId: 'w1:p2', status: 'working'),
        ],
      ),
    );

    // Two agents with identical inputs must come out in the same order every
    // time; a list that reshuffles on each refresh is a list you cannot tap.
    expect(list.targets.map((t) => t.paneId), ['w1:p1', 'w1:p2']);
  });

  group('siblingTab — where a horizontal swipe lands', () {
    final three = tree(tabs: const [
      {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'one', 'number': 1},
      {'tab_id': 'w1:t2', 'workspace_id': 'w1', 'label': 'two', 'number': 2},
      {'tab_id': 'w1:t3', 'workspace_id': 'w1', 'label': 'three', 'number': 3},
    ], panes: const [
      {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t2'},
      {'pane_id': 'w1:p3', 'workspace_id': 'w1', 'tab_id': 'w1:t3'},
    ]);

    test('forward and back', () {
      expect(siblingTab(three, paneId: 'w1:p1', delta: 1)?.tabLabel, 'two');
      expect(siblingTab(three, paneId: 'w1:p2', delta: -1)?.tabLabel, 'one');
    });

    test('wraps around at both ends', () {
      // A swipe that does nothing because you are on the last tab reads as a
      // broken gesture rather than as a boundary.
      expect(siblingTab(three, paneId: 'w1:p3', delta: 1)?.tabLabel, 'one');
      expect(siblingTab(three, paneId: 'w1:p1', delta: -1)?.tabLabel, 'three');
    });

    test('one tab means nowhere to go', () {
      expect(siblingTab(tree(), paneId: 'w1:p1', delta: 1), isNull);
    });

    test('an unknown pane is not a navigation', () {
      expect(siblingTab(three, paneId: 'nope', delta: 1), isNull);
    });

    test('a zero delta does nothing at all', () {
      expect(siblingTab(three, paneId: 'w1:p1', delta: 0), isNull);
    });

    test('an empty target tab is skipped rather than opened', () {
      final ragged = tree(tabs: const [
        {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'one', 'number': 1},
        {'tab_id': 'w1:t2', 'workspace_id': 'w1', 'label': 'empty', 'number': 2},
      ], panes: const [
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      ]);
      expect(siblingTab(ragged, paneId: 'w1:p1', delta: 1), isNull);
    });
  });

  group('siblingPane — where a two-finger swipe lands', () {
    final split = tree(panes: const [
      {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
      {'pane_id': 'w1:p3', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
    ]);

    test('moves within the tab and wraps', () {
      expect(siblingPane(split, paneId: 'w1:p1', delta: 1)?.pane.paneId, 'w1:p2');
      expect(siblingPane(split, paneId: 'w1:p2', delta: -1)?.pane.paneId, 'w1:p1');
      expect(siblingPane(split, paneId: 'w1:p3', delta: 1)?.pane.paneId, 'w1:p1');
    });

    test('a lone pane in its tab has nowhere to go', () {
      expect(siblingPane(tree(), paneId: 'w1:p1', delta: 1), isNull);
    });

    test('it never crosses into another tab', () {
      // That is what the ONE finger is for. Two gestures with the same effect
      // would just be two ways to be surprised.
      final two = tree(tabs: const [
        {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'label': 'one', 'number': 1},
        {'tab_id': 'w1:t2', 'workspace_id': 'w1', 'label': 'two', 'number': 2},
      ], panes: const [
        {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t2'},
      ]);
      expect(siblingPane(two, paneId: 'w1:p1', delta: 1), isNull);
      expect(siblingTab(two, paneId: 'w1:p1', delta: 1)?.pane.paneId, 'w1:p2');
    });
  });

  test('an empty machine is an empty list, not a crash', () {
    final list = JumpList.join(
      tree: tree(workspaces: const [], tabs: const [], panes: const []),
      agents: AgentList(agents: const []),
    );
    expect(list.isEmpty, isTrue);
    expect(list.sections, isEmpty);
    expect(list.needsYouCount, 0);
  });
}
