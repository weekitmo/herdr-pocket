/// How a reply should reach the pane.
///
/// Ported in *semantics* (not code) from `herdrup/Sources/HerdrKit/InputIntent.swift`
/// (Apache-2.0). The design position there is "send intent, not keystrokes",
/// and it is right for the same reason on our side: `agent.prompt` is a
/// server-side primitive that understands bracketed paste, agent readiness and
/// completion, while typing bytes into a TUI is a race against the renderer.
///
/// It does not hold universally. A full-screen menu has no composer to submit
/// to, and `agent.prompt` is REJECTED outright while an agent is blocked
/// (`agent_blocked`, no bytes sent). So the mode is decided explicitly, never by
/// a single code path with a fallback.
library;

import 'package:herdr_pocket/domain/agent/agent_question.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// A reply that is ready to be sent.
sealed class AgentReplyIntent {
  const AgentReplyIntent();
}

/// Submit text as a prompt, the way the desktop composer would.
///
/// The only intent that can cause the agent to START working.
final class ReplySubmit extends AgentReplyIntent {
  const ReplySubmit(this.text);

  final String text;
}

/// Type text into the pane WITHOUT submitting it.
///
/// Used for a plain shell, and for an agent that is showing a menu — where
/// `agent.prompt` is refused but the menu's own free-text field still accepts
/// characters. Enter stays a separate, explicit action so that typing can never
/// execute anything by itself.
final class ReplyTypeOnly extends AgentReplyIntent {
  const ReplyTypeOnly(this.text);

  final String text;
}

/// Press keys: menu options, Enter, Escape.
final class ReplyKeys extends AgentReplyIntent {
  const ReplyKeys(this.keys);

  final List<String> keys;
}

/// Why a reply was not turned into an intent.
enum ReplyRefusal {
  /// Nothing to send. Refused rather than sent as an empty prompt, which some
  /// agents treat as a bare Enter — i.e. as confirming whatever is highlighted.
  empty,

  /// The text contains a newline and the target cannot submit.
  ///
  /// A newline reaching a pane's line discipline IS a submission; there is no
  /// way to type one and not run it. Refusing is the only honest option.
  multiline,

  /// No pane to send to.
  noTarget,
}

/// The outcome of deciding how to deliver typed text.
sealed class TextReplyPlan {
  const TextReplyPlan();
}

/// Send it, this way.
final class TextReplyReady extends TextReplyPlan {
  const TextReplyReady(this.intent);

  final AgentReplyIntent intent;
}

/// Do not send it, for this reason.
final class TextReplyRefused extends TextReplyPlan {
  const TextReplyRefused(this.reason);

  final ReplyRefusal reason;
}

/// Decides how [text] should reach the pane behind a row.
///
/// [agentKind] is empty for a pane with no detected agent (a plain shell), and
/// [isAwaitingMenu] mirrors `AgentRow`'s grouping predicate — the SAME signal,
/// so the board and the router cannot disagree about whether a menu is up
/// (the bug herdrup documents: gating on composer state instead sent replies
/// that were typed but never submitted).
///
/// Gating on a NAMED AGENT alone is deliberate. An earlier herdrup version also
/// required a live composer handle, which downgraded a real agent with a
/// transiently-null handle to raw keys — and the reply landed in the composer
/// without ever being submitted. "The agent never received it" is a worse bug
/// than "we typed instead of prompted".
TextReplyPlan planTextReply({
  required String paneId,
  required String agentKind,
  required bool isAwaitingMenu,
  required String text,
}) {
  if (paneId.trim().isEmpty) return const TextReplyRefused(ReplyRefusal.noTarget);
  if (text.trim().isEmpty) return const TextReplyRefused(ReplyRefusal.empty);

  if (agentKind.trim().isEmpty || isAwaitingMenu) {
    if (containsSubmitChar(text)) {
      return const TextReplyRefused(ReplyRefusal.multiline);
    }
    return TextReplyReady(ReplyTypeOnly(text));
  }

  return TextReplyReady(ReplySubmit(text));
}

/// Whether an agent is in a state where `agent.prompt` would be REFUSED.
///
/// Two signals, and the second one is not redundant:
///
/// 1. `input_pending` — the daemon saying "a menu is up". Absent on stock herdr
///    0.9.0, which is why it cannot be the only input.
/// 2. The status is literally `blocked`. herdr refuses `agent.prompt` with
///    `agent_blocked` and **sends no bytes at all**, so routing a blocked agent
///    to a prompt does not merely fail politely — it fails on the single most
///    important case this feature exists for, while looking implemented.
///
/// Everything typed then goes through the menu's own free-text field instead,
/// which the daemon does accept while blocked.
bool isPromptBlocked({
  required bool inputPending,
  required AgentStatus status,
}) =>
    inputPending || status is AgentBlocked;

/// Whether [text] would submit itself if typed into a pane.
///
/// Scans RUNES rather than characters: `"\r\n"` is a single grapheme cluster,
/// so a `characters`-based scan sees one unit and can miss the pair entirely.
bool containsSubmitChar(String text) =>
    text.runes.any((r) => r == 0x0A || r == 0x0D);

/// The keys that press [option].
///
/// A numbered menu acts on the digit; an inline `(y/n)` needs the letter AND a
/// return. Sending both in one call keeps them adjacent in the input stream —
/// two calls would let the daemon render something in between.
List<String> keysForOption(AgentOption option) =>
    option.needsEnter ? [option.key, 'enter'] : [option.key];
