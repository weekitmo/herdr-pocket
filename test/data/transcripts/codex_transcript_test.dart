import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transcripts/codex_transcript.dart';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/domain/transcript/session_ledger.dart';

/// Reading codex's rollout files.
///
/// WHAT THIS FILE PROTECTS: the difference between what codex records and what
/// it *means*. Three things here would each produce a screen that looks
/// plausible and is wrong:
///
///   * its own instructions arrive as `role: "user"` messages, so the first
///     thing the ledger would show is a 17 000-character AGENTS.md block;
///   * `cached_input_tokens` is a SUBSET of `input_tokens`, so adding the two
///     the way an Anthropic-shaped agent requires doubles the bill;
///   * a tool failure is not a flag — it is a line inside the output text.
void main() {
  const codex = CodexTranscript();

  LedgerSession parse(List<String> lines) {
    final result = codex.parse(lines);
    return switch (result) {
      ParsedTranscript(:final session) => session,
      UnusableTranscript() => throw StateError('fixture did not parse: $result'),
    };
  }

  test("the harness preamble is not the user's prompt", () {
    final session = parse([
      _sessionMeta(cwd: '/work/app'),
      _taskStarted(atSec: 100),
      _user('# AGENTS.md instructions for /work/app\n\n<INSTRUCTIONS>\n…'),
      _user('fix the flaky test'),
      _assistant('looking'),
    ]);

    expect(session.turns.single.prompt, 'fix the flaky test');
  });

  test('a real prompt that happens to start with a brace is still a prompt', () {
    // The wrappers are a fixed list, not "anything that looks like markup".
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('{ "not": "a wrapper" }'),
    ]);

    expect(session.turns.single.prompt, '{ "not": "a wrapper" }');
  });

  test('cached input is subtracted from input, not added to it', () {
    // total = input + output, and cached ⊂ input. Reading the cache as an extra
    // would report twice the tokens the agent actually billed.
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _tokenCount(input: 1000, cached: 400, output: 50),
    ]);

    final usage = session.turns.single.usage;
    expect(usage?.input, 600);
    expect(usage?.cacheRead, 400);
    expect(usage?.total, 1050);
  });

  test('a non-zero exit code in the output is a failure', () {
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _call('c1', 'exec_command', '{"cmd":"false"}', atSec: 101),
      _output('c1', 'Process exited with code 1\nOutput:\nboom', atSec: 103),
    ]);

    final call = session.turns.single.toolCalls.single;
    expect(call.isError, isTrue);
    expect(call.duration, const Duration(seconds: 2));
  });

  test('a zero exit code is not a failure, whatever else the output says', () {
    // A tool that prints a stack trace it was asked to read is not a failure.
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _call('c1', 'exec_command', '{"cmd":"cat log"}', atSec: 101),
      _output('c1', 'Process exited with code 0\nOutput:\nerror: expected', atSec: 102),
    ]);

    expect(session.turns.single.toolCalls.single.isError, isFalse);
  });

  test('reasoning arrives as a summary and is drawn as one', () {
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _reasoning('Preparing to read the config'),
    ]);

    final thinking = session.turns.single.items.whereType<LedgerThinking>().single;
    expect(thinking.text, 'Preparing to read the config');
  });

  test('the session total is the one the agent stated', () {
    // `token_usage_record` is cumulative and `token_count` is per turn; the
    // screen must not add a cumulative number into a per-turn one.
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _tokenCount(input: 1000, cached: 0, output: 50),
      _tokenUsageRecord(input: 9000, cached: 0, output: 700),
    ]);

    expect(session.reportedUsage?.input, 9000);
    expect(session.turns.single.usage?.input, 1000);
  });

  test('the context window travels with the usage that reported it', () {
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _tokenCount(input: 10, cached: 0, output: 1, window: 258400),
    ]);

    expect(session.turns.single.usage?.contextWindow, 258400);
  });

  test('several tool calls in one turn keep their own results', () {
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _call('c1', 'exec_command', '{"cmd":"a"}', atSec: 101),
      _call('c2', 'exec_command', '{"cmd":"b"}', atSec: 101),
      _output('c2', 'Process exited with code 0', atSec: 104),
      _output('c1', 'Process exited with code 1', atSec: 102),
    ]);

    final calls = session.turns.single.toolCalls.toList();
    expect(calls, hasLength(2));
    expect(calls[0].arguments, '{"cmd":"a"}');
    expect(calls[0].duration, const Duration(seconds: 1));
    expect(calls[0].isError, isTrue);
    expect(calls[1].duration, const Duration(seconds: 3));
    expect(calls[1].isError, isFalse);
  });

  test('EVERY window of a session parses — no window may throw', () {
    // codex is read from the end too, for the same reason pi is. The pi
    // adapter had a window that crashed and the phone showed it as "nothing
    // found"; this is the same property, checked on this side before it can.
    final full = [
      _sessionMeta(),
      _taskStarted(atSec: 100),
      _user('go'),
      _reasoning('thinking about it'),
      _call('c1', 'exec_command', '{"cmd":"a"}', atSec: 101),
      _output('c1', 'Process exited with code 1', atSec: 102),
      _assistant('done'),
      _tokenCount(input: 100, cached: 0, output: 10),
    ];

    for (var cut = 0; cut < full.length; cut++) {
      expect(
        () => const CodexTranscript().parse(full.sublist(cut)),
        returnsNormally,
        reason: 'the window starting at line $cut must not throw',
      );
    }
  });

  test('a broken line costs one line, not the session', () {
    final session = parse([
      _sessionMeta(),
      _taskStarted(atSec: 100),
      'not json at all',
      _user('go'),
    ]);

    expect(session.skippedLines, 1);
    expect(session.turns.single.prompt, 'go');
  });

  test('a rollout with no turns is a session with no turns, not a foreign file', () {
    // The distinction that matters everywhere in this feature: "the record has
    // nothing in it yet" is not "this is somebody else's file".
    final parse = codex.parse([_sessionMeta(), _taskStarted(atSec: 100)]);
    expect(parse, isA<ParsedTranscript>());
    // A turn exists — the agent opened one — and nothing was said in it, which
    // is a different claim from "this is not a codex file".
    final session = (parse as ParsedTranscript).session;
    expect(session.turns.every((turn) => turn.items.isEmpty), isTrue);
  });

  test('a file this adapter understands none of is unusable', () {
    final parse = codex.parse([
      jsonEncode(<String, Object?>{'hello': 'world'}),
    ]);

    expect(parse, isA<UnusableTranscript>());
  });

  test('the model is read from the thread settings', () {
    final session = parse([
      _sessionMeta(),
      _threadSettings(model: 'gpt-5.6-sol'),
      _taskStarted(atSec: 100),
      _user('go'),
    ]);

    expect(session.model, 'gpt-5.6-sol');
  });

  test('unknown payload types are skipped without failing the parse', () {
    // The file is a log and a log grows: a future version's new record must not
    // be the reason a phone cannot read yesterday\'s session.
    final session = parse([
      _sessionMeta(),
      jsonEncode(<String, Object?>{
        'timestamp': _iso(100),
        'type': 'world_state',
        'payload': <String, Object?>{'x': 1},
      }),
      jsonEncode(<String, Object?>{
        'timestamp': _iso(101),
        'type': 'something_new',
        'payload': <String, Object?>{},
      }),
      _taskStarted(atSec: 102),
      _user('go'),
    ]);

    expect(session.turns.single.prompt, 'go');
  });
}

String _iso(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
        .toIso8601String();

String _sessionMeta({String cwd = '/work/app'}) => jsonEncode({
  'timestamp': _iso(99),
  'type': 'session_meta',
  'payload': {'session_id': 's-1', 'cwd': cwd, 'cli_version': '0.153.0'},
});

String _threadSettings({required String model}) => jsonEncode({
  'timestamp': _iso(99),
  'type': 'thread_settings_applied',
  'payload': {
    'thread_settings': {'model': model},
  },
});

String _taskStarted({required int atSec}) => jsonEncode({
  'timestamp': _iso(atSec),
  'type': 'event_msg',
  'payload': {'type': 'task_started', 'turn_id': 't-$atSec', 'started_at': atSec},
});

String _user(String text) => jsonEncode({
  'timestamp': _iso(100),
  'type': 'response_item',
  'payload': {
    'type': 'message',
    'role': 'user',
    'content': [
      {'type': 'input_text', 'text': text},
    ],
  },
});

String _assistant(String text) => jsonEncode({
  'timestamp': _iso(105),
  'type': 'response_item',
  'payload': {
    'type': 'message',
    'role': 'assistant',
    'content': [
      {'type': 'output_text', 'text': text},
    ],
  },
});

String _reasoning(String summary) => jsonEncode({
  'timestamp': _iso(101),
  'type': 'response_item',
  'payload': {
    'type': 'reasoning',
    'id': 'rs-1',
    'summary': [
      {'type': 'summary_text', 'text': summary},
    ],
    'content': null,
    'encrypted_content': 'gAAAAA',
  },
});

String _call(String callId, String name, String arguments, {required int atSec}) =>
    jsonEncode({
      'timestamp': _iso(atSec),
      'type': 'response_item',
      'payload': {
        'type': 'function_call',
        'id': 'fc-$callId',
        'name': name,
        'arguments': arguments,
        'call_id': callId,
      },
    });

String _output(String callId, String output, {required int atSec}) => jsonEncode({
  'timestamp': _iso(atSec),
  'type': 'response_item',
  'payload': {
    'type': 'function_call_output',
    'id': 'fco-$callId',
    'call_id': callId,
    'output': output,
  },
});

String _tokenCount({
  required int input,
  required int cached,
  required int output,
  int? window,
}) => jsonEncode({
  'timestamp': _iso(106),
  'type': 'event_msg',
  'payload': {
    'type': 'token_count',
    'info': {
      'last_token_usage': {
        'input_tokens': input,
        'cached_input_tokens': cached,
        'output_tokens': output,
        'total_tokens': input + output,
      },
      if (window != null) 'model_context_window': window,
    },
  },
});

String _tokenUsageRecord({
  required int input,
  required int cached,
  required int output,
}) => jsonEncode({
  'timestamp': _iso(107),
  'type': 'token_usage_record',
  'payload': {
    'usage': {
      'input_tokens': input,
      'cached_input_tokens': cached,
      'output_tokens': output,
      'total_tokens': input + output,
    },
  },
  'usage': {
    'input_tokens': input,
    'cached_input_tokens': cached,
    'output_tokens': output,
    'total_tokens': input + output,
  },
});
