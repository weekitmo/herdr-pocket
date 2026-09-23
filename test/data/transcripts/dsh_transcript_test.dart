import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transcripts/codex_transcript.dart';
import 'package:herdr_pocket/data/transcripts/dsh_transcript.dart';
import 'package:herdr_pocket/data/transcripts/pi_transcript.dart';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/data/transcripts/transcript_registry.dart';
import 'package:herdr_pocket/domain/transcript/session_trace.dart';

/// Reading dsh's session files.
///
/// WHAT THIS FILE PROTECTS, beyond "the fields land in the right place":
///
///   * the TURN NUMBER is the agent's, not ours. dsh records `turn/start {turn}`
///     and `assistant/message {turn, step}`, so the trace does not have to
///     count from whatever window it happened to read — the one place in this
///     feature where a number on screen is the record's rather than a count of
///     what we saw;
///   * usage is PER STEP and is summed per turn, additively (the cache is not
///     part of `inputTokens` here, unlike codex);
///   * an assistant message repeats its tool calls inline in its content, and
///     counting both copies would double every call in the table.
///
/// The fixtures are built as records rather than raw JSON text for the same
/// reason the other two adapters' fixtures are: a renamed field should be a
/// compile error, not a fixture that quietly stops matching.
void main() {
  const dsh = DshTranscript();

  TraceSession parsed(TranscriptParse result) => switch (result) {
    ParsedTranscript(:final session) => session,
    UnusableTranscript(:final detail) => throw StateError('fixture: $detail'),
  };

  test('the turn number comes from the record, not from the window', () {
    // A window that starts at the agent's turn 7: the screen must say 7, not 1.
    final session = parsed(
      dsh.parse([
        _turnStart(7),
        _stepStart(7, 1),
        _user('carry on', turn: 7),
        _assistant(turn: 7, step: 1, text: 'ok'),
        _turnEnd(7),
      ]),
    );

    expect(session.turns.single.index, 7);
    expect(session.turns.single.prompt, 'carry on');
  });

  test('a tool call and its result become one item with a measured duration', () {
    final session = parsed(
      dsh.parse([
        _turnStart(3),
        _user('run it', turn: 3),
        _assistant(
          turn: 3,
          step: 1,
          text: 'running',
          usage: {'inputTokens': 100, 'outputTokens': 10, 'cacheReadTokens': 400},
        ),
        _toolCall(turn: 3, step: 1, id: 'c1', name: 'bash', at: 5000),
        _toolResult(turn: 3, step: 1, id: 'c1', text: 'file-a', at: 9000),
        _turnEnd(3),
      ]),
    );

    final call = session.turns.single.toolCalls.single;
    expect(call.name, 'bash');
    expect(call.duration, const Duration(seconds: 4));
    expect(call.result, 'file-a');
  });

  test('a reasoning block becomes a thinking item', () {
    // dsh keeps the reasoning TEXT in plain sight (unlike codex, which writes
    // an encrypted blob and a one-line summary). Dropping it left the trace
    // showing the answer with no sign of how it got there.
    final session = parsed(
      dsh.parse([
        _turnStart(1),
        _user('go', turn: 1),
        _assistant(
          turn: 1,
          step: 1,
          text: 'the answer',
          reasoning: 'weighing two options',
        ),
      ]),
    );

    final thinking = session.turns.single.items.whereType<TraceThinking>().single;
    expect(thinking.text, 'weighing two options');
  });

  test('an empty reasoning block is not drawn', () {
    final session = parsed(
      dsh.parse([
        _turnStart(1),
        _user('go', turn: 1),
        _assistant(turn: 1, step: 1, text: 'the answer', reasoning: '   '),
      ]),
    );

    expect(session.turns.single.items.whereType<TraceThinking>(), isEmpty);
  });

  test('the inline copy of a tool call is not counted twice', () {
    // `assistant/message` carries `{type: tool-call}` blocks as well as the
    // `tool/call` records. Reading both would double every call in the table.
    final session = parsed(
      dsh.parse([
        _turnStart(1),
        _user('go', turn: 1),
        _assistant(
          turn: 1,
          step: 1,
          text: 'looking',
          inlineCalls: [
            {'type': 'tool-call', 'id': 'c1', 'name': 'bash', 'arguments': '{}'},
          ],
        ),
        _toolCall(turn: 1, step: 1, id: 'c1', name: 'bash', at: 1000),
        _toolResult(turn: 1, step: 1, id: 'c1', text: 'ok', at: 2000),
      ]),
    );

    expect(session.turns.single.toolCalls, hasLength(1));
  });

  test('usage is summed across the steps of one turn, additively', () {
    final session = parsed(
      dsh.parse([
        _turnStart(1),
        _user('go', turn: 1),
        _assistant(
          turn: 1,
          step: 1,
          text: 'one',
          usage: {
            'inputTokens': 4538,
            'outputTokens': 227,
            'cacheReadTokens': 10880,
            'totalTokens': 15645,
          },
        ),
        _assistant(
          turn: 1,
          step: 2,
          text: 'two',
          usage: {'inputTokens': 1000, 'outputTokens': 50, 'totalTokens': 1050},
        ),
      ]),
    );

    final usage = session.turns.single.usage;
    expect(usage?.input, 5538);
    expect(usage?.output, 277);
    // The cache is a separate quantity here — 4538 + 227 + 10880 = 15645 is
    // what the agent itself wrote as the total, which is how we know.
    expect(usage?.cacheRead, 10880);
    expect(usage?.total, 16695);
  });

  test('a header-only session is a session with no turns, not a foreign file', () {
    // dsh opens a session directory every time it runs, so short-lived empty
    // ones are normal. Calling that "not a dsh file" would hide a session that
    // genuinely has nothing in it yet.
    final session = parsed(
      dsh.parse([
        _header(),
        jsonEncode(<String, Object?>{
          'type': 'approval/policy',
          'seq': 1,
          'time': 1000,
          'data': <String, Object?>{'policy': 'never'},
        }),
      ]),
    );

    expect(session.turns, isEmpty);
    expect(session.cwd, '/work/app');
  });

  test('EVERY window of a session parses — no window may throw', () {
    // The same property the other two adapters are held to, because a tail read
    // starts wherever the cut landed: mid-record, mid-turn, on a tool result
    // whose call is above the window.
    final full = [
      _header(),
      _turnStart(1),
      _stepStart(1, 1),
      _user('go', turn: 1),
      _assistant(turn: 1, step: 1, text: 'one'),
      _toolCall(turn: 1, step: 1, id: 'c1', name: 'bash', at: 2000),
      _toolResult(turn: 1, step: 1, id: 'c1', text: 'ok', at: 3000),
      _stepEnd(1, 1),
      _turnEnd(1),
      _turnStart(2),
      _user('again', turn: 2),
    ];

    for (var cut = 0; cut < full.length; cut++) {
      expect(
        () => dsh.parse(full.sublist(cut)),
        returnsNormally,
        reason: 'the window starting at line $cut must not throw',
      );
    }
  });

  test('a result whose call is above the window is kept, not attached', () {
    final session = parsed(
      dsh.parse([
        _toolResult(turn: 4, step: 2, id: 'gone', text: 'orphan', at: 1000),
        _assistant(turn: 4, step: 2, text: 'carry on'),
      ]),
    );

    expect(session.turns.single.toolCalls, isEmpty);
    expect(session.turns.single.items.whereType<TraceNote>(), hasLength(1));
  });

  test('the three adapters tell each other apart by structure', () {
    // One `type: session` line each, and the difference is in the other fields:
    // pi stamps `timestamp`, dsh carries `createdAt`, codex has `payload`.
    expect(const PiTranscript().canParse(_header()), isFalse);
    expect(dsh.canParse(_header()), isTrue);
    expect(adapterForLines([_header(), _user('go', turn: 1)]), isA<DshTranscript>());
    expect(
      adapterForLines([_codexLine()]),
      isA<CodexTranscript>(),
    );
  });

  test('the read decodes before it cuts, and survives a missing zstd on PATH', () {
    // The tail of a COMPRESSED stream is not the tail of the file, so the
    // command has to decode first. And a non-login shell does not have
    // Homebrew's bin on PATH, which is where zstd actually lives.
    final command = dsh.readTailCommand('/home/u/s/session.v3.jsonl.zstd', 4096);
    expect(command, contains('command -v zstd'));
    expect(command, contains('/opt/homebrew/bin/zstd'));
    expect(command, contains('-d -c'));
    expect(command, contains('| tail -c 4096'));
    expect(dsh.isCompressed, isTrue);
  });

  test('the locate command descends into the per-session directory', () {
    final command = dsh.locateCommand('/Users/x/app', DateTime.utc(2026, 9, 23));
    expect(command, contains(r'$HOME/.dsh/sessions/--Users-x-app--'));
    expect(command, contains('*/session*.jsonl.zstd'));
  });
}

String _header() => jsonEncode(<String, Object?>{
  'type': 'session',
  'version': 3,
  'id': 'session-1',
  'createdAt': 1000,
  'cwd': '/work/app',
  'delegationDepth': 0,
});

String _turnStart(int turn) =>
    jsonEncode(<String, Object?>{'type': 'turn/start', 'seq': 0, 'time': 1000, 'data': {'turn': turn}});

String _turnEnd(int turn) => jsonEncode(<String, Object?>{
  'type': 'turn/end',
  'seq': 1,
  'time': 1000,
  'data': {'turn': turn, 'reason': {'kind': 'completed'}},
});

String _stepStart(int turn, int step) => jsonEncode(<String, Object?>{
  'type': 'step/start',
  'seq': 2,
  'time': 1000,
  'data': {'turn': turn, 'step': step},
});

String _stepEnd(int turn, int step) => jsonEncode(<String, Object?>{
  'type': 'step/end',
  'seq': 3,
  'time': 1000,
  'data': {'turn': turn, 'step': step},
});

String _user(String text, {required int turn}) => jsonEncode(<String, Object?>{
  'type': 'user/message',
  'seq': 4,
  'time': 1000,
  'data': {
    'turn': turn,
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

String _assistant({
  required int turn,
  required int step,
  required String text,
  String? reasoning,
  Map<String, Object?>? usage,
  List<Map<String, Object?>> inlineCalls = const [],
}) => jsonEncode(<String, Object?>{
  'type': 'assistant/message',
  'seq': 5,
  'time': 1500,
  'data': {
    'turn': turn,
    'step': step,
    'message': {
      'role': 'assistant',
      'content': [
        if (reasoning != null) {'type': 'reasoning', 'text': reasoning},
        {'type': 'text', 'text': text},
        ...inlineCalls,
      ],
    },
    if (usage != null) 'usage': usage,
  },
});

String _toolCall({
  required int turn,
  required int step,
  required String id,
  required String name,
  required int at,
}) => jsonEncode(<String, Object?>{
  'type': 'tool/call',
  'seq': 6,
  'time': at,
  'data': {
    'turn': turn,
    'step': step,
    'callId': id,
    'name': name,
    'arguments': '{"command":"ls"}',
  },
});

String _toolResult({
  required int turn,
  required int step,
  required String id,
  required String text,
  required int at,
}) => jsonEncode(<String, Object?>{
  'type': 'tool/result',
  'seq': 7,
  'time': at,
  'data': {
    'turn': turn,
    'step': step,
    'message': {
      'source': {'kind': 'tool', 'callId': id},
      'content': [
        {
          'type': 'tool-result',
          'toolCallId': id,
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      ],
    },
  },
});

String _codexLine() => jsonEncode(<String, Object?>{
  'timestamp': '2026-09-23T02:00:00.000Z',
  'type': 'session_meta',
  'payload': <String, Object?>{'session_id': 's1', 'cwd': '/work/app'},
});
