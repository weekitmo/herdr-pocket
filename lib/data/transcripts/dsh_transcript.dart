/// Reading dsh's session files.
///
/// WHERE THEY LIVE: `~/.dsh/sessions/<cwd-slug>/<session-uuid>/session*.jsonl.zstd`
/// — one DIRECTORY per session, and the transcript is **zstd-compressed**.
/// That is the two things this adapter adds to the family: a locator that
/// descends one more level, and a read that decompresses.
///
/// WHAT THE FILE IS: an event log, `{type, seq, time, data}`, and — unlike the
/// other two — it names its own boundaries:
///
///   turn/start         {turn}                      a turn, numbered by the agent
///   step/start         {turn, step}                one model inference
///   user/message       {content, id, role, source}
///   assistant/message  {turn, step, message, usage}  usage is PER STEP
///   tool/call          {turn, step, callId, name, arguments}
///   tool/result        {turn, step, message}
///   step/end, turn/end {turn, step, reason}
///
/// So the trace gets to use the agent's own turn numbers instead of counting
/// the window it happens to have read — the one place in this feature where a
/// number on screen is the agent's rather than ours.
///
/// THE INLINE COPY IS IGNORED. An assistant message also carries `tool-call`
/// blocks in its content, duplicating the `tool/call` records; this adapter
/// reads the records, because they carry `callId` and arrive as their own
/// events, and takes only the text out of the message.
library;

import 'dart:convert';

import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/domain/transcript/session_trace.dart';

class DshTranscript implements TranscriptAdapter {
  const DshTranscript();

  @override
  String get agentId => 'dsh';

  @override
  bool get isCompressed => true;

  @override
  bool canParse(String firstLine) {
    final decoded = _decode(firstLine);
    if (decoded == null) return false;
    final type = stringOf(decoded['type']) ?? '';
    if (type.isEmpty) return false;
    // Slashed names (`tool/call`, `turn/start`) are dsh's own vocabulary and
    // always carry a `data` object. The `session` header does not, which is why
    // it is checked by its own fields: pi also opens with a `type: session`
    // line, and the two have to be told apart by something.
    if (type == 'session') return decoded['createdAt'] != null;
    return decoded['data'] != null && decoded['time'] != null;
  }

  @override
  String locateCommand(String cwd, DateTime now) {
    const root = r'$HOME/.dsh/sessions/';
    final dir = '"$root${dqShell(cwdSlug(cwd))}"';
    // Newest session directory (by the transcript inside it), then the
    // transcript. `ls -t` over the glob is enough: the sessions directory holds
    // one directory per session and nothing else worth mentioning.
    return 'ls -t $dir/*/session*.jsonl.zstd 2>/dev/null | head -5';
  }

  @override
  String readTailCommand(String path, int limit) {
    // The tail of the DECODED stream: a compressed file cannot be seeked to its
    // last N bytes. `zstd` is not on a non-login shell's PATH, so the same
    // guard the `lsof` probe uses applies — and when it is missing entirely the
    // page says it could not read the file rather than that none exists.
    const zstd = r'zstd="$(command -v zstd || echo /opt/homebrew/bin/zstd)"; '
        r'"$zstd" -d -c ';
    return '$zstd${quoteShell(path)} 2>/dev/null | tail -c $limit';
  }

  @override
  TranscriptParse parse(Iterable<String> lines) {
    final turns = <int, _TurnBuilder>{};
    final order = <int>[];
    final open = <String, _CallSite>{};
    TokenUsage? usage;
    String? cwd;
    String? sessionId;
    // 1-based index inside the window, for the turns the file did not number.
    var skipped = 0;
    var recognised = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final decoded = _decode(line);
      if (decoded == null) {
        skipped++;
        continue;
      }

      final type = stringOf(decoded['type']) ?? '';
      final data = mapOf(decoded['data']);
      final at = timeMsOf(decoded['time']) ?? timeMsOf(decoded['createdAt']);
      // EVERY record in the log counts as understood, not just the ones that
      // carry conversation. dsh opens a session directory every time it runs,
      // so a file with a header and nothing else is common — and calling that
      // "not a dsh file" would hide a session that genuinely has no turns yet.
      if (type == 'session' || type.contains('/')) recognised++;
      if (type == 'session') {
        cwd ??= stringOf(decoded['cwd']);
        sessionId ??= stringOf(decoded['id']);
        continue;
      }
      if (data == null) continue;

      final number = intOf(data['turn']);
      _TurnBuilder turn() {
        final key = number ?? order.length;
        final existing = turns[key];
        if (existing != null) return existing;
        order.add(key);
        return turns[key] = _TurnBuilder(number: key, at: at);
      }

      switch (type) {
        case 'turn/start':
        case 'step/start':
          turn();
          recognised++;
        case 'user/message':
          final text = textOfBlocks(data['content']);
          if (text.trim().isEmpty) break;
          final current = turn();
          current.prompt ??= text;
          recognised++;
        case 'assistant/message':
          final message = mapOf(data['message']);
          final current = turn();
          // A reasoning block is the agent THINKING, and dsh keeps its text in
          // plain sight — unlike codex, whose reasoning arrives as an encrypted
          // blob with a one-line summary. Dropping it would leave the trace
          // with the answer and no sign of how it got there.
          for (final block in listOf(message?['content'])) {
            final entry = mapOf(block);
            if (entry == null) continue;
            final blockType = stringOf(entry['type']);
            final blockText = stringOf(entry['text']) ?? '';
            if (blockText.trim().isEmpty) continue;
            switch (blockType) {
              case 'reasoning':
                current.items.add(TraceThinking(blockText));
              case 'text':
                current.items.add(TraceText(blockText));
              case _:
                // `tool-call` blocks repeat the `tool/call` records; reading
                // both would double every call in the table.
                break;
            }
          }
          final stepUsage = _usageOf(data['usage']);
          if (stepUsage != null) {
            current.usage = current.usage == null
                ? stepUsage
                : current.usage!.merge(stepUsage);
            usage = usage == null ? stepUsage : usage.merge(stepUsage);
          }
          recognised++;
        case 'tool/call':
          final id = stringOf(data['callId']) ?? '';
          final current = turn();
          current.items.add(
            TraceToolCall(
              id: id,
              name: stringOf(data['name']) ?? '?',
              arguments: stringOf(data['arguments']) ?? '',
            ),
          );
          open[id] = _CallSite(
            current,
            current.items.length - 1,
            at,
          );
          recognised++;
        case 'tool/result':
          final id = _callIdOf(data['message']);
          final site = open.remove(id);
          final text = _resultTextOf(data['message']);
          if (site == null) {
            final current = turn();
            if (text.isNotEmpty) current.items.add(TraceNote(text));
            break;
          }
          final started = site.startedAt;
          final duration = (started == null || at == null)
              ? null
              : at.difference(started);
          final previous = site.turn.items[site.index];
          if (previous is TraceToolCall) {
            site.turn.items[site.index] = TraceToolCall(
              id: previous.id,
              name: previous.name,
              arguments: previous.arguments,
              duration: duration != null && duration.isNegative ? null : duration,
              isError: _failedOf(data['message']),
              result: text.isEmpty ? null : text,
            );
          }
          recognised++;
        default:
          // `step/end`, `turn/end`, sandbox and approval records, and whatever
          // a later version adds. A log grows; an unknown record is not an
          // error.
          break;
      }
    }

    if (recognised == 0) {
      return const UnusableTranscript('no dsh session events');
    }

    return ParsedTranscript(
      TraceSession(
        agentId: agentId,
        sessionId: sessionId,
        cwd: cwd,
        // The agent's own turn number, not a count of what this window
        // happens to contain: dsh writes `turn/start {turn}` and every record
        // carries it, so a window that begins at turn 7 says 7.
        turns: [
          for (final key in order) turns[key]!.freeze(index: key),
        ],
        skippedLines: skipped,
      ),
    );
  }

  static Map<String, Object?>? _decode(String line) {
    try {
      return mapOf(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }

  /// The `callId` a tool result answers, wherever the version put it.
  static String _callIdOf(Object? message) {
    final map = mapOf(message);
    final source = mapOf(map?['source']);
    final direct = stringOf(source?['callId']) ?? stringOf(map?['toolCallId']);
    if (direct != null) return direct;
    for (final block in listOf(map?['content'])) {
      final id = stringOf(mapOf(block)?['toolCallId']);
      if (id != null) return id;
    }
    return '';
  }

  /// The text of a tool result, which arrives as content blocks inside a
  /// message inside the event.
  static String _resultTextOf(Object? message) {
    final map = mapOf(message);
    final blocks = listOf(map?['content']);
    final parts = <String>[];
    for (final block in blocks) {
      final entry = mapOf(block);
      if (entry == null) continue;
      final inner = stringOf(entry['text']);
      if (inner != null && inner.isNotEmpty) {
        parts.add(inner);
        continue;
      }
      final nested = textOfBlocks(entry['content']);
      if (nested.isNotEmpty) parts.add(nested);
    }
    return parts.join('\n');
  }

  /// Whether the result says it failed.
  ///
  /// dsh records `meta` on some results; a non-zero exit is the shape that
  /// carries a failure, and anything else is left unknown rather than guessed.
  static bool? _failedOf(Object? message) {
    final map = mapOf(message);
    if (map == null) return null;
    final meta = mapOf(map['meta']);
    if (meta == null) return null;
    final exit = intOf(meta['exitCode']) ?? intOf(meta['exit_code']);
    if (exit != null) return exit != 0;
    final failed = meta['isError'] ?? meta['error'];
    return failed is bool ? failed : null;
  }

  static TokenUsage? _usageOf(Object? value) {
    final map = mapOf(value);
    if (map == null) return null;
    // Additive, like pi's and unlike codex's: `cacheReadTokens` is not part of
    // `inputTokens`, which the numbers confirm — 4538 + 227 + 10880 = 15645.
    final usage = TokenUsage(
      input: intOf(map['inputTokens']),
      output: intOf(map['outputTokens']),
      cacheRead: intOf(map['cacheReadTokens']),
      cacheWrite: intOf(map['cacheWriteTokens']),
      reasoning: intOf(map['reasoningTokens']),
      total: intOf(map['totalTokens']),
    );
    return usage.isEmpty ? null : usage;
  }

}

class _CallSite {
  const _CallSite(this.turn, this.index, this.startedAt);

  final _TurnBuilder turn;
  final int index;
  final DateTime? startedAt;
}

class _TurnBuilder {
  _TurnBuilder({required this.number, this.at});

  /// The number the agent used, which is what the screen shows.
  final int number;
  DateTime? at;
  String? prompt;
  TokenUsage? usage;
  final List<TraceItem> items = [];

  TraceTurn freeze({required int index}) => TraceTurn(
    index: index,
    prompt: prompt,
    startedAt: at,
    usage: usage,
    items: List.unmodifiable(items),
  );
}
