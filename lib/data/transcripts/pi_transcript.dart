/// Reading pi's own session files.
///
/// WHERE THEY LIVE: `~/.pi/agent/sessions/<cwd-slug>/<timestamp>_<uuid>.jsonl`.
/// Each line is `{type, id, timestamp, message}`; only `type == "message"`
/// carries the conversation, and everything else (model changes, thinking
/// level, session info) is metadata this adapter lets fall.
///
/// THE SHAPE, measured on a live machine (see the research doc's appendix):
///   user       {role, content: [{type: text, text}], timestamp}
///   assistant  {role, content: [...], usage, model, provider, timestamp}
///              where a block is `{type: text}` / `{type: thinking, thinking}`
///              / `{type: toolCall, id, name, arguments}`
///   toolResult {role, content: [{type: text}], toolCallId, toolName, isError}
///
/// A TOOL CALL AND ITS RESULT ARE TWO LINES, so the call is kept open until its
/// result arrives and the pairing is by id. A result that never comes leaves
/// the call open, which the trace shows as such rather than as a zero-second
/// success — an interrupted session really does end that way.
library;

import 'dart:convert';

import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/domain/transcript/session_trace.dart';

class PiTranscript implements TranscriptAdapter {
  const PiTranscript();

  @override
  String get agentId => 'pi';

  @override
  bool get isCompressed => false;

  /// pi keeps one directory per working directory, so the path is derivable.
  ///
  /// `$HOME` stays a bare dollar for the REMOTE shell to expand, and only the
  /// slug is quoted. The first version of this line put single quotes INSIDE a
  /// double-quoted string — where they are literal characters — so the path was
  /// `…/sessions/'--slug--'` and every lookup missed, which a phone reported as
  /// "no session record found" about a file sitting right there.
  @override
  String locateCommand(String cwd, DateTime now) {
    const root = r'$HOME/.pi/agent/sessions/';
    final dir = '"$root${dqShell(cwdSlug(cwd))}"';
    // More than one, newest first: the caller walks them, because a dsh-style
    // agent leaves empty stubs behind and pi-style files can be replaced.
    return 'ls -t $dir/*.jsonl 2>/dev/null | head -5';
  }

  @override
  String readTailCommand(String path, int limit) =>
      'tail -c $limit -- ${quoteShell(path)} 2>/dev/null';

  @override
  bool canParse(String firstLine) {
    final decoded = _decode(firstLine);
    if (decoded == null) return false;
    // STRUCTURE, NOT VOCABULARY. A type list was the first attempt and it was
    // wrong twice: the list was incomplete, and the one line it was asked about
    // is usually a fragment. What actually tells the three apart:
    //
    //   pi     every line carries a top-level `timestamp`
    //   dsh    every line carries `time`, and the header `createdAt`
    //   codex  every line carries `payload`
    if (decoded['payload'] != null) return false;
    if (decoded['time'] != null || decoded['createdAt'] != null) return false;
    if (decoded['timestamp'] == null) return false;
    final type = stringOf(decoded['type']);
    return type != null && _piLineTypes.contains(type);
  }

  @override
  TranscriptParse parse(Iterable<String> lines) {
    final turns = <_TurnBuilder>[];
    final open = <String, _CallSite>{};
    TokenUsage? usage;
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

      final type = stringOf(decoded['type']);
      if (type != 'message') {
        // Metadata, but two of these lines carry facts the header wants — and
        // a metadata line still counts as understood, so a session file with no
        // messages reads as "no turns yet" rather than as somebody else's file.
        if (type != null && _piLineTypes.contains(type)) recognised++;
        cwd ??= stringOf(decoded['cwd']);
        sessionId ??= stringOf(decoded['sessionId']);
        continue;
      }

      final message = mapOf(decoded['message']);
      if (message == null) {
        skipped++;
        continue;
      }
      recognised++;

      final at = timeMsOf(message['timestamp']) ?? timeOf(decoded['timestamp']);
      final role = stringOf(message['role']) ?? '';
      switch (role) {
        case 'user':
          turns.add(_TurnBuilder(at: at, prompt: textOfBlocks(message['content'])));
        case 'assistant':
          // pi delimits a turn with the USER message, not with the assistant
          // one: a turn that calls three tools is several assistant messages
          // with tool results in between, and splitting there would report
          // three turns where the user asked one question.
          if (turns.isEmpty) turns.add(_TurnBuilder(at: at));
          final turn = turns.last;
          model ??= stringOf(message['model']);
          final messageUsage = _usageOf(message['usage']);
          if (messageUsage != null) {
            turn.usage = turn.usage == null
                ? messageUsage
                : turn.usage!.merge(messageUsage);
            usage = usage == null ? messageUsage : usage.merge(messageUsage);
          }
          for (final block in listOf(message['content'])) {
            final map = mapOf(block);
            if (map == null) continue;
            switch (stringOf(map['type'])) {
              case 'thinking':
                final text = stringOf(map['thinking']) ?? '';
                // An empty thinking block is normal — the agent kept only a
                // signature. Drawing an empty box would be worse than nothing.
                if (text.trim().isNotEmpty) {
                  turn.items.add(TraceThinking(text));
                }
              case 'text':
                final text = stringOf(map['text']) ?? '';
                if (text.trim().isNotEmpty) turn.items.add(TraceText(text));
              case 'toolCall':
                final id = stringOf(map['id']) ?? '';
                final call = TraceToolCall(
                  id: id,
                  name: stringOf(map['name']) ?? '?',
                  arguments: _argumentsOf(map['arguments']),
                );
                turns.last.items.add(call);
                open[id] = _CallSite(turns.length - 1, turns.last.items.length - 1, at);
            }
          }
        case 'toolResult':
          final id = stringOf(message['toolCallId']) ?? '';
          final site = open.remove(id);
          final text = textOfBlocks(message['content']);
          if (site == null) {
            // A result with no call in this file: a session that was compacted,
            // a line that arrived out of order, or — most often — the FIRST
            // line of a window read from the end of the file, whose call is
            // above the window. Keep it visible; do not invent a call for it.
            //
            // `turns.last` on an empty list THREW here, and the phone showed
            // "no session record found" for a file that existed: the page
            // caught the throw and reported it as an absence. Any window of a
            // file has to parse, so this opens a turn rather than assuming one.
            if (turns.isEmpty) turns.add(_TurnBuilder(at: at));
            turns.last.items.add(TraceNote(text));
            break;
          }
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
              isError: message['isError'] == true,
              result: text.isEmpty ? null : text,
            );
          }
        default:
          // A system prompt, or a role this version does not use. Not a
          // conversation turn, and not an error either.
          recognised--;
      }
    }

    if (recognised == 0) {
      return const UnusableTranscript('no pi message lines');
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
      ),
    );
  }

  /// pi's line types. Used only to recognise a file, so the list is the whole
  /// vocabulary rather than the subset this adapter reads.
  static const Set<String> _piLineTypes = {
    'session',
    'message',
    'model_change',
    'thinking_level_change',
    'session_info',
    'custom_message',
    'custom',
  };

  static Map<String, Object?>? _decode(String line) {
    try {
      final decoded = jsonDecode(line);
      return mapOf(decoded);
    } on FormatException {
      return null;
    }
  }

  /// `arguments` is an object here, but it is stored as whatever the model
  /// produced. Kept as text so the trace can show it without deciding what it
  /// means — and so a future version that writes a string still reads.
  static String _argumentsOf(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  static TokenUsage? _usageOf(Object? value) {
    final map = mapOf(value);
    if (map == null) return null;
    final cost = mapOf(map['cost']);
    final totalCost = doubleOf(cost?['total']);
    final usage = TokenUsage(
      input: intOf(map['input']),
      output: intOf(map['output']),
      cacheRead: intOf(map['cacheRead']),
      cacheWrite: intOf(map['cacheWrite']),
      reasoning: intOf(map['reasoning']),
      total: intOf(map['totalTokens']),
      // Zero means "this agent has no pricing for this provider", not "free".
      cost: (totalCost == null || totalCost == 0) ? null : totalCost,
    );
    return usage.isEmpty ? null : usage;
  }
}

/// Where one tool call sits, so its result can be written into it later.
class _CallSite {
  const _CallSite(this.turn, this.index, this.startedAt);

  final int turn;
  final int index;
  final DateTime? startedAt;
}

class _TurnBuilder {
  _TurnBuilder({this.at, this.prompt});

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
