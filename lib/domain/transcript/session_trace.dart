/// One agent session, as its own transcript describes it.
///
/// WHY THIS LIVES IN `domain/`: nothing here needs a Flutter binding, and the
/// parts that can be *wrong* — where a turn begins, which tool call a result
/// belongs to, whether a token count is known or merely zero — are exactly the
/// parts worth testing without a widget in the way.
///
/// WHY IT IS NOT THE CHAT VIEW. This is a trace of what happened, not a
/// conversation to reply to. It reads the agent's own file and never writes to
/// it; the terminal underneath is still the thing that drives the agent
/// (see `TODO.md` T1-1 for the chat view, which shares this model).
library;

/// What one model inference was billed for.
///
/// EVERY FIELD IS NULLABLE, and that is the point: an agent that reports
/// nothing must render as nothing, not as zero. A cache-read of `0` and an
/// unreported cache-read are different facts, and the screen has to be able to
/// tell them apart — the board's rule about context usage ("never draw a guessed
/// progress bar") applies here word for word.
class TokenUsage {
  const TokenUsage({
    this.input,
    this.output,
    this.cacheRead,
    this.cacheWrite,
    this.reasoning,
    this.total,
    this.cost,
    this.contextWindow,
  });

  final int? input;
  final int? output;
  final int? cacheRead;
  final int? cacheWrite;
  final int? reasoning;

  /// The agent's own total, when it reports one. Not computed here: a total we
  /// derived and a total it stated are different evidence.
  final int? total;

  /// Money, only when the agent itself put a non-zero number in the transcript.
  ///
  /// Zero is treated as "did not report" rather than "free": pi writes a cost
  /// object for every message and fills it with zeros when it has no pricing,
  /// so a faithful reading of that zero would print `$0.00` next to real work.
  final double? cost;

  /// The model's context window, when the agent states it — codex does.
  final int? contextWindow;

  /// True when there is nothing worth drawing.
  bool get isEmpty =>
      input == null &&
      output == null &&
      cacheRead == null &&
      cacheWrite == null &&
      reasoning == null &&
      total == null;

  /// Adds [other] to this, treating "not reported" as "nothing to add".
  ///
  /// Null plus a number is that number. Null plus null stays null, so a sum
  /// that knows nothing still knows nothing.
  TokenUsage merge(TokenUsage other) => TokenUsage(
    input: _add(input, other.input),
    output: _add(output, other.output),
    cacheRead: _add(cacheRead, other.cacheRead),
    cacheWrite: _add(cacheWrite, other.cacheWrite),
    reasoning: _add(reasoning, other.reasoning),
    total: _add(total, other.total),
    cost: _addDouble(cost, other.cost),
    // A window is a fact about the model, not a quantity: taking the larger of
    // the two would invent a window no model has, so the first one wins.
    contextWindow: contextWindow ?? other.contextWindow,
  );

  static int? _add(int? a, int? b) => (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);

  static double? _addDouble(double? a, double? b) =>
      (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);
}

/// One line of the transcript, as the trace draws it.
///
/// Sealed rather than "a message with optional fields": a tool call is not a
/// message with empty text, and making the compiler say so is what keeps the
/// screen from having to ask whether `text` means anything this time.
sealed class TraceItem {
  const TraceItem();
}

/// Something a human or the agent said.
class TraceText extends TraceItem {
  const TraceText(this.text);

  final String text;
}

/// A reasoning block.
///
/// Not every agent keeps these, and the ones that do sometimes store an empty
/// string where the text used to be (Claude Code keeps only a signature once
/// the block has been redacted). An empty [text] is therefore normal, and the
/// only correct thing to do with it is not draw it.
class TraceThinking extends TraceItem {
  const TraceThinking(this.text);

  final String text;
}

/// One tool invocation, with whatever the agent recorded about its outcome.
///
/// THE CALL AND ITS RESULT ARE ONE ITEM, because that is how a person reads a
/// transcript: "Bash — flutter test — 42s — failed". Two rows would make the
/// reader pair them up by eye, and the pairing is the thing we already know.
class TraceToolCall extends TraceItem {
  const TraceToolCall({
    required this.id,
    required this.name,
    this.arguments = '',
    this.duration,
    this.isError,
    this.result,
  });

  /// The agent's own id for this call, used to match the result back to it.
  final String id;

  final String name;

  /// The arguments exactly as the agent recorded them.
  ///
  /// Kept raw on purpose: codex stores a JSON *string* that may or may not
  /// decode, and pi stores an object that may be arbitrarily deep. The trace
  /// shows this text and never tries to be cleverer than the record.
  final String arguments;

  /// How long the call took, when a result was seen. Derived from the two
  /// timestamps the transcript already carries — that is a measurement, not an
  /// estimate, and it is null rather than zero when there is no result yet.
  final Duration? duration;

  /// Whether the agent reported a failure. Null means "no result was recorded",
  /// which is not the same as success.
  final bool? isError;

  /// The result's text, trimmed by the adapter to something a phone can hold.
  final String? result;

  /// True when the call never came back in this transcript.
  bool get isOpen => isError == null;
}

/// A line the adapter understood well enough to keep, but not well enough to
/// classify — codex's per-turn notes, or a text-bearing payload we do not model.
class TraceNote extends TraceItem {
  const TraceNote(this.text);

  final String text;
}

/// One user prompt and everything the agent did about it.
///
/// THE TOKEN FIGURE LIVES HERE, and nowhere else. A single inference can emit
/// several tool calls at once, so tokens cannot be attributed to one tool
/// without making a number up; the turn is the smallest unit the agents
/// actually bill. [usage] is the sum over the inferences in this turn — each of
/// which was reported exactly, so the sum is exact too.
class TraceTurn {
  const TraceTurn({
    required this.index,
    this.prompt,
    this.startedAt,
    this.usage,
    this.items = const [],
  });

  /// 1-based, as the screen numbers them.
  final int index;

  /// What the human asked for, when the transcript recorded it.
  final String? prompt;

  final DateTime? startedAt;

  final TokenUsage? usage;

  final List<TraceItem> items;

  /// Every tool call in this turn, in the order they were invoked.
  Iterable<TraceToolCall> get toolCalls => items.whereType<TraceToolCall>();
}

/// A whole session: the turns, plus what the agent said about itself.
class TraceSession {
  const TraceSession({
    required this.agentId,
    this.model,
    this.sessionId,
    this.turns = const [],
    this.skippedLines = 0,
    this.cwd,
    this.reportedUsage,
  });

  /// The agent that wrote this, as its adapter names it (`pi`, `codex`).
  final String agentId;

  final String? model;
  final String? sessionId;
  final String? cwd;
  final List<TraceTurn> turns;

  /// Lines that did not parse as JSON, or that the adapter could not read.
  ///
  /// Counted rather than hidden: a transcript that half-parsed is still worth
  /// reading, but the reader is told, because "12 of 340 lines unread" is a
  /// different claim from "this is the session".
  final int skippedLines;

  /// The thread total the agent itself reported, when it reports one.
  ///
  /// codex writes a cumulative `token_usage_record`; pi does not write anything
  /// comparable, which is why this is separate from the per-turn sum instead of
  /// replacing it. A stated total and a total we added up are different
  /// evidence, and the header says which one it is showing.
  final TokenUsage? reportedUsage;
}
