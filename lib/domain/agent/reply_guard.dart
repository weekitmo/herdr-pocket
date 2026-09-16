/// Whether it is still safe to answer.
///
/// The single most dangerous thing this app can do is press a key based on a
/// screen someone read a minute ago. Moshi's own remote-approval flow documents
/// the same hazard and answers it the same way: re-capture first, then act.
/// This file is the decision half of that — pure, so it can be tested against
/// the race instead of being trusted.
library;

import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// The verdict on a re-read.
enum ReplySafety {
  /// Same pane, still waiting, no observed transition. Send.
  safe,

  /// The agent moved on since we read the screen. What we are about to press
  /// answers a question that may no longer be on screen.
  changed,

  /// It is no longer waiting on a human at all — someone (or something) already
  /// answered, or it resumed on its own. Sending now would type into whatever
  /// it is doing instead.
  noLongerWaiting,

  /// The pane is gone. Nothing to answer.
  gone,
}

/// Judges a re-read of [before] taken immediately before sending.
///
/// [after] is the fresh `agent.list` row for the same pane, or null when the
/// pane is no longer listed. [paneIsLive] is the census answer, kept separate
/// from [after] so "the pane is gone" and "the row vanished from the list" stay
/// distinguishable.
///
/// Note what this can and cannot conclude. `state_change_seq` counts agent
/// LIFECYCLE transitions, so an equal value does NOT prove nothing changed (a
/// live measurement held it constant across 13 distinct screens in 26 s). It is
/// used here only as a POSITIVE signal: a different value proves something
/// happened, and that alone is enough to stop. Assuming the converse would be
/// the exact kind of inference this codebase refuses elsewhere.
ReplySafety judgeReplySafety({
  required AgentInfo before,
  required bool paneIsLive,
  AgentInfo? after,
}) {
  if (!paneIsLive || after == null) return ReplySafety.gone;

  // A pane id can be reused after a move (`pane.move` assigns a new public id
  // and keeps the old one as an alias), so the identity is re-checked rather
  // than assumed from the fact that we asked about the same id.
  if (after.paneId != before.paneId) return ReplySafety.changed;

  if (_groupOf(after, isLive: true) != AgentGroup.needsYou) {
    return ReplySafety.noLongerWaiting;
  }

  final was = before.stateChangeSeq;
  final now = after.stateChangeSeq;
  if (was != null && now != null && was != now) return ReplySafety.changed;

  return ReplySafety.safe;
}

/// The grouping decision for one row, without building a whole board.
AgentGroup _groupOf(AgentInfo info, {required bool isLive}) => resolveAgentGroup((
      status: AgentStatus.fromWire(info.agentStatus),
      lastKnownStatus: AgentStatus.fromWire(info.lastKnownStatus),
      isLive: isLive,
      isAwaitingMenuInput: info.inputPending,
    ));
