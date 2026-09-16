import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_info.dart';

/// A tab and the panes inside it.
class TabNode {
  const TabNode({required this.tab, required this.panes});

  final TabInfo tab;
  final List<PaneInfo> panes;

  /// True when the daemon reported a tab but no panes under it.
  ///
  /// Kept rather than filtered out: an empty tab is a real thing a user can
  /// create, and a tree that hides it makes the app disagree with the machine.
  bool get isEmpty => panes.isEmpty;
}

/// A workspace and the tabs inside it.
class WorkspaceNode {
  const WorkspaceNode({
    required this.workspace,
    required this.tabs,
    required this.orphanPanes,
  });

  final WorkspaceInfo workspace;
  final List<TabNode> tabs;

  /// Panes that claim this workspace but a tab that is not in the tab list.
  ///
  /// This happens for real: the three lists are three separate requests against
  /// a live daemon, so a tab created between the tab read and the pane read is
  /// visible in one and not the other. Dropping such a pane would make an agent
  /// that is running RIGHT NOW invisible — the failure mode this whole project
  /// exists to avoid. So it is carried up and shown.
  final List<PaneInfo> orphanPanes;

  int get paneCount =>
      tabs.fold(0, (n, t) => n + t.panes.length) + orphanPanes.length;

  bool get hasOrphans => orphanPanes.isNotEmpty;
}

/// The workspace → tab → pane tree, joined.
///
/// The join is the interesting part, and it is deliberately forgiving in one
/// direction only: nothing that the daemon reported is ever dropped. Lists that
/// do not line up produce an explicitly-labelled bucket rather than a silent
/// omission, because a client that quietly loses a running agent is worse than
/// one that admits the machine and the app disagree.
class WorkspaceTree {
  const WorkspaceTree({
    required this.workspaces,
    required this.unplacedPanes,
  });

  /// Joins the three lists.
  ///
  /// [panes] is matched to workspaces and tabs by the ids the pane itself
  /// carries, NOT by index or by order — the lists are independently sorted and
  /// any positional assumption would scramble the tree the moment one of them
  /// changed length.
  factory WorkspaceTree.join({
    required List<WorkspaceInfo> workspaces,
    required List<TabInfo> tabs,
    required List<PaneInfo> panes,
  }) {
    final panesByTab = <String, List<PaneInfo>>{};
    final panesByWorkspace = <String, List<PaneInfo>>{};
    for (final pane in panes) {
      (panesByTab[pane.tabId] ??= <PaneInfo>[]).add(pane);
      (panesByWorkspace[pane.workspaceId] ??= <PaneInfo>[]).add(pane);
    }

    final tabsByWorkspace = <String, List<TabInfo>>{};
    final knownTabIds = <String>{};
    for (final tab in tabs) {
      (tabsByWorkspace[tab.workspaceId] ??= <TabInfo>[]).add(tab);
      knownTabIds.add(tab.tabId);
    }

    final knownWorkspaceIds = <String>{};
    final nodes = <WorkspaceNode>[];
    for (final workspace in workspaces) {
      knownWorkspaceIds.add(workspace.workspaceId);

      final ownTabs = [...?tabsByWorkspace[workspace.workspaceId]]
        ..sort((a, b) => a.number.compareTo(b.number));
      final tabNodes = <TabNode>[];
      final orphans = <PaneInfo>[];

      for (final tab in ownTabs) {
        final ownPanes = [...?panesByTab[tab.tabId]]
          ..sort(_byPaneIdThenFocus);
        tabNodes.add(TabNode(tab: tab, panes: ownPanes));
      }

      // A pane whose tab is missing from the tab list still belongs to this
      // workspace, and the workspace is what the user picks from. Filing it
      // under the workspace keeps it reachable.
      for (final pane in panesByWorkspace[workspace.workspaceId] ?? const <PaneInfo>[]) {
        if (!knownTabIds.contains(pane.tabId)) orphans.add(pane);
      }
      orphans.sort(_byPaneIdThenFocus);

      nodes.add(
        WorkspaceNode(
          workspace: workspace,
          tabs: tabNodes,
          orphanPanes: orphans,
        ),
      );
    }

    // Panes claiming a workspace that does not exist at all. Same reasoning as
    // the orphan tabs: shown, not swallowed.
    final unplaced = panes
        .where((p) => !knownWorkspaceIds.contains(p.workspaceId))
        .toList()
      ..sort(_byPaneIdThenFocus);

    nodes.sort((a, b) => a.workspace.number.compareTo(b.workspace.number));

    return WorkspaceTree(workspaces: nodes, unplacedPanes: unplaced);
  }

  factory WorkspaceTree.empty() =>
      const WorkspaceTree(workspaces: [], unplacedPanes: []);

  final List<WorkspaceNode> workspaces;
  final List<PaneInfo> unplacedPanes;

  bool get isEmpty => workspaces.isEmpty && unplacedPanes.isEmpty;

  int get paneCount =>
      workspaces.fold(0, (n, w) => n + w.paneCount) + unplacedPanes.length;

  /// The tab a pane lives in, if the tree knows about it.
  ///
  /// Used by the pane switcher to offer a pane's siblings: switching away from
  /// what you are looking at is almost always a move within one tab, so that
  /// list wants to be exact rather than roughly right.
  TabNode? tabOf(String tabId) {
    for (final workspace in workspaces) {
      for (final tab in workspace.tabs) {
        if (tab.tab.tabId == tabId) return tab;
      }
    }
    return null;
  }

  /// Every pane sharing a tab with [paneId], [paneId] included.
  List<PaneInfo> siblingsOf(String paneId) {
    for (final workspace in workspaces) {
      for (final tab in workspace.tabs) {
        if (tab.panes.any((p) => p.paneId == paneId)) return tab.panes;
      }
      if (workspace.orphanPanes.any((p) => p.paneId == paneId)) {
        return workspace.orphanPanes;
      }
    }
    if (unplacedPanes.any((p) => p.paneId == paneId)) return unplacedPanes;
    return const [];
  }

  /// Every pane in the workspace a pane belongs to.
  ///
  /// Empty when the pane is unknown, which the switcher shows as "only you".
  List<PaneInfo> panesInWorkspaceOf(String paneId) {
    for (final workspace in workspaces) {
      final all = [
        for (final tab in workspace.tabs) ...tab.panes,
        ...workspace.orphanPanes,
      ];
      if (all.any((p) => p.paneId == paneId)) return all;
    }
    return const [];
  }

  PaneInfo? paneById(String paneId) {
    for (final workspace in workspaces) {
      for (final tab in workspace.tabs) {
        for (final pane in tab.panes) {
          if (pane.paneId == paneId) return pane;
        }
      }
      for (final pane in workspace.orphanPanes) {
        if (pane.paneId == paneId) return pane;
      }
    }
    for (final pane in unplacedPanes) {
      if (pane.paneId == paneId) return pane;
    }
    return null;
  }

  /// Pane ids in the order the daemon names them, then by focus.
  ///
  /// `w9:p1` → 1. The ids are stable and short, so sorting by them gives the
  /// same order herdr's own UI uses far more often than any heuristic about
  /// titles would.
  static int _byPaneIdThenFocus(PaneInfo a, PaneInfo b) {
    if (a.isFocused != b.isFocused) return a.isFocused ? -1 : 1;
    final na = _paneNumber(a.paneId);
    final nb = _paneNumber(b.paneId);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    return a.paneId.compareTo(b.paneId);
  }

  /// The numeric tail of `w9:p12`. Null when the id is not that shape — the
  /// format is a daemon convention, not a promise, so it is parsed leniently.
  static int? _paneNumber(String paneId) {
    final at = paneId.lastIndexOf(':p');
    if (at < 0) return null;
    return int.tryParse(paneId.substring(at + 2));
  }
}
