/// Reading codex's own rollout files.
///
/// WHERE THEY LIVE: `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl`.
/// Each line is `{timestamp, ordinal, type, payload}`, and the type tells you
/// which of four very different things the payload is:
///
///   session_meta    once, at the top: session id, cwd, cli version
///   response_item   the conversation — `message`, `reasoning`,
///                   `function_call`, `function_call_output`
///   event_msg       the runtime's own view — `task_started`, `task_complete`,
///                   `token_count`, and `item_completed`, which DUPLICATES the
///                   response items and is therefore ignored here
///   token_usage_record   the bill, per turn
///
/// WHAT IS NOT HERE: the chain of thought. A `reasoning` item carries a
/// one-line `summary` and an `encrypted_content` blob that only OpenAI can
/// read, so the trace shows the summary it was given and never implies there
/// was more — claiming to show "thinking" when the text is a label would be
/// the same lie as an invented token count.
///
/// TOKENS ARE PER TURN and the file says so itself: `token_count.info` carries
/// both `last_token_usage` (this inference) and `total_token_usage` (the thread
/// since it began). The trace accumulates the former for its per-turn figure
/// and takes the latter for the session, because adding up the last-token
/// numbers and calling it a total is a different number from what the agent
/// reports.
library;

import 'dart:convert';

import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/domain/transcript/session_trace.dart';

class CodexTranscript implements TranscriptAdapter {
  const CodexTranscript();

  @override
  String get agentId => 'codex';

  @override
  bool get isCompressed => false;

  /// codex has no cwd in the path, so the cwd has to be read out of the files.
  ///
  /// Only the last few weeks are searched, and only files that mention this
  /// directory: without the sieve the answer is "the newest session on the
  /// machine", which is a different project's conversation.
  @override
  String locateCommand(String cwd, DateTime now) {
    final since = now.subtract(const Duration(days: 30));
    final stamp = '${since.year}-${_two(since.month)}-${_two(since.day)}';
    const root = r'$HOME/.codex/sessions';
    return 'find "$root" -name "*.jsonl" -type f -newermt $stamp -print 2>/dev/null '
        '| xargs grep -l -- ${quoteShell(cwd)} 2>/dev/null '
        '| xargs ls -t 2>/dev/null | head -5';
  }

  @override
  String readTailCommand(String path, int limit) =>
      'tail -c $limit -- ${quoteShell(path)} 2>/dev/null';

  static String _two(int value) => value.toString().padLeft(2, '0');

  @override
  bool canParse(String firstLine) {
    final decoded = _decode(firstLine);
    if (decoded == null) return false;
    final type = stringOf(decoded['type']);
    return type != null && _codexLineTypes.contains(type) && decoded['payload'] != null;
  }

  @override
  TranscriptParse parse(Iterable<String> lines) {
    final turns = <_TurnBuilder>[];
    final open = <String, _CallSite>{};
    TokenUsage? reported;
    String? model;
    String? cwd;
    String? sessionId;
    var skipped = 0;
    var recognised = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final decoded = _decode(line);
      if (decoded == null) {
        skipped++;
        continue;
      }

      final at = timeOf(decoded['timestamp']);
      final type = stringOf(decoded['type']);
      final payload = mapOf(decoded['payload']);
      // Every record of the log counts as understood, not only the ones that
      // carry conversation: a rollout that recorded no turn is still a codex
      // rollout, and calling it a foreign file would hide it.
      if (type != null && _codexLineTypes.contains(type)) recognised++;

      switch (type) {
        case 'session_meta':
          sessionId ??= stringOf(payload?['session_id']);
          cwd ??= stringOf(payload?['cwd']);
        case 'thread_settings_applied':
          model ??= stringOf(mapOf(payload?['thread_settings'])?['model']);
        case 'token_usage_record':
          // The thread-wide bill, stated by the agent. Kept as the thread
          // total rather than summed into a turn: it is cumulative, and
          // adding a cumulative number to a per-turn one would double it.
          final usage = _usageOf(decoded['usage']);
          if (usage != null) reported = usage;
        case 'turn_context':
          final context = payload ?? const <String, Object?>{};
          cwd ??= stringOf(context['cwd']);
          model ??= stringOf(context['model']);
        case 'event_msg':
          final kind = stringOf(payload?['type']);
          switch (kind) {
            case 'task_started':
              turns.add(
                _TurnBuilder(at: timeSecOf(payload?['started_at']) ?? at),
              );
            case 'task_complete':
              // `last_agent_message` repeats the assistant text that already
              // arrived as a response item. Not drawn twice.
              break;
            case 'token_count':
              final info = mapOf(payload?['info']);
              final window = intOf(info?['model_context_window']);
              final last = _usageOf(info?['last_token_usage']);
              if (last != null) {
                final turn = turns.isEmpty ? null : turns.last;
                if (turn != null) {
                  final withWindow = window == null
                      ? last
                      : TokenUsage(
                          input: last.input,
                          output: last.output,
                          cacheRead: last.cacheRead,
                          cacheWrite: last.cacheWrite,
                          reasoning: last.reasoning,
                          total: last.total,
                          cost: last.cost,
                          contextWindow: window,
                        );
                  turn.usage = turn.usage == null
                      ? withWindow
                      : turn.usage!.merge(withWindow);
                }
              }
            default:
              break;
          }
        case 'response_item':
          final kind = stringOf(payload?['type']);
          switch (kind) {
            case 'message':
              final role = stringOf(payload?['role']) ?? '';
              // `developer` and `system` carry the harness's own instructions —
              // thousands of tokens of them, repeated every turn. They are not
              // the conversation and are skipped on purpose.
              if (role != 'user' && role != 'assistant') break;
              final text = textOfBlocks(
                payload?['content'],
                types: const {'input_text', 'output_text', 'text'},
              );
              if (text.trim().isEmpty) break;
              if (role == 'user' && _isHarnessPreamble(text)) break;
              if (role == 'user') {
                final turn = turns.isEmpty
                    ? (turns..add(_TurnBuilder(at: at))).last
                    : turns.last;
                turn.prompt ??= text;
              } else {
                if (turns.isEmpty) turns.add(_TurnBuilder(at: at));
                turns.last.items.add(TraceText(text));
              }
            case 'reasoning':
              final summary = _summaryOf(payload?['summary']);
              if (summary.isNotEmpty) {
                if (turns.isEmpty) turns.add(_TurnBuilder(at: at));
                turns.last.items.add(TraceThinking(summary));
              }
            case 'function_call':
              final id = stringOf(payload?['call_id']) ?? stringOf(payload?['id']) ?? '';
              if (turns.isEmpty) turns.add(_TurnBuilder(at: at));
              turns.last.items.add(
                TraceToolCall(
                  id: id,
                  name: stringOf(payload?['name']) ?? '?',
                  arguments: stringOf(payload?['arguments']) ?? '',
                ),
              );
              open[id] = _CallSite(turns.length - 1, turns.last.items.length - 1, at);
            case 'function_call_output':
              final id = stringOf(payload?['call_id']) ?? '';
              final site = open.remove(id);
              final output = stringOf(payload?['output']) ?? '';
              if (site == null) break;
              final started = site.startedAt;
              final duration = (started == null || at == null)
                  ? null
                  : at.difference(started);
              final previous = turns[site.turn].items[site.index];
              if (previous is TraceToolCall) {
                turns[site.turn].items[site.index] = TraceToolCall(
                  id: previous.id,
                  name: previous.name,
                  arguments: previous.arguments,
                  duration: duration != null && duration.isNegative ? null : duration,
                  // codex reports failures inside the output text rather than
                  // as a flag, so "exited with a non-zero code" is the only
                  // signal there is — and reading a process's exit line is a
                  // measurement, not a guess.
                  isError: _looksFailed(output),
                  result: output.isEmpty ? null : output,
                );
              }
            default:
              break;
          }
        default:
          // `world_state`, `compacted`, and whatever the next version adds.
          // Unknown is not an error: the file is a log, and a log grows.
          break;
      }
    }

    if (recognised == 0) {
      return const UnusableTranscript('no codex records this adapter knows');
    }

    return ParsedTranscript(
      TraceSession(
        agentId: agentId,
        model: model,
        sessionId: sessionId,
        cwd: cwd,
        turns: [
          for (var i = 0; i < turns.length; i++) turns[i].freeze(index: i + 1),
        ],
        skippedLines: skipped,
        reportedUsage: reported,
      ),
    );
  }

  static const Set<String> _codexLineTypes = {
    'session_meta',
    'response_item',
    'event_msg',
    'token_usage_record',
    'turn_context',
    'world_state',
    'compacted',
  };

  static Map<String, Object?>? _decode(String line) {
    try {
      return mapOf(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }

  static String _summaryOf(Object? value) {
    final parts = <String>[];
    for (final entry in listOf(value)) {
      final text = stringOf(mapOf(entry)?['text']);
      if (text != null && text.trim().isNotEmpty) parts.add(text.trim());
    }
    return parts.join('\n');
  }

  /// Whether a tool's own output says it failed.
  ///
  /// Deliberately narrow: only a line that reports a non-zero exit code, which
  /// is what codex's shell tool prints. Matching anything looser — the word
  /// "error" anywhere in the output — would paint a passing run red because it
  /// happened to print a stack trace it was asked to read.
  static bool _looksFailed(String output) {
    if (output.isEmpty) return false;
    final match = RegExp(r'Process exited with code (-?\d+)').firstMatch(output);
    if (match == null) return false;
    return match.group(1) != '0';
  }

  /// Whether a user message is really the harness talking to itself.
  ///
  /// codex puts its own instructions into `role: "user"` messages — a 17 000
  /// character `# AGENTS.md instructions for <cwd>` block, the skills roster,
  /// and an environment context — and every one of them would otherwise be
  /// rendered as the first thing the human asked for. Only these wrappers are
  /// skipped; a person pasting XML into the prompt is still a person.
  static bool _isHarnessPreamble(String text) {
    const wrappers = [
      '# AGENTS.md instructions for ',
      '<user_instructions>',
      '<environment_context>',
      '<skills_instructions>',
      '<INSTRUCTIONS>',
      '<codex_internal_context',
    ];
    final trimmed = text.trimLeft();
    return wrappers.any(trimmed.startsWith);
  }

  static TokenUsage? _usageOf(Object? value) {
    final map = mapOf(value);
    if (map == null) return null;
    final cached = intOf(map['cached_input_tokens']);
    final rawInput = intOf(map['input_tokens']);
    // `cached_input_tokens` is a SUBSET of `input_tokens` here, and `total` is
    // their sum plus the output. Anthropic-shaped agents (pi, Claude) report
    // the cache separately instead. Normalising to the additive meaning is what
    // lets one screen add up several agents without a footnote: `in` means
    // tokens the model had to read fresh, `cache` means tokens it read from the
    // cache, and the two never overlap.
    final fresh = (rawInput == null || cached == null)
        ? rawInput
        : (rawInput - cached).clamp(0, rawInput);
    final usage = TokenUsage(
      input: fresh,
      output: intOf(map['output_tokens']),
      cacheRead: cached,
      cacheWrite: intOf(map['cache_write_input_tokens']),
      reasoning: intOf(map['reasoning_output_tokens']),
      total: intOf(map['total_tokens']),
    );
    return usage.isEmpty ? null : usage;
  }
}

class _CallSite {
  const _CallSite(this.turn, this.index, this.startedAt);

  final int turn;
  final int index;
  final DateTime? startedAt;
}

class _TurnBuilder {
  _TurnBuilder({this.at});

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
