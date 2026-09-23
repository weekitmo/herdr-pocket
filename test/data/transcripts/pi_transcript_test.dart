import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transcripts/codex_transcript.dart';
import 'package:herdr_pocket/data/transcripts/pi_transcript.dart';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/data/transcripts/transcript_registry.dart';
import 'package:herdr_pocket/domain/transcript/session_ledger.dart';

/// Reading pi's session files.
///
/// WHAT THIS FILE PROTECTS: the pairing. A tool call and its result are two
/// separate lines, and every number the ledger shows — how long the call took,
/// how often it failed — comes from putting them back together. Get the pairing
/// wrong and the screen still looks right: it simply reports a duration of
/// nothing for a tool that took a minute.
///
/// The fixtures are built as records rather than as raw JSON text so that the
/// shape being fed in is visible on the page, and so a field rename shows up as
/// a compile error rather than as a fixture that quietly stops matching.
void main() {
  const pi = PiTranscript();

  /// Unwraps a parse the fixtures expect to succeed, so the assertions below
  /// read as assertions rather than as error handling.
  LedgerSession parsed(TranscriptParse result) => switch (result) {
    ParsedTranscript(:final session) => session,
    UnusableTranscript(:final detail) => throw StateError('fixture: $detail'),
  };

  test('a turn is delimited by the user, not by each assistant message', () {
    // Three assistant messages belong to one question: pi delimits a turn with
    // the user message, and a turn that calls a tool is several assistant
    // messages with results in between.
    final session = parsed(
      pi.parse([
        _session(cwd: '/work/app'),
        _user('run the tests', at: 1000),
        _assistant(content: [_thinking('let me look'), _text('checking')], at: 2000),
        _assistant(content: [_toolCall('c1', 'bash', {'command': 'ls'})], at: 3000),
        _result('c1', 'bash', 'ok', at: 5000),
      ]),
    );

    expect(session.turns, hasLength(1));
    expect(session.turns.single.prompt, 'run the tests');
  });

  test('a tool call and its result become one item with a measured duration', () {
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_toolCall('c1', 'bash', {'command': 'sleep 4'})], at: 2000),
        _result('c1', 'bash', 'done', at: 6000),
      ]),
    );

    final call = session.turns.single.toolCalls.single;
    expect(call.name, 'bash');
    expect(call.duration, const Duration(seconds: 4));
    expect(call.isError, isFalse);
    expect(call.result, 'done');
  });

  test('a result marked as an error stays an error', () {
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_toolCall('c1', 'read', {'path': 'a.dart'})], at: 2000),
        _result('c1', 'read', 'ENOENT', at: 3000, isError: true),
      ]),
    );

    expect(session.turns.single.toolCalls.single.isError, isTrue);
  });

  test('a call whose result never arrived is open, not a zero-second success', () {
    // A session that was interrupted really does end this way. Reporting it as
    // a success would make the ledger claim something the transcript never said.
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_toolCall('c1', 'bash', {'command': 'sleep 999'})], at: 2000),
      ]),
    );

    final call = session.turns.single.toolCalls.single;
    expect(call.isOpen, isTrue);
    expect(call.duration, isNull);
    expect(call.isError, isNull);
  });

  test('an empty thinking block is not drawn', () {
    // pi keeps the block and drops the text once it has been redacted. An empty
    // box on screen would say "it thought nothing", which is not what happened.
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_thinking(''), _text('answer')], at: 2000),
      ]),
    );

    expect(session.turns.single.items.whereType<LedgerThinking>(), isEmpty);
    expect(session.turns.single.items.whereType<LedgerText>(), hasLength(1));
  });

  test('a result with no matching call is kept but not attached', () {
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _result('missing', 'bash', 'orphan output', at: 2000),
      ]),
    );

    expect(session.turns.single.toolCalls, isEmpty);
    expect(session.turns.single.items.whereType<LedgerNote>(), hasLength(1));
  });

  test('usage accumulates across the inferences inside one turn', () {
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_text('one')], at: 2000, usage: {'input': 10, 'output': 3}),
        _assistant(content: [_text('two')], at: 3000, usage: {'input': 20, 'output': 4}),
      ]),
    );

    final usage = session.turns.single.usage;
    expect(usage?.input, 30);
    expect(usage?.output, 7);
  });

  test('a zero cost is treated as unreported, not as free', () {
    // pi writes a cost object for every message and fills it with zeros when it
    // has no pricing for the provider. `$0.00` next to real work is a lie.
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_text('one')], at: 2000, usage: {
          'input': 10,
          'cost': {'total': 0},
        }),
      ]),
    );

    expect(session.turns.single.usage?.cost, isNull);
  });

  test('a real cost survives', () {
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        _assistant(content: [_text('one')], at: 2000, usage: {
          'input': 10,
          'cost': {'total': 0.42},
        }),
      ]),
    );

    expect(session.turns.single.usage?.cost, closeTo(0.42, 0.0001));
  });

  test('EVERY window of a session parses — no window may throw', () {
    // THE PHONE BUG. We read the END of a file, so the parser starts wherever
    // the cut landed: mid-record, mid-turn, or right on a tool result whose
    // call is above the window. `turns.last` on an empty list threw, the page
    // caught it, and the screen said "no session record found" about a file
    // that was sitting right there.
    //
    // So this walks the cut across the whole file and asserts the weaker but
    // load-bearing property: whatever the window, parsing returns a result and
    // never an exception.
    final full = [
      _session(cwd: '/work/app'),
      _user('run the tests', at: 1000),
      _assistant(content: [_thinking('reading'), _toolCall('c1', 'bash', {'command': 'ls'})], at: 2000),
      _result('c1', 'bash', 'ok', at: 5000),
      _assistant(content: [_toolCall('c2', 'read', {'path': 'a.dart'})], at: 6000),
      _result('c2', 'read', 'ENOENT', at: 7000, isError: true),
      _user('again', at: 8000),
      _assistant(content: [_text('done')], at: 9000),
    ];

    for (var cut = 0; cut < full.length; cut++) {
      final window = full.sublist(cut);
      expect(
        () => const PiTranscript().parse(window),
        returnsNormally,
        reason: 'the window starting at line $cut must not throw',
      );
    }
  });

  test('a window that starts with a tool result opens a turn for it', () {
    // The specific shape that crashed: a result with no call above it.
    final window = [
      _result('c9', 'bash', 'output of a call above the window', at: 1000),
      _assistant(content: [_text('carry on')], at: 2000),
    ];

    final result = const PiTranscript().parse(window);
    expect(result, isA<ParsedTranscript>());
    expect((result as ParsedTranscript).session.turns, hasLength(1));
  });

  test('unreadable lines are counted, and the rest still reads', () {
    final session = parsed(
      pi.parse([
        _session(),
        _user('go', at: 1000),
        '{ this is not json',
        _assistant(content: [_text('answer')], at: 2000),
      ]),
    );

    expect(session.skippedLines, 1);
    expect(session.turns.single.items, isNotEmpty);
  });

  test('a metadata-only file is a session with no turns, not a foreign file', () {
    // "No turns" and "this is not a pi file" are different answers. A session
    // whose only records are metadata was still written by pi, and calling it
    // foreign would hide it — the same distinction dsh needs for the empty
    // sessions it opens every time it runs.
    final result = pi.parse([
      _session(),
      jsonEncode({'type': 'model_change', 'timestamp': _iso(2000)}),
    ]);

    expect(result, isA<ParsedTranscript>());
    expect((result as ParsedTranscript).session.turns, isEmpty);
  });

  test('a file this adapter understands none of is unusable', () {
    final result = pi.parse([
      jsonEncode(<String, Object?>{'hello': 'world'}),
      jsonEncode(<String, Object?>{'another': 'thing'}),
    ]);

    expect(result, isA<UnusableTranscript>());
  });

  test("the adapter recognises its own files and refuses the other agent's", () {
    expect(adapterForAgent('pi'), isA<PiTranscript>());
    expect(adapterForAgent('PI'), isA<PiTranscript>());
    expect(adapterForAgent('codex'), isA<CodexTranscript>());
    expect(adapterForAgent('claude'), isNull);

    expect(adapterForLine(_session()), isA<PiTranscript>());
    expect(
      adapterForLine(jsonEncode(<String, Object?>{'type': 'session_meta', 'payload': <String, Object?>{}})),
      isA<CodexTranscript>(),
    );
    expect(adapterForLine('{"nothing": "familiar"}'), isNull);
  });

  test('cwd and model reach the header', () {
    final session = parsed(
      pi.parse([
        _session(cwd: '/work/app'),
        _user('go', at: 1000),
        _assistant(content: [_text('x')], at: 2000, model: 'deepseek-flash'),
      ]),
    );

    expect(session.cwd, '/work/app');
    expect(session.model, 'deepseek-flash');
  });
}

String _session({String cwd = '/work/app'}) => jsonEncode({
  'type': 'session',
  'timestamp': _iso(0),
  'cwd': cwd,
});

String _user(String text, {required int at}) => jsonEncode({
  'type': 'message',
  'timestamp': _iso(at),
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'timestamp': at,
  },
});

String _assistant({
  required List<Map<String, Object?>> content,
  required int at,
  Map<String, Object?>? usage,
  String model = 'gpt-5',
}) => jsonEncode({
  'type': 'message',
  'timestamp': _iso(at),
  'message': {
    'role': 'assistant',
    'model': model,
    'content': content,
    if (usage != null) 'usage': usage,
    'timestamp': at,
  },
});

String _result(
  String callId,
  String toolName,
  String text, {
  required int at,
  bool isError = false,
}) => jsonEncode({
  'type': 'message',
  'timestamp': _iso(at),
  'message': {
    'role': 'toolResult',
    'toolCallId': callId,
    'toolName': toolName,
    'isError': isError,
    'content': [
      {'type': 'text', 'text': text},
    ],
    'timestamp': at,
  },
});

Map<String, Object?> _text(String text) => {'type': 'text', 'text': text};

Map<String, Object?> _thinking(String text) => {'type': 'thinking', 'thinking': text};

Map<String, Object?> _toolCall(
  String id,
  String name,
  Map<String, Object?> arguments,
) => {'type': 'toolCall', 'id': id, 'name': name, 'arguments': arguments};

/// pi writes the line's timestamp as ISO-8601 and the message's as epoch
/// milliseconds, so a fixture that only set one of them would not exercise the
/// path the real file takes.
String _iso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
