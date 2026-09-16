import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/transport/unix_socket_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// Integration tests against a LIVE herdr daemon.
///
/// These exist because a protocol layer verified only against hand-written
/// fixtures agrees with the fixtures and not necessarily with the server. Every
/// non-obvious thing this client does — `params` always present, one channel
/// per request, error envelopes with an empty id, source drift in
/// `agent.list` — was learned from the real daemon, so the real daemon is what
/// verifies it.
///
/// The whole file skips when no socket is present, so CI without herdr is not
/// broken by it.
///
/// READ-ONLY BY CONSTRUCTION: only `ping`, `agent.list` and `pane.list` are
/// called. Nothing here sends input to, or changes the state of, a running
/// agent.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final socketPath = '$home/.config/herdr/herdr.sock';
  final socketExists = File(socketPath).existsSync();

  final skipReason = socketExists
      ? null
      : 'no herdr socket at $socketPath (skipping live tests)';

  HerdrClient client() =>
      HerdrClient(UnixSocketTransport(socketPath: socketPath));

  group('live herdr', () {
    test('ping reports a version and a protocol number', () async {
      final c = client();
      addTearDown(c.close);

      final hello = await c.ping();
      expect(hello.version, isNotEmpty, reason: 'version came back empty');
      expect(hello.protocol, greaterThan(0));
      // The live version banner is the whole point of running this against a
      // real daemon, so printing it is intentional.
      print('  live herdr: ${hello.version} protocol ${hello.protocol}');
    }, skip: skipReason);

    test('agent.list decodes into domain rows', () async {
      final c = client();
      addTearDown(c.close);

      final agents = await c.agentList();
      for (final a in agents) {
        expect(a.paneId, isNotEmpty, reason: 'a row without a pane id');
        // Whatever the daemon sent, it must map to a status without throwing —
        // including states this build has never heard of.
        expect(AgentStatus.fromWire(a.agentStatus), isA<AgentStatus>());
      }
      print('  live agents: ${agents.length}');
    }, skip: skipReason);

    test('the board composes without error', () async {
      final c = client();
      addTearDown(c.close);

      final board = await c.board();
      // Sections are ordered by the fail-closed rank, and every row lands in
      // exactly one of them.
      final sectioned = board.sections.expand((s) => s.rows).length;
      expect(sectioned, board.rows.length);
      for (var i = 1; i < board.sections.length; i++) {
        expect(
          board.sections[i].group.rank,
          greaterThan(board.sections[i - 1].group.rank),
          reason: 'sections must be in rank order',
        );
      }
    }, skip: skipReason);

    test('many sequential requests all succeed on a single-shot socket',
        () async {
      // The daemon accepts ONE request per connection and then closes. If the
      // transport ever reused a channel, the second call here would fail —
      // which is precisely the bug this asserts against.
      final c = client();
      addTearDown(c.close);

      for (var i = 0; i < 5; i++) {
        final hello = await c.ping();
        expect(hello.protocol, greaterThan(0), reason: 'request #$i failed');
      }
    }, skip: skipReason);

    test('an unsupported method surfaces as a typed API error', () async {
      final c = client();
      addTearDown(c.close);

      await expectLater(
        c.supports('definitely.not.a.method'),
        completion(isFalse),
      );
    }, skip: skipReason);

    test('the fork-only pane.stream is correctly reported as unsupported',
        () async {
      // Guards the architectural decision: we target UPSTREAM herdr, and
      // `pane.stream` exists only in jerryfane/herdr. If this ever returns
      // true, the daemon changed and the terminal plan is worth revisiting.
      final c = client();
      addTearDown(c.close);

      final supported = await c.supports('pane.stream', {'pane_id': 'w1:p1'});
      expect(
        supported,
        isFalse,
        reason: 'pane.stream answered — is this a fork daemon?',
      );
    }, skip: skipReason);

    test('an error envelope with an empty id still decodes', () {
      // The daemon does not echo the request id on errors, so correlation must
      // come from the connection, not the id.
      final reply = HerdrReply.decode(
        '{"id":"","error":{"code":"invalid_request","message":"nope"}}',
      );
      expect(reply, isA<HerdrFailure>());
      expect((reply as HerdrFailure).id, isEmpty);
    });

    test('an unknown method is recognised by the phrase, not the code',
        () async {
      // Goes through the transport directly rather than HerdrClient.supports,
      // because supports() deliberately swallows the error to answer a boolean.
      final t = UnixSocketTransport(socketPath: socketPath);
      addTearDown(t.close);

      final line = await t.roundTrip(
        HerdrRequest('definitely.not.a.method').encode('probe'),
      );
      final reply = HerdrReply.decode(line);
      expect(reply, isA<HerdrFailure>());

      final failure = reply as HerdrFailure;
      final api = HerdrApiException(code: failure.code, message: failure.message);

      // The code is `invalid_request`, which is ALSO what a valid method with
      // bad arguments returns. Only the message distinguishes them.
      expect(api.code, 'invalid_request');
      expect(api.isUnknownMethod, isTrue);
      // Free capability listing: the message enumerates every valid method.
      expect(api.knownMethods, isNotEmpty);
      expect(api.knownMethods, contains('agent.list'));
      print('  daemon reports ${api.knownMethods.length} methods');
    }, skip: skipReason);

    test('agent.read returns the screen the question parser reads', () async {
      final c = client();
      addTearDown(c.close);

      final agents = await c.agentList();
      if (agents.isEmpty) {
        print('  no agents running; agent.read not exercised');
        return;
      }

      // READING ONLY. `agent.read` never sends input and never clears a
      // completion — that is `agent.focus`, which this test deliberately does
      // not call.
      final read = await c.agentRead(target: agents.first.paneId);

      expect(read.paneId, agents.first.paneId);
      expect(read.lines.length, read.text.isEmpty ? 0 : greaterThan(0));

      // The shape that makes the approval feature need a parser instead of a
      // label: for a TUI agent the tail of this text is the agent's own status
      // bar, not its message. Printing it here is the evidence for that claim.
      print('  read ${read.text.length} chars, truncated=${read.truncated}');
      print('  last line: ${read.lines.isEmpty ? '(none)' : read.lines.last}');
    }, skip: skipReason);

    test('agent.read accepts an explicit line count', () async {
      final c = client();
      addTearDown(c.close);

      final agents = await c.agentList();
      if (agents.isEmpty) {
        print('  no agents running; line-limited read not exercised');
        return;
      }

      final read = await c.agentRead(target: agents.first.paneId, lines: 6);
      expect(read.lines.length, lessThanOrEqualTo(6));
    }, skip: skipReason);
  });
}
