/// The Jump To list: every place worth going, flat, ordered, and labelled with
/// what is happening there.
///
/// The workspaces page answers "what is the shape of my machine?" — a tree,
/// grouped by workspace and tab, which is the right answer to that question and
/// the wrong one to "take me to the agent that is waiting on me". That question
/// wants a FLAT list, ordered by urgency, with enough breadcrumb on each row to
/// recognise where it goes.
///
/// The ordering is not re-invented here: it comes from [AgentRow.group], the
/// same fail-closed ranking the board uses, so the two screens cannot disagree
/// about what needs attention.
library;

import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';

/// One row of the sheet: a pane, and whatever is in it.
///
/// The id and the label are EXPLICIT fields rather than read off [pane]. Two
/// paths build a target — one from the tree, one from an agent whose pane the
/// tree does not contain — and only one of them has a `PaneInfo`. Reading the
/// identity off the optional one produced targets with an empty id, which is a
/// row that opens nothing when tapped. The first version of this class did
/// exactly that, and its own test caught it.
class JumpTarget {
  const JumpTarget({
    required this.paneId,
    required this.paneLabel,
    required this.workspaceLabel,
    required this.tabLabel,
    this.pane,
    this.agent,
  });

  final String paneId;

  /// The pane's own name, used when there is no agent to name the row.
  final String paneLabel;

  final String workspaceLabel;
  final String tabLabel;

  /// The pane, when the tree knew about it.
  final PaneInfo? pane;

  /// Null for a pane with no detected agent — a shell, a scratch pane, a place
  /// to put something new.
  final AgentRow? agent;

  /// Urgency, or null when nothing is running there.
  AgentGroup? get group => agent?.group;

  String get title => agent?.title ?? paneLabel;

  /// `workspace › tab`, so a row is recognisable without opening it.
  String get breadcrumb => '$workspaceLabel › $tabLabel';
}

/// Every pane on the machine, ordered by how much it wants you.
class JumpList {
  const JumpList._(this.targets, this.sections);

  /// Builds from the two things the app already reads.
  ///
  /// [tree] supplies the structure and the labels; [agents] supplies the
  /// urgency. They are joined by PANE ID, and a pane with no matching agent is
  /// kept rather than dropped — an empty shell is a legitimate place to go, and
  /// a list that silently omits half the panes is a list that looks broken.
  factory JumpList.join({
    required WorkspaceTree tree,
    required AgentList agents,
  }) {
    final byPane = <String, AgentRow>{
      for (final row in agents.rows) row.info.paneId: row,
    };

    final targets = <JumpTarget>[];
    final orphans = <JumpTarget>[];
    for (final node in tree.workspaces) {
      final workspaceLabel = _labelOf(node.workspace.label, node.workspace.workspaceId);
      for (final tab in node.tabs) {
        final tabLabel = _labelOf(tab.tab.label, tab.tab.tabId);
        for (final pane in tab.panes) {
          targets.add(
            JumpTarget(
              paneId: pane.paneId,
              paneLabel: pane.displayName,
              pane: pane,
              workspaceLabel: workspaceLabel,
              tabLabel: tabLabel,
              agent: byPane[pane.paneId],
            ),
          );
        }
      }
      // A pane that claims this workspace but a tab the tab list did not
      // mention. Real, and frequent: these are three separate requests against
      // a live daemon, so a tab created in between is visible in one and not
      // another. Dropping it would hide an agent that is running RIGHT NOW.
      for (final pane in node.orphanPanes) {
        orphans.add(
          JumpTarget(
            paneId: pane.paneId,
            paneLabel: pane.displayName,
            pane: pane,
            workspaceLabel: workspaceLabel,
            tabLabel: _labelOf(pane.tabId, '—'),
            agent: byPane[pane.paneId],
          ),
        );
      }
    }

    // Panes herdr listed but the tree could not place, and any agent whose pane
    // the tree does not contain at all.
    final seen = targets.map((t) => t.paneId).toSet();
    for (final orphan in orphans) {
      if (seen.add(orphan.paneId)) targets.add(orphan);
    }
    for (final row in agents.rows) {
      if (seen.add(row.info.paneId)) {
        targets.add(
          JumpTarget(
            paneId: row.info.paneId,
            paneLabel: row.info.terminalTitle ?? row.info.paneId,
            workspaceLabel: row.info.workspaceId ?? '—',
            tabLabel: row.info.tabId ?? '—',
            agent: row,
          ),
        );
      }
    }

    targets.sort(_byUrgency);

    final grouped = <({AgentGroup? group, List<JumpTarget> rows})>[];
    for (final group in _urgencyOrder) {
      final rows = targets.where((t) => t.group == group).toList(growable: false);
      if (rows.isNotEmpty) grouped.add((group: group, rows: rows));
    }

    return JumpList._(List.unmodifiable(targets), List.unmodifiable(grouped));
  }

  factory JumpList.empty() => const JumpList._([], []);

  /// Every target, in display order.
  final List<JumpTarget> targets;

  /// The same targets, grouped and in section order. Empty groups are absent.
  final List<({AgentGroup? group, List<JumpTarget> rows})> sections;

  bool get isEmpty => targets.isEmpty;

  /// How many rows want a human — the number the sheet's title is about.
  int get needsYouCount =>
      targets.where((t) => t.group == AgentGroup.needsYou).length;

  /// How many places are waiting per workspace, for a section label.
  Map<String, int> get waitingByWorkspace {
    final counts = <String, int>{};
    for (final t in targets) {
      if (t.group != AgentGroup.needsYou) continue;
      counts.update(t.workspaceLabel, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// The section order, and the reason it is this order.
  ///
  /// `null` (a pane with nothing in it) sorts LAST, not first: it is not a
  /// thing that needs you, it is a place you might want. `unrecognised` keeps
  /// the fail-closed placement it has on the board — above working and idle,
  /// because "I cannot tell what this is" is nearer to *needs attention* than
  /// to *nothing to do*.
  static const _urgencyOrder = <AgentGroup?>[
    AgentGroup.needsYou,
    AgentGroup.stopped,
    AgentGroup.unrecognised,
    AgentGroup.working,
    AgentGroup.idle,
    null,
  ];

  static int _byUrgency(JumpTarget a, JumpTarget b) {
    final ra = _rankOf(a.group);
    final rb = _rankOf(b.group);
    if (ra != rb) return ra.compareTo(rb);
    // Stable and meaningful within a section: the board's own order, which is
    // most-recently-active first.
    return a.paneId.compareTo(b.paneId);
  }

  static int _rankOf(AgentGroup? group) {
    final index = _urgencyOrder.indexOf(group);
    return index == -1 ? _urgencyOrder.length : index;
  }
}

String _labelOf(String? label, String fallback) {
  final trimmed = label?.trim();
  return (trimmed == null || trimmed.isEmpty) ? fallback : trimmed;
}

/// Where a horizontal swipe should land.
///
/// Kept here rather than in the widget for the usual reason: this is a decision
/// (which tab is next, and what happens at the ends) and decisions are the part
/// worth testing. The widget only turns a gesture into a [delta].
///
/// Wraps around at both ends — a swipe that does nothing because you are on the
/// last tab reads as a broken gesture, not as a boundary.
///
/// Returns null when there is nowhere to go: an unknown pane, or a workspace
/// with only one tab.
({String tabLabel, PaneInfo pane})? siblingTab(
  WorkspaceTree tree, {
  required String paneId,
  required int delta,
}) {
  if (delta == 0) return null;
  for (final node in tree.workspaces) {
    final index =
        node.tabs.indexWhere((t) => t.panes.any((p) => p.paneId == paneId));
    if (index < 0) continue;
    if (node.tabs.length < 2) return null;
    final next = node.tabs[(index + delta) % node.tabs.length];
    if (next.panes.isEmpty) return null;
    final pane = next.panes.first;
    if (pane.paneId == paneId) return null;
    return (tabLabel: _labelOf(next.tab.label, next.tab.tabId), pane: pane);
  }
  return null;
}

/// Where a two-finger swipe should land: the next or previous PANE in the same
/// tab.
///
/// The sibling of [siblingTab], and the difference between them is the whole
/// point of having a hierarchy in the gestures: one finger moves between TABS,
/// two move between the PANES of the tab you are already in. Wraps at both ends
/// for the same reason — a swipe that does nothing at the edge reads as broken.
({String paneLabel, PaneInfo pane})? siblingPane(
  WorkspaceTree tree, {
  required String paneId,
  required int delta,
}) {
  if (delta == 0) return null;
  for (final node in tree.workspaces) {
    for (final tab in node.tabs) {
      final index = tab.panes.indexWhere((p) => p.paneId == paneId);
      if (index < 0) continue;
      if (tab.panes.length < 2) return null;
      final next = tab.panes[(index + delta) % tab.panes.length];
      if (next.paneId == paneId) return null;
      return (paneLabel: next.displayName, pane: next);
    }
  }
  return null;
}
