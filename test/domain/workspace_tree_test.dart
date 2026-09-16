import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';

/// Shapes here are trimmed copies of real `workspace.list` / `tab.list` /
/// `pane.list` output from a live herdr 0.9.0 (protocol 22), so the tests fail
/// if the daemon's field names are read differently than they arrive.
WorkspaceInfo _workspace(String id, int number, {bool focused = false}) =>
    WorkspaceInfo.fromJson({
      'workspace_id': id,
      'number': number,
      'label': 'project-$number',
      'focused': focused,
      'active_tab_id': '$id:t1',
      'tab_count': 1,
      'pane_count': 1,
    });

TabInfo _tab(String id, String workspaceId, int number, {bool focused = false}) =>
    TabInfo.fromJson({
      'tab_id': id,
      'workspace_id': workspaceId,
      'number': number,
      'label': 'tab $number',
      'focused': focused,
      'pane_count': 1,
    });

PaneInfo _pane(
  String id, {
  required String workspaceId,
  required String tabId,
  String agent = '',
  bool focused = false,
  String? title,
  String? cwd,
}) =>
    PaneInfo.fromJson({
      'pane_id': id,
      'workspace_id': workspaceId,
      'tab_id': tabId,
      'agent': agent,
      'agent_status': agent.isEmpty ? null : 'idle',
      'focused': focused,
      if (title != null) 'title': title,
      if (cwd != null) 'cwd': cwd,
    });

void main() {
  group('join', () {
    test('groups panes under their tab and tabs under their workspace', () {
      final tree = WorkspaceTree.join(
        workspaces: [_workspace('w9', 1, focused: true)],
        tabs: [_tab('w9:t1', 'w9', 1), _tab('w9:t3', 'w9', 3)],
        panes: [
          _pane('w9:p1', workspaceId: 'w9', tabId: 'w9:t1', agent: 'pi'),
          _pane('w9:p3', workspaceId: 'w9', tabId: 'w9:t3', agent: 'claude'),
          _pane('w9:p6', workspaceId: 'w9', tabId: 'w9:t3'),
        ],
      );

      expect(tree.workspaces, hasLength(1));
      final node = tree.workspaces.single;
      expect(node.tabs, hasLength(2));
      expect(node.tabs[0].panes.map((p) => p.paneId), ['w9:p1']);
      expect(node.tabs[1].panes.map((p) => p.paneId), ['w9:p3', 'w9:p6']);
      expect(node.paneCount, 3);
      expect(node.hasOrphans, isFalse);
    });

    test("orders workspaces and tabs by the daemon's own numbers", () {
      // The three lists arrive independently sorted, so the tree must not
      // inherit whatever order the requests happened to return.
      final tree = WorkspaceTree.join(
        workspaces: [_workspace('wC', 4), _workspace('w9', 1)],
        tabs: [_tab('w9:t5', 'w9', 5), _tab('w9:t1', 'w9', 1)],
        panes: const [],
      );

      expect(tree.workspaces.map((w) => w.workspace.workspaceId), ['w9', 'wC']);
      expect(tree.workspaces.first.tabs.map((t) => t.tab.number), [1, 5]);
    });

    test('keeps a pane whose tab has not appeared yet', () {
      // Three separate requests against a live daemon: a tab created between
      // the tab read and the pane read is visible in one and not the other.
      // Dropping this pane would make a running agent invisible.
      final tree = WorkspaceTree.join(
        workspaces: [_workspace('w9', 1)],
        tabs: [_tab('w9:t1', 'w9', 1)],
        panes: [
          _pane('w9:p1', workspaceId: 'w9', tabId: 'w9:t1'),
          _pane('w9:p9', workspaceId: 'w9', tabId: 'w9:t9', agent: 'codex'),
        ],
      );

      final node = tree.workspaces.single;
      expect(node.hasOrphans, isTrue);
      expect(node.orphanPanes.map((p) => p.paneId), ['w9:p9']);
      // Counted, because the user's question "how many panes does this have"
      // must not change depending on which read won the race.
      expect(node.paneCount, 2);
    });

    test('keeps a pane whose workspace has vanished', () {
      final tree = WorkspaceTree.join(
        workspaces: [_workspace('w9', 1)],
        tabs: [_tab('w9:t1', 'w9', 1)],
        panes: [
          _pane('w9:p1', workspaceId: 'w9', tabId: 'w9:t1'),
          _pane('wX:p1', workspaceId: 'wX', tabId: 'wX:t1', agent: 'grok'),
        ],
      );

      expect(tree.unplacedPanes.map((p) => p.paneId), ['wX:p1']);
      expect(tree.paneCount, 2);
      expect(tree.isEmpty, isFalse);
    });

    test('an empty reply is empty, not an error', () {
      final tree = WorkspaceTree.join(
        workspaces: const [],
        tabs: const [],
        panes: const [],
      );
      expect(tree.isEmpty, isTrue);
      expect(tree.paneCount, 0);
    });

    test('an empty tab is kept rather than filtered away', () {
      final tree = WorkspaceTree.join(
        workspaces: [_workspace('w9', 1)],
        tabs: [_tab('w9:t1', 'w9', 1)],
        panes: const [],
      );
      expect(tree.workspaces.single.tabs.single.isEmpty, isTrue);
    });
  });

  group('lookup', () {
    final tree = WorkspaceTree.join(
      workspaces: [_workspace('w9', 1), _workspace('wC', 4)],
      tabs: [_tab('w9:t1', 'w9', 1), _tab('wC:t1', 'wC', 1)],
      panes: [
        _pane('w9:p1', workspaceId: 'w9', tabId: 'w9:t1', focused: true),
        _pane('w9:p3', workspaceId: 'w9', tabId: 'w9:t1'),
        _pane('wC:p1', workspaceId: 'wC', tabId: 'wC:t1'),
      ],
    );

    test('siblings are the panes sharing a tab, current one included', () {
      expect(
        tree.siblingsOf('w9:p3').map((p) => p.paneId),
        ['w9:p1', 'w9:p3'],
      );
      expect(tree.siblingsOf('wC:p1').map((p) => p.paneId), ['wC:p1']);
    });

    test('workspace pane list crosses tabs but not workspaces', () {
      expect(
        tree.panesInWorkspaceOf('w9:p3').map((p) => p.paneId),
        ['w9:p1', 'w9:p3'],
      );
      expect(tree.panesInWorkspaceOf('nope'), isEmpty);
    });

    test('an unknown pane has no siblings rather than throwing', () {
      expect(tree.siblingsOf('wZ:p9'), isEmpty);
      expect(tree.paneById('wZ:p9'), isNull);
      expect(tree.tabOf('wZ:t9'), isNull);
    });

    test('paneById finds panes in every bucket', () {
      expect(tree.paneById('wC:p1')?.workspaceId, 'wC');
      expect(tree.paneById('w9:p1')?.isFocused, isTrue);
    });
  });

  group('pane status', () {
    test('the raw wire string is carried and mapped fail-closed', () {
      final pane = PaneInfo.fromJson({
        'pane_id': 'w9:p1',
        'workspace_id': 'w9',
        'tab_id': 'w9:t1',
        'agent': 'pi',
        'agent_status': 'waiting_approval',
      });

      // A status this build has never seen must reach the loud group, not the
      // quiet one. `waiting_approval` is exactly the kind of value a future
      // herdr would add, and the whole point is that it is not silently idle.
      expect(pane.agentStatus, 'waiting_approval');
      expect(pane.status, isA<AgentUnrecognised>());
      expect(pane.group, AgentGroup.unrecognised);
    });

    test('a plain shell is quiet, not an unrecognised-status alarm', () {
      // A live `pane.list` reports `agent_status: "unknown"` for EVERY plain
      // shell and sidebar pane — it is their normal value, not a failure to
      // read them. Running those through the board's fail-closed grouping put
      // the amber alarm on four rows out of six and would have buried the one
      // pane that really was unreadable.
      final pane = PaneInfo.fromJson({
        'pane_id': 'w9:p6',
        'workspace_id': 'w9',
        'tab_id': 'w9:t3',
        'agent_status': 'unknown',
      });
      expect(pane.isAgent, isFalse);
      expect(pane.status, isA<AgentIndefinite>());
      expect(pane.group, AgentGroup.idle);
    });

    test('an agent with an unreadable status is still loud', () {
      // The fail-closed rule survives where it belongs: a pane that DOES claim
      // to be an agent, in a state this build cannot interpret.
      final pane = PaneInfo.fromJson({
        'pane_id': 'w9:p1',
        'workspace_id': 'w9',
        'tab_id': 'w9:t1',
        'agent': 'pi',
        'agent_status': 'composing',
      });
      expect(pane.isAgent, isTrue);
      expect(pane.group, AgentGroup.unrecognised);
    });

    test('an agent with no status at all is loud too', () {
      final pane = PaneInfo.fromJson({
        'pane_id': 'w9:p1',
        'workspace_id': 'w9',
        'tab_id': 'w9:t1',
        'agent': 'codex',
      });
      expect(pane.group, AgentGroup.unrecognised);
    });

    test('display name prefers a typed title, then a label, then the folder', () {
      expect(
        _pane('p', workspaceId: 'w', tabId: 't', title: '晚间行情分析',
                cwd: '/x/y/z')
            .displayName,
        '晚间行情分析',
      );
      expect(
        PaneInfo.fromJson({
          'pane_id': 'p',
          'workspace_id': 'w',
          'tab_id': 't',
          'label': 'Sidebar',
          'cwd': '/x/y/z',
        }).displayName,
        'Sidebar',
      );
      expect(
        _pane('p', workspaceId: 'w', tabId: 't', cwd: '/x/y/z').displayName,
        'z',
      );
      // Last resort is machine noise, but it beats an empty row.
      expect(_pane('w9:p7', workspaceId: 'w9', tabId: 'w9:t1').displayName,
          'w9:p7');
    });

    test('a blank title does not win over a useful fallback', () {
      expect(
        _pane('p', workspaceId: 'w', tabId: 't', title: '   ', cwd: '/a/b')
            .displayName,
        'b',
      );
    });
  });
}
