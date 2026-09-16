/// What an agent is doing, as this client is willing to act on it.
///
/// Ported from `herdrup/Sources/HerdrKit/AgentList.swift` (Apache-2.0). The
/// *semantics* are the valuable part and are carried over exactly; the
/// expression here is Dart's.
///
/// herdr serialises its own status as `idle | working | blocked | done |
/// unknown`, and the field is OPTIONAL. That gives three genuinely different
/// ways of not knowing, and the whole point of this type is refusing to merge
/// them:
///
///   * [AgentAbsent]        the field was not sent at all. `agent.list` only
///                          ever returns agent terminals, so this means an
///                          older server or a gap — NOT "this is not an agent".
///   * [AgentIndefinite]    the server sent `"unknown"`. It looked and could
///                          not tell.
///   * [AgentUnrecognised]  the server sent something this build has never
///                          heard of.
///
/// The third is the one that matters. A future herdr adding, say,
/// `"waiting_approval"` would — under a `default: idle` mapping — sort an
/// agent that is blocked on a human into the QUIETEST group on the screen, and
/// nothing would ever report it. The bug would be invisible, permanent, and
/// would look exactly like the feature working.
///
/// So the raw string is CARRIED, not discarded. It costs one field and it is
/// the difference between a client that degrades and one that lies.
///
/// Sealed rather than an enum for one reason: it makes the switches in
/// [AgentGroup] exhaustive at compile time, so adding a case fails the build
/// instead of silently falling through to a guess.
sealed class AgentStatus {
  const AgentStatus();

  /// Maps a wire value. Deliberately has no fallback that collapses to a real
  /// state — an unmatched string becomes [AgentUnrecognised], never idle.
  factory AgentStatus.fromWire(String? wire) {
    if (wire == null) return const AgentAbsent();
    switch (wire) {
      case 'idle':
        return const AgentIdle();
      case 'working':
        return const AgentWorking();
      case 'blocked':
        return const AgentBlocked();
      case 'done':
        return const AgentDone();
      case 'unknown':
        return const AgentIndefinite();
      default:
        return AgentUnrecognised(wire);
    }
  }

  /// True only when herdr positively reports the agent is waiting on a human.
  ///
  /// NOT true for any of the unknown cases. Claiming an agent needs you when
  /// you do not know is a different lie from claiming it does not; grouping
  /// handles the rest.
  bool get isBlocked => this is AgentBlocked;
}

final class AgentIdle extends AgentStatus {
  const AgentIdle();
}

final class AgentWorking extends AgentStatus {
  const AgentWorking();
}

final class AgentBlocked extends AgentStatus {
  const AgentBlocked();
}

final class AgentDone extends AgentStatus {
  const AgentDone();
}

/// The server sent `"unknown"` — it looked and could not determine a state.
final class AgentIndefinite extends AgentStatus {
  const AgentIndefinite();
}

/// A value this build does not know. The payload is retained verbatim so it can
/// be surfaced and diagnosed rather than guessed at.
final class AgentUnrecognised extends AgentStatus {
  const AgentUnrecognised(this.raw);

  /// The exact string the server sent, unmodified.
  final String raw;

  @override
  bool operator ==(Object other) =>
      other is AgentUnrecognised && other.raw == raw;

  @override
  int get hashCode => Object.hash(AgentUnrecognised, raw);

  @override
  String toString() => 'AgentUnrecognised($raw)';
}

/// No `agent_status` field at all.
final class AgentAbsent extends AgentStatus {
  const AgentAbsent();
}
