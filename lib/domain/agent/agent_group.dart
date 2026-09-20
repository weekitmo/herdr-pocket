import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// Which section of the status board an agent belongs to.
///
/// Ported from `herdrup/Sources/HerdrKit/AgentList.swift` (Apache-2.0).
///
/// The ordering IS the screen's entire argument. The board exists to answer
/// "does anything need me?", so the answer sorts first and everything quiet
/// sorts last. [rank] is the sort key.
enum AgentGroup {
  /// herdr says this agent is waiting on a human.
  needsYou(0, 'needs you'),

  /// The pane is gone or the process exited.
  stopped(1, 'stopped'),

  /// THE FAIL-CLOSED PLACEMENT, and the reason this enum has an explicit rank.
  ///
  /// A status this build cannot interpret sorts ABOVE working and idle, not
  /// below them. "I do not know what this agent is doing" is nearer to *needs
  /// attention* than to *nothing to do*, and burying it is what would make a
  /// new upstream state permanently unobservable.
  ///
  /// Being wrong here is cheap — a stale row shown too prominently. Being wrong
  /// the other way is silent.
  unrecognised(2, 'unrecognised'),

  working(3, 'working'),

  idle(4, 'idle');

  AgentGroup(this.rank, this.label);

  /// Sort key. Lower sorts higher on screen.
  final int rank;

  /// Debug/test label. The UI localises from the enum instead of rendering
  /// this, because `toUpperCase()` is a no-op on Han characters and the
  /// English section-heading style does not transfer to zh-Hans (ADR-007).
  final String label;
}

// WHICH SECTIONS ARE OPEN IS NOT DECIDED HERE ANY MORE, and the two things that
// used to decide it are gone: `startsCollapsed` (idle and stopped closed by
// default) and `defaultExpandedGroup()` (exactly one section opened by
// preference — working, else approvals, else idle).
//
// The rule they encoded was not silly, only superseded, and the reason is worth
// keeping: the ranking above ALREADY puts what needs attention at the top, so
// the row that wants the user is never below the fold — "a fleet of idle agents
// buries the one that is stuck" describes a problem the order had solved. What
// was left was a guess about which ONE section the user came to see, and it is
// wrong the moment they wanted two.
//
// The default is now "everything open", and the only state is what the user has
// explicitly closed — remembered per machine. See
// `data/providers/board_sections.dart`, which is where that lives and where the
// reasoning for the set-of-closed-groups shape is written down.

/// Inputs the grouping decision depends on.
///
/// A record-ish parameter object so call sites cannot silently forget a signal
/// (herdrup learned this the hard way: a predicate scoped for one surface's
/// drawing decision was reused to answer another surface's question four times
/// in one PR's review history).
typedef GroupInputs = ({
  AgentStatus status,
  AgentStatus lastKnownStatus,
  bool isLive,
  bool isAwaitingMenuInput,
});

/// The grouping rule.
///
/// Two escalation-only overlays on top of the base switch. Nothing here may
/// ever move a row toward a QUIETER section, so the fail-closed placement the
/// rank encodes cannot be undone by a lenient field.
///
/// 1. `isAwaitingMenuInput` — an agent showing a plan-approval or
///    AskUserQuestion menu while its status is anything other than the literal
///    "blocked" could otherwise never reach [AgentGroup.needsYou]. The
///    predicate already gates input routing; this makes the BOARD agree with
///    the router instead of contradicting it.
///
/// 2. `lastKnownStatus == blocked` when the live status reads [AgentIndefinite]
///    — a federated peer that misses a single poll gets its status overwritten
///    with "unknown" and the real state moved to `last_known_status`, so every
///    agent on that machine would leave `working` and `needsYou` at once.
///    Reading the surviving copy for the blocked case only keeps a fleet agent
///    that is waiting on a human visible, without presenting any other stale
///    state as though it were live.
///
///    The [AgentIndefinite] precondition is load-bearing, not decoration: a
///    LIVE status is authoritative, and escalating on a known-idle row that
///    happens to carry a stale blocked value would resurrect a state the server
///    already replaced. A last-known `working` deliberately does NOT restore
///    the working group either — "this machine went quiet on us" is the louder,
///    truer thing to say.
AgentGroup resolveAgentGroup(GroupInputs input) {
  final base = _baseGroup(input.status, isLive: input.isLive);

  // A pane that is gone needs nothing from anybody: never escalate off
  // `stopped`.
  if (!input.isLive) return base;

  if (input.isAwaitingMenuInput) return AgentGroup.needsYou;

  if (input.status is AgentIndefinite && input.lastKnownStatus.isBlocked) {
    return AgentGroup.needsYou;
  }

  return base;
}

/// EXHAUSTIVE OVER [AgentStatus] ON PURPOSE — no `default:` arm.
///
/// Adding a case to [AgentStatus] must fail to compile HERE rather than fall
/// through to a guess. That compile error is the guard; a `default:` would
/// silently swallow exactly the class of change this whole file exists to
/// catch.
AgentGroup _baseGroup(AgentStatus status, {required bool isLive}) {
  if (!isLive) return AgentGroup.stopped;
  return switch (status) {
    AgentBlocked() => AgentGroup.needsYou,
    AgentWorking() => AgentGroup.working,
    AgentIdle() || AgentDone() => AgentGroup.idle,
    // All three of these mean "this client cannot say what is happening", and
    // all three surface rather than sink. They stay SEPARATE cases in
    // [AgentStatus] so a diagnostic can tell "the server could not tell" from
    // "this client is out of date" — different problems, different fixes — but
    // they group identically, because the user's situation is the same.
    //
    // `.absent` groups here too. An earlier version treated a missing status as
    // "not an agent pane", which was wrong: herdr only returns agent terminals
    // from `agent.list`, so an absent status means an older server or a gap,
    // never a non-agent.
    AgentIndefinite() || AgentUnrecognised() || AgentAbsent() =>
      AgentGroup.unrecognised,
  };
}
