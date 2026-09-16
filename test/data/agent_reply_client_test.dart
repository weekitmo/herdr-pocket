import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// Pins the WIRE SHAPE of the agent-reply calls.
///
/// These are the methods that press keys on a live agent, so a wrong parameter
/// name is not a cosmetic bug: herdr answers `unknown variant` / a missing-field
/// error, and the caller sees "nothing happened" on a screen where something
/// was supposed to happen. The daemon's parameter names are checked here
/// literally, on purpose.
class _RecordingTransport implements HerdrTransport {
  _RecordingTransport(this.reply);

  /// The JSON line the daemon would answer with.
  final String Function(String requestLine) reply;

  final List<Map<String, Object?>> sent = [];

  @override
  Future<String> roundTrip(String requestLine) async {
    sent.add((jsonDecode(requestLine) as Map).cast<String, Object?>());
    return reply(requestLine);
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError('not used by these calls');

  @override
  Future<void> close() async {}

  Map<String, Object?> get last => sent.last;
  Map<String, Object?> get lastParams =>
      (last['params']! as Map).cast<String, Object?>();
}

HerdrClient clientReturning(
  String Function(String requestLine) reply,
) =>
    HerdrClient(_RecordingTransport(reply));

void main() {
  group('agent.read', () {
    test('sends target and source and unwraps the read object', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"pane_read","read":'
            '{"pane_id":"w1:p1","source":"recent","format":"text",'
            r'"text":"Do you want to proceed?\n1. Yes","revision":7,'
            '"truncated":false}}}',
      );
      final result =
          await HerdrClient(transport).agentRead(target: 'w1:p1');

      expect(transport.lastParams['target'], 'w1:p1');
      expect(transport.lastParams['source'], 'recent');
      expect(result.text, 'Do you want to proceed?\n1. Yes');
      expect(result.paneId, 'w1:p1');
      expect(result.revision, 7);
      expect(result.truncated, isFalse);
    });

    test('carries truncation rather than hiding it', () async {
      // A clipped screen is what a person would press a key on. Losing this
      // flag turns "I saw part of it" into "I saw all of it".
      final client = clientReturning(
        (_) => '{"id":"x","result":{"type":"pane_read","read":'
            '{"text":"partial","truncated":true}}}',
      );
      final result = await client.agentRead(target: 'w1:p1');
      expect(result.truncated, isTrue);
    });

    test('omits lines when not asked, so the daemon picks its default', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"pane_read","read":{"text":""}}}',
      );
      await HerdrClient(transport).agentRead(target: 'w1:p1');
      expect(transport.lastParams.containsKey('lines'), isFalse);
    });

    test('a malformed read object is empty text, not a crash', () async {
      final client = clientReturning(
        (_) => '{"id":"x","result":{"type":"pane_read","read":"nonsense"}}',
      );
      final result = await client.agentRead(target: 'w1:p1');
      expect(result.text, isEmpty);
      expect(result.lines, isEmpty);
    });

    test('lines drops only the trailing blank', () async {
      final client = clientReturning(
        (_) => '{"id":"x","result":{"type":"pane_read","read":'
            r'{"text":"a\n\nb\n"}}}',
      );
      final result = await client.agentRead(target: 'w1:p1');
      expect(result.lines, ['a', '', 'b']);
    });
  });

  group('the reply calls', () {
    test('agent.send_keys sends the keys verbatim', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"ok"}}',
      );
      await HerdrClient(transport).agentSendKeys(
        target: 'w1:p1',
        keys: const ['y', 'enter'],
      );
      expect(transport.last['method'], HerdrMethod.agentSendKeys);
      expect(transport.lastParams['keys'], ['y', 'enter']);
    });

    test('agent.prompt sends text and NO wait when none was asked', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"agent_prompted","agent":'
            '{"pane_id":"w1:p1","agent":"claude","agent_status":"working"}}}',
      );
      final agent = await HerdrClient(transport).agentPrompt(
        target: 'w1:p1',
        text: 'run the tests',
      );
      expect(transport.lastParams['text'], 'run the tests');
      expect(transport.lastParams.containsKey('wait'), isFalse);
      expect(agent?.agent, 'claude');
    });

    test('agent.prompt can submit AND wait in one request', () async {
      // Two round trips would race the agent's own state change in between,
      // which is exactly what the server-side wait exists to avoid.
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"agent_prompted","agent":'
            '{"pane_id":"w1:p1","agent":"claude"}}}',
      );
      await HerdrClient(transport).agentPrompt(
        target: 'w1:p1',
        text: 'go',
        waitUntil: const ['done'],
        timeoutMs: 30000,
      );
      expect(transport.lastParams['wait'], {
        'until': ['done'],
        'timeout_ms': 30000,
      });
    });

    test('agent.focus targets the same address as the read', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"ok"}}',
      );
      await HerdrClient(transport).agentFocus('w1:p1');
      expect(transport.last['method'], HerdrMethod.agentFocus);
      expect(transport.lastParams['target'], 'w1:p1');
    });

    test('agent.rename sends an explicit null to clear a name', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"ok"}}',
      );
      await HerdrClient(transport).agentRename(target: 'w1:p1');
      expect(transport.lastParams.containsKey('name'), isTrue);
      expect(transport.lastParams['name'], isNull);
    });

    test('an unknown-method error surfaces as a typed exception', () async {
      // The capability probe depends on this: "the daemon does not have it" is
      // an ordinary error, not a transport failure.
      final client = clientReturning(
        (_) => '{"id":"","error":{"code":"unknown_method",'
            '"message":"invalid request: unknown variant `agent.read`"}}',
      );
      await expectLater(
        client.agentRead(target: 'w1:p1'),
        throwsA(
          isA<HerdrApiException>().having((e) => e.isUnknownMethod, 'unknown', isTrue),
        ),
      );
    });

    test('agent_blocked surfaces with its own code', () async {
      // The refusal that makes menu routing necessary: while an agent is
      // blocked, `agent.prompt` sends NOTHING.
      final client = clientReturning(
        (_) => '{"id":"","error":{"code":"agent_blocked",'
            '"message":"agent is blocked and requires interactive input"}}',
      );
      await expectLater(
        client.agentPrompt(target: 'w1:p1', text: 'go'),
        throwsA(
          isA<HerdrApiException>().having((e) => e.code, 'code', 'agent_blocked'),
        ),
      );
    });
  });
}
