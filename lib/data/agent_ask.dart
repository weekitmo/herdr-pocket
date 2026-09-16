import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/agent/agent_question.dart';
import 'package:herdr_pocket/domain/agent/agent_reply.dart';
import 'package:herdr_pocket/domain/agent/reply_guard.dart';

/// One loaded question, with the row it was read from.
class AgentAsk {
  const AgentAsk({required this.row, required this.question, this.truncated = false});

  /// The board row AS IT WAS when the screen was read.
  ///
  /// This snapshot is the whole point of the two-phase flow: it is what the
  /// re-read before sending is compared against.
  final AgentRow row;

  final AgentQuestion question;

  /// True when the daemon cut the buffer, i.e. the oldest part of what is on
  /// screen was not shown to us.
  final bool truncated;
}

/// What happened when we tried to answer.
sealed class AskOutcome {
  const AskOutcome();
}

/// The keys were handed to the daemon.
///
/// Deliberately NOT called "sent" in the UI: the daemon accepted the input, and
/// whether the agent acted on it is a separate fact the board reports on its
/// own refresh. A phone that claims success on its own behalf is the failure
/// mode this codebase keeps refusing.
final class AskAccepted extends AskOutcome {
  const AskAccepted();
}

/// We refused to send, and why.
final class AskRefused extends AskOutcome {
  const AskRefused(this.reason);

  final ReplyRefusal reason;
}

/// The re-read said the screen moved on.
final class AskStale extends AskOutcome {
  const AskStale(this.safety);

  final ReplySafety safety;
}

/// The daemon said no, or the link died.
final class AskFailed extends AskOutcome {
  const AskFailed({required this.code, required this.message});

  /// The daemon's own error code, e.g. `agent_blocked`, `timeout`. Empty when
  /// the failure was a transport one, which has no code.
  final String code;
  final String message;
}

/// Reads a question and answers it, safely.
///
/// The flow is Moshi's, and it is the right one: **re-read before you press
/// anything**. A phone screen can be a minute old, and a menu answered from a
/// stale reading is a menu answered wrong — the failure mode where being
/// helpful deletes a file.
class AskController {
  const AskController(this._client);

  final HerdrClient _client;

  /// How much of the buffer to ask for when reading a question.
  ///
  /// Measured against a live 0.9.0: without a limit the daemon returns the
  /// whole readable buffer (several thousand characters) and flags nothing;
  /// with one it returns the LAST n lines and sets `truncated`. A prompt is at
  /// the bottom, so the tail is the right part — and 40 lines is enough for a
  /// boxed question with its options, without shipping a wall of scrollback to
  /// a phone.
  static const readLines = 40;

  /// Reads the current screen for [row] and parses what it is asking.
  ///
  /// Throws only for transport/API failures; "this is not a question" is an
  /// [AgentQuestion] with [QuestionConfidence.none], not an exception — the
  /// caller shows the raw lines instead of an error.
  Future<AgentAsk> load(AgentRow row) async {
    final read = await _client.agentRead(
      target: row.info.paneId,
      lines: readLines,
    );
    return AgentAsk(
      row: row,
      question: parseAgentQuestion(read.lines),
      truncated: read.truncated,
    );
  }

  /// Answers with a typed piece of text.
  ///
  /// The route is decided from the ROW, never from a flag a caller passes:
  /// [`isPromptBlocked`] is computed here so a screen cannot be shown as
  /// answerable and then routed to a call the daemon will refuse.
  Future<AskOutcome> answerText({
    required AgentRow before,
    required String text,
  }) async {
    final plan = planTextReply(
      paneId: before.info.paneId,
      agentKind: before.info.agent,
      isAwaitingMenu: isPromptBlocked(
        inputPending: before.info.inputPending,
        status: before.status,
      ),
      text: text,
    );
    return switch (plan) {
      TextReplyRefused(:final reason) => AskRefused(reason),
      TextReplyReady(:final intent) =>
        await _send(before: before.info, intent: intent),
    };
  }

  /// Answers by pressing an option's keys.
  ///
  /// The option carries its own submit semantics — a menu digit acts on its
  /// own, an inline `(y/n)` needs the return — so this must not add one.
  Future<AskOutcome> answerOption({
    required AgentRow before,
    required AgentOption option,
  }) =>
      _send(
        before: before.info,
        intent: ReplyKeys(keysForOption(option)),
      );

  /// The two-phase send: re-read, judge, then act.
  Future<AskOutcome> _send({
    required AgentInfo before,
    required AgentReplyIntent intent,
  }) async {
    final ReplySafety safety;
    try {
      final rows = await _client.agentList();
      final census = await _client.livePaneIds();
      final after = rows.where((r) => r.paneId == before.paneId).firstOrNull;
      safety = judgeReplySafety(
        before: before,
        paneIsLive: census?.contains(before.paneId) ?? true,
        after: after,
      );
    } on Object catch (e) {
      return AskFailed(code: '', message: e.toString());
    }

    if (safety != ReplySafety.safe) return AskStale(safety);

    try {
      switch (intent) {
        case ReplySubmit(:final text):
          await _client.agentPrompt(target: before.paneId, text: text);
        case ReplyTypeOnly(:final text):
          await _client.paneSendText(paneId: before.paneId, text: text);
        case ReplyKeys(:final keys):
          await _client.agentSendKeys(target: before.paneId, keys: keys);
      }
      return const AskAccepted();
    } on HerdrApiException catch (e) {
      return AskFailed(code: e.code, message: e.message);
    } on Object catch (e) {
      return AskFailed(code: '', message: e.toString());
    }
  }
}
