import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';

/// An edge worth telling the user about.
class AgentAttention {
  const AgentAttention({
    required this.paneId,
    required this.title,
    required this.agent,
  });

  final String paneId;
  final String title;
  final String agent;

  @override
  String toString() => 'AgentAttention($paneId, $title)';
}

/// Turns a stream of board states into the handful of MOMENTS worth a
/// notification.
///
/// The whole job is edge detection, and getting it wrong is worse than not
/// having notifications at all: a rule that fires on state rather than on
/// transition sends one alert every refresh, and the user disables the feature
/// within a day. It is the same failure as a smoke alarm that beeps at toast.
///
/// Two rules make it quiet by construction:
///
///   1. **First sight is silent.** Opening the app while three agents are
///      already blocked must not produce three notifications — the user is
///      looking at the board, they can see it. Only a change observed DURING
///      this session counts.
///   2. **Only transitions into needing-you fire.** An agent that stays blocked
///      is still one agent needing one answer; re-announcing it every time the
///      board refreshes adds nothing and costs the feature its credibility.
///
/// Pure: no plugin, no storage, no clock. That is what makes the interaction
/// between those two rules testable, and it is the part that actually decides
/// whether this feature is good.
class AttentionTracker {
  final Map<String, AgentGroup> _lastKnown = {};

  /// True once the first observation has been absorbed.
  bool get isPrimed => _lastKnown.isNotEmpty || _primed;

  bool _primed = false;

  /// Feeds one board state and returns what to notify about.
  ///
  /// Returns an empty list on the first call, always — that call establishes
  /// what the world already looked like.
  List<AgentAttention> observe(AgentList board) {
    final fired = <AgentAttention>[];
    final seen = <String>{};

    for (final row in board.rows) {
      final paneId = row.info.paneId;
      seen.add(paneId);

      // Archive is not a transition the user needs to hear about, and a row
      // leaving the board is silence, not an alert.
      final previous = _lastKnown[paneId];
      _lastKnown[paneId] = row.group;

      if (!_primed) continue;
      if (row.group != AgentGroup.needsYou) continue;
      // No history for this pane means we cannot claim a transition happened.
      // The alternative reading — "it needs you and I do not know its past, so
      // alert" — re-fires every time the board briefly comes back empty, which
      // it does during a reconnect and whenever the pane census fails. Quiet
      // wins: the board already shows the agent, and an alert that repeats for
      // a reason the user cannot see is how the feature gets turned off.
      if (previous == null || previous == AgentGroup.needsYou) continue;

      fired.add(
        AgentAttention(
          paneId: paneId,
          title: row.title,
          agent: row.info.agent,
        ),
      );
    }

    // Forget panes that are gone, so a pane id reused later is treated as a
    // fresh arrival rather than inheriting a stale "already blocked" state.
    _lastKnown.removeWhere((paneId, _) => !seen.contains(paneId));

    _primed = true;
    return fired;
  }

  /// Forgets everything, so the next observation is silent again.
  ///
  /// Used when the board is torn down (a host switch, a reconnect). Without
  /// this, reconnecting to a machine where an agent is blocked would announce
  /// it as though it had just happened.
  void reset() {
    _lastKnown.clear();
    _primed = false;
  }
}
