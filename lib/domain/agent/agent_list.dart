import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// One row of the status board, and the grouping decision for it.
///
/// Ported from `herdrup/Sources/HerdrKit/AgentList.swift` (Apache-2.0).
class AgentRow {
  AgentRow({required this.info, bool? isLive})
      : isLive = isLive ?? true,
        status = AgentStatus.fromWire(info.agentStatus) {
    group = resolveAgentGroup((
      status: status,
      lastKnownStatus: AgentStatus.fromWire(info.lastKnownStatus),
      isLive: this.isLive,
      isAwaitingMenuInput: info.inputPending,
    ));
  }

  final AgentInfo info;

  /// What this build is willing to say the agent is doing. Distinguishes three
  /// kinds of "I don't know" — see [AgentStatus].
  final AgentStatus status;

  /// Which section this row belongs in.
  late final AgentGroup group;

  /// Whether the pane still exists. A row for a pane herdr no longer lists is
  /// [AgentGroup.stopped] regardless of the last status it reported.
  final bool isLive;

  String get id => info.paneId;
  String get title => info.displayName;

  @override
  String toString() => 'AgentRow($id, $group, $status)';
}

/// The whole board's state, derived from one `agent.list` response.
///
/// Pure: no Flutter, no IO. This is deliberate — it makes the most
/// consequential logic in the app testable without a binding, and lets the
/// tests be written against herdrup's documented semantics rather than against
/// our own accident.
class AgentList {
  /// Builds the board from `agent.list` agents.
  ///
  /// [livePaneIds], when supplied, is the set of panes herdr still reports;
  /// anything absent from it is `stopped`. Passing null means "no pane census
  /// available", and every row is treated as live — the ONLY safe reading,
  /// since inferring death from missing evidence would mark every agent
  /// stopped the moment a census failed to arrive.
  AgentList._({
    required this.rows,
    required this.sections,
    required this.archived,
  });

  factory AgentList({required List<AgentInfo> agents, Set<String>? livePaneIds}) {
    final archivedInfos = agents.where((a) => a.isArchived).toList();
    final liveInfos = agents.where((a) => !a.isArchived).toList();

    final archived = archivedInfos
        .map((i) => AgentRow(info: i, isLive: false))
        .toList()
      ..sort(
        (a, b) => (b.info.archivedAt ?? '').compareTo(a.info.archivedAt ?? ''),
      );

    final rows = liveInfos
        .map(
          (i) => AgentRow(
            info: i,
            isLive: livePaneIds == null || livePaneIds.contains(i.paneId),
          ),
        )
        .toList();

    // Group order first (the screen's primary signal — "does anything need
    // me?"). WITHIN a group, most-recently-active first, using the server's
    // wall-clock `completed_unix_ms`. Agents with no completed turn yet sort
    // last. A tie on the wall clock falls back to the server's own
    // `state_change_seq`, and paneId is the final tiebreak — unique and stable
    // as the agent works — so the list only reshuffles when an agent is
    // genuinely more recent, never on an unchanged refresh where every
    // timestamp is equal.
    //
    // The `state_change_seq` step is new and deliberately a TIEBREAK: it counts
    // agent LIFECYCLE transitions rather than time, so using it as the primary
    // key would reorder a quiet group every time somebody's status flickered.
    // As a tiebreak it answers the question the wall clock cannot ("these two
    // finished in the same second — which one just moved?") without disturbing
    // the order the wall clock already got right.
    rows.sort((a, b) {
      if (a.group != b.group) return a.group.rank.compareTo(b.group.rank);
      final ta = a.info.lastCompletedTurnUnixMs;
      final tb = b.info.lastCompletedTurnUnixMs;
      if (ta != tb) {
        // Null sorts last; a missing timestamp is not "very recent".
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta);
      }
      final sa = a.info.stateChangeSeq;
      final sb = b.info.stateChangeSeq;
      if (sa != null && sb != null && sa != sb) return sb.compareTo(sa);
      return a.info.paneId.compareTo(b.info.paneId);
    });

    final frozenRows = List<AgentRow>.unmodifiable(rows);

    final sections = [
      for (final group in AgentGroup.values)
        if (rows.any((r) => r.group == group))
          (
            group: group,
            rows: List<AgentRow>.unmodifiable(
              rows.where((r) => r.group == group),
            ),
          ),
    ];

    return AgentList._(
      rows: frozenRows,
      sections: List.unmodifiable(sections),
      archived: List.unmodifiable(archived),
    );
  }

  /// Every live row, in final display order.
  final List<AgentRow> rows;

  /// Sections in fixed group order, each holding its rows. Empty groups are
  /// omitted; the screen renders no heading for a section with nothing in it.
  final List<({AgentGroup group, List<AgentRow> rows})> sections;

  /// Archived agents, kept OUT of the live status sections and out of [rows] /
  /// [needsYouCount] / [isQuiet] entirely — an archived agent needs nothing
  /// from you. Most-recently-archived first.
  final List<AgentRow> archived;

  /// What the top of the screen says. Counts the [AgentGroup.needsYou] GROUP,
  /// not the retained status: reading `status.isBlocked` directly would let a
  /// blocked agent whose pane has since vanished sort into `stopped` while
  /// still being counted, so the screen would simultaneously claim all-clear
  /// and one-waiting.
  int get needsYouCount => countOf(AgentGroup.needsYou);

  int get workingCount => countOf(AgentGroup.working);

  /// How many rows are in [group]. Zero is a real answer.
  int countOf(AgentGroup group) =>
      rows.where((r) => r.group == group).length;

  /// EVERY group in board order, with its count — empty ones included.
  ///
  /// The differ from [sections] deliberately, and the difference is the whole
  /// point: a section with no rows renders no heading (a heading over nothing
  /// is a dead end you can tap), while the summary has to list all five,
  /// because a group that is ABSENT from the summary cannot be told apart from
  /// a group with nothing in it. "Nothing is working" is a fact the reader
  /// should get from reading, not from noticing a missing word.
  List<({AgentGroup group, int count})> get groupCounts => [
        for (final group in AgentGroup.values)
          (group: group, count: countOf(group)),
      ];

  /// True when nothing is blocked AND nothing is unrecognised.
  ///
  /// The quiet state has to mean "I checked everything", so an uninterpretable
  /// agent must prevent it — otherwise the screen says all-clear while holding
  /// a row it could not read.
  bool get isQuiet =>
      !rows.any((r) => r.group == AgentGroup.needsYou || r.group == AgentGroup.unrecognised);

  /// The wording rule for "N need you", kept here so every surface that renders
  /// the count shares one rule instead of inventing its own.
  ///
  /// NOTE: herdrup's version also qualifies an *unconfirmed* portion, which
  /// exists because federated peers can go quiet and leave last-known values
  /// behind. We do not implement federation (ADR-012: official herdr only), so
  /// there is no unconfirmed state to qualify. If federation lands later this
  /// must grow the qualifier back rather than silently asserting a guess.
  String? get needsYouSummary {
    final total = needsYouCount;
    if (total == 0) return null;
    return '$total need you';
  }

  /// Rows in the order a compact surface (notification, lock-screen widget)
  /// should speak about them — which is NOT the list order.
  ///
  /// The board's order answers "what should I scroll to first", so a gone pane
  /// sorts high there on purpose. A headline answers "what is this session
  /// doing right now", where a freshly stopped pane must not outrank N working
  /// agents. Reusing one order for the other made a single surface contradict
  /// itself; this is the separate rule.
  AgentRow? get activityLead {
    int rank(AgentRow r) => switch (r.group) {
          AgentGroup.needsYou => 0,
          AgentGroup.unrecognised => 1,
          AgentGroup.working => 2,
          AgentGroup.idle => 3,
          AgentGroup.stopped => 4,
        };
    if (rows.isEmpty) return null;
    return rows.reduce((a, b) => rank(a) <= rank(b) ? a : b);
  }

  static AgentList empty() => AgentList(agents: const []);
}

/// Compact "time in current state" label for a board card badge.
///
/// Minutes under an hour, hours under a day, else days — never seconds, always
/// a few digits plus one letter (`5m` / `2h` / `3d`). Returns null when the
/// daemon reported no anchor (older server, or no transition yet) or the
/// timestamp is in the future (clock skew), so the card shows no badge rather
/// than a wrong one.
String? compactTimeInState(int? sinceUnixMs, int nowUnixMs) {
  if (sinceUnixMs == null) return null;
  if (nowUnixMs < sinceUnixMs) return null;
  final seconds = (nowUnixMs - sinceUnixMs) ~/ 1000;
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}d';
}
