import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/agent_ask.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/agent/agent_question.dart';
import 'package:herdr_pocket/domain/agent/agent_reply.dart';
import 'package:herdr_pocket/domain/agent/reply_guard.dart';

/// A daemon that answers by method, and records everything it was asked.
///
/// The recording is the important half: several of these tests assert that NO
/// input call was made at all, which is the only way to prove a refusal refused
/// rather than merely reported itself as one.
class _FakeDaemon implements HerdrTransport {
  _FakeDaemon(this.handlers);

  final Map<String, String Function(Map<String, Object?> params)> handlers;
  final List<Map<String, Object?>> sent = [];

  @override
  Future<String> roundTrip(String requestLine) async {
    final req = (jsonDecode(requestLine) as Map).cast<String, Object?>();
    sent.add(req);
    final method = req['method']! as String;
    final handler = handlers[method];
    if (handler == null) {
      return '{"id":"","error":{"code":"unknown_method",'
          '"message":"invalid request: unknown variant `$method`"}}';
    }
    return handler((req['params']! as Map).cast<String, Object?>());
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}

  Iterable<String> get methods => sent.map((r) => r['method']! as String);
  Map<String, Object?>? paramsOf(String method) {
    for (final r in sent.reversed) {
      if (r['method'] == method) {
        return (r['params']! as Map).cast<String, Object?>();
      }
    }
    return null;
  }

  bool sentInput() => methods.any(
        (m) => m == HerdrMethod.agentSendKeys ||
            m == HerdrMethod.agentPrompt ||
            m == HerdrMethod.paneSendText,
      );
}

const _ok = '{"id":"x","result":{"type":"ok"}}';
const _prompted = '{"id":"x","result":{"type":"agent_prompted","agent":'
    '{"pane_id":"w1:p1","agent":"claude"}}}';

String _agentList({String status = 'blocked', String? lastKnown, int seq = 10}) =>
    '{"id":"x","result":{"type":"agent_list","agents":['
    '{"pane_id":"w1:p1","agent":"claude","agent_status":"$status",'
    '${lastKnown == null ? '' : '"last_known_status":"$lastKnown",'}'
    '"state_change_seq":$seq}]}}';

String _paneList([String paneId = 'w1:p1']) =>
    '{"id":"x","result":{"type":"pane_list","panes":[{"pane_id":"$paneId"}]}}';

String _screen(String text) =>
    '{"id":"x","result":{"type":"pane_read","read":'
    '{"pane_id":"w1:p1","text":${jsonEncode(text)},"truncated":true,"revision":0}}}';

const _menuScreen = '''
Do you want to proceed?
❯ 1. Yes
  2. No
[gw-ai/openai @max]  repo  main
↑0 ↓0  TTFB 0s  0 tok/s  t0/s0''';

/// A board row, which is what the controller takes — so the routing decision
/// cannot be made from a flag that disagrees with the row being displayed.
AgentRow _row({
  String status = 'blocked',
  String? lastKnown,
  bool inputPending = false,
  int seq = 10,
}) =>
    AgentRow(
      info: AgentInfo.fromJson({
        'pane_id': 'w1:p1',
        'agent': 'claude',
        'agent_status': status,
        if (lastKnown != null) 'last_known_status': lastKnown,
        if (inputPending) 'input_pending': true,
        'state_change_seq': seq,
      }),
      isLive: true,
    );

void main() {
  group('load', () {
    test('asks for a bounded tail, not the whole buffer', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentRead: (_) => _screen(_menuScreen),
      });
      final ask = await AskController(HerdrClient(daemon)).load(_row());

      expect(
        daemon.paramsOf(HerdrMethod.agentRead)?['lines'],
        AskController.readLines,
      );
      expect(ask.question.options.length, 2);
      expect(ask.question.prompt, 'Do you want to proceed?');
      expect(ask.truncated, isTrue);
    });

    test('a screen with no question is not an error', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentRead: (_) => _screen('just some output\nno question here'),
      });
      final ask = await AskController(HerdrClient(daemon)).load(_row());

      expect(ask.question.confidence, QuestionConfidence.none);
      expect(ask.question.rawLines, isNotEmpty);
    });
  });

  group('answerOption', () {
    test('re-reads, then presses the option key', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => _agentList(),
        HerdrMethod.paneList: (_) => _paneList(),
        HerdrMethod.agentSendKeys: (_) => _ok,
      });
      final outcome = await AskController(HerdrClient(daemon)).answerOption(
        before: _row(),
        option: const AgentOption(key: '1', label: 'Yes', isCursor: true),
      );

      expect(outcome, isA<AskAccepted>());
      // The re-read must come FIRST. If it did not, the guard would be judging
      // a state the send had already changed.
      expect(daemon.methods.first, HerdrMethod.agentList);
      expect(daemon.paramsOf(HerdrMethod.agentSendKeys)?['keys'], ['1']);
    });

    test('never sends when the agent moved on', () async {
      // The whole point of the two-phase flow. A stale screen must not produce
      // a keystroke.
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => _agentList(status: 'working', seq: 11),
        HerdrMethod.paneList: (_) => _paneList(),
      });
      final outcome = await AskController(HerdrClient(daemon)).answerOption(
        before: _row(),
        option: const AgentOption(key: '1', label: 'Yes'),
      );

      expect((outcome as AskStale).safety, ReplySafety.noLongerWaiting);
      expect(daemon.sentInput(), isFalse);
    });

    test('never sends when the pane is gone', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) =>
            '{"id":"x","result":{"type":"agent_list","agents":[]}}',
        HerdrMethod.paneList: (_) =>
            '{"id":"x","result":{"type":"pane_list","panes":[]}}',
      });
      final outcome = await AskController(HerdrClient(daemon)).answerOption(
        before: _row(),
        option: const AgentOption(key: '1', label: 'Yes'),
      );

      expect((outcome as AskStale).safety, ReplySafety.gone);
      expect(daemon.sentInput(), isFalse);
    });

    test('an inline y/n carries its return in one call', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => _agentList(),
        HerdrMethod.paneList: (_) => _paneList(),
        HerdrMethod.agentSendKeys: (_) => _ok,
      });
      await AskController(HerdrClient(daemon)).answerOption(
        before: _row(),
        option: const AgentOption(key: 'y', label: 'y', needsEnter: true),
      );

      expect(daemon.paramsOf(HerdrMethod.agentSendKeys)?['keys'], ['y', 'enter']);
    });
  });

  group('answerText routes by the ROW, not by a caller-supplied flag', () {
    test('a blocked agent is TYPED at, never prompted', () async {
      // The bug this test was written for: stock herdr never sends
      // `input_pending`, so a blocked agent with no menu flag was routed to
      // `agent.prompt` — which the daemon refuses with `agent_blocked` and
      // sends nothing. The most important case in the feature failed while
      // looking implemented.
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => _agentList(),
        HerdrMethod.paneList: (_) => _paneList(),
        HerdrMethod.paneSendText: (_) => _ok,
      });
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(status: 'blocked'),
        text: 'use the second option',
      );

      expect(outcome, isA<AskAccepted>());
      expect(daemon.paramsOf(HerdrMethod.paneSendText)?['text'], 'use the second option');
      expect(daemon.methods, isNot(contains(HerdrMethod.agentPrompt)));
    });

    test('a live agent with nothing in the way gets a real prompt', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => _agentList(status: 'blocked'),
        HerdrMethod.paneList: (_) => _paneList(),
        HerdrMethod.agentPrompt: (_) => _prompted,
      });
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(status: 'working'),
        text: 'go ahead',
      );

      expect(outcome, isA<AskAccepted>());
      expect(daemon.paramsOf(HerdrMethod.agentPrompt)?['text'], 'go ahead');
    });

    test('a menu-flagged row is typed at even with a quiet status', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) =>
            '{"id":"x","result":{"type":"agent_list","agents":['
            '{"pane_id":"w1:p1","agent":"claude","agent_status":"working",'
            '"input_pending":true,"state_change_seq":10}]}}',
        HerdrMethod.paneList: (_) => _paneList(),
        HerdrMethod.paneSendText: (_) => _ok,
      });
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(status: 'working', inputPending: true),
        text: 'hello',
      );

      expect(outcome, isA<AskAccepted>());
      expect(daemon.methods, isNot(contains(HerdrMethod.agentPrompt)));
    });

    test('empty text is refused before any traffic', () async {
      final daemon = _FakeDaemon({});
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(),
        text: '  ',
      );

      expect((outcome as AskRefused).reason, ReplyRefusal.empty);
      // Not even the re-read: nothing to send means nothing to check.
      expect(daemon.sent, isEmpty);
    });

    test('a newline into a menu is refused', () async {
      final daemon = _FakeDaemon({});
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(status: 'blocked'),
        text: 'a\nb',
      );

      expect((outcome as AskRefused).reason, ReplyRefusal.multiline);
      expect(daemon.sent, isEmpty);
    });
  });

  group('the daemon gets the last word', () {
    test('agent_blocked comes back as a failure with its code', () async {
      // A federated peer whose real state moved to `last_known_status` reads as
      // needsYou without reading as a menu — so the prompt goes out and the
      // daemon refuses it. The client must report that, not assume success.
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => _agentList(status: 'unknown', lastKnown: 'blocked'),
        HerdrMethod.paneList: (_) => _paneList(),
        HerdrMethod.agentPrompt: (_) => '{"id":"","error":{"code":"agent_blocked",'
            '"message":"agent is blocked and requires interactive input"}}',
      });
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(status: 'unknown', lastKnown: 'blocked'),
        text: 'go',
      );

      expect((outcome as AskFailed).code, 'agent_blocked');
    });

    test('a dead link is a failure, not a silent success', () async {
      final daemon = _FakeDaemon({
        HerdrMethod.agentList: (_) => throw HerdrTransportException(
              TransportFailure.streamClosed,
              'channel closed',
            ),
      });
      final outcome = await AskController(HerdrClient(daemon)).answerText(
        before: _row(),
        text: 'go',
      );

      expect(outcome, isA<AskFailed>());
      expect(daemon.sentInput(), isFalse);
    });
  });
}
