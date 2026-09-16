import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';

void main() {
  group('request encoding', () {
    test('params is always present, even when empty', () {
      // Measured behaviour: the daemon rejects a request without `params`.
      final encoded = HerdrRequest(HerdrMethod.agentList).encode('req1');
      expect(encoded, contains('"params"'));
      expect(encoded, contains('"method":"agent.list"'));
      expect(encoded, contains('"id":"req1"'));
    });

    test('params survive encoding', () {
      final encoded =
          HerdrRequest(HerdrMethod.paneRead, {'pane_id': 'w1:p1', 'lines': 50})
              .encode('r2');
      expect(encoded, contains('"pane_id":"w1:p1"'));
      expect(encoded, contains('"lines":50'));
    });
  });

  group('reply decoding', () {
    test('a success carries its result type', () {
      final reply = HerdrReply.decode(
        '{"id":"r1","result":{"type":"agent_list","agents":[]}}',
      );
      expect(reply, isA<HerdrSuccess>());
      final ok = reply as HerdrSuccess;
      expect(ok.id, 'r1');
      expect(ok.resultType, 'agent_list');
    });

    test('an error envelope decodes even though id is empty', () {
      // Measured: the daemon does NOT echo the request id on errors. Code that
      // correlated replies by id would hang here.
      final reply = HerdrReply.decode(
        '{"id":"","error":{"code":"unknown_method","message":"unknown method"}}',
      );
      expect(reply, isA<HerdrFailure>());
      final err = reply as HerdrFailure;
      expect(err.id, isEmpty);
      expect(err.code, 'unknown_method');
    });

    test('an error without a well-formed code still decodes', () {
      final reply = HerdrReply.decode('{"id":"","error":{"message":"boom"}}');
      expect((reply as HerdrFailure).code, 'unknown');
    });

    test('a non-JSON line is a protocol error, not a silent null', () {
      expect(
        () => HerdrReply.decode('not json at all'),
        throwsA(isA<HerdrProtocolException>()),
      );
    });

    test('a JSON array is not a reply', () {
      expect(
        () => HerdrReply.decode('[]'),
        throwsA(isA<HerdrProtocolException>()),
      );
    });
  });

  group('feature detection', () {
    // The real error, captured from a live herdr 0.9.0 (protocol 22).
    const unknownVariantJson = '{"id":"","error":{"code":"invalid_request",'
        '"message":"invalid request: unknown variant `pane.stream`, expected '
        'one of `ping`, `server.stop`, `agent.list`"}}';

    test('an unknown method is detected by the message phrase', () {
      final reply = HerdrReply.decode(unknownVariantJson) as HerdrFailure;
      final e = HerdrApiException(code: reply.code, message: reply.message);
      expect(e.isUnknownMethod, isTrue);
    });

    test('the error CODE alone is not enough to conclude "unsupported"', () {
      // `invalid_request` is what the daemon returns for a VALID method called
      // with bad arguments too. Keying on the code would report every argument
      // error as a missing feature — which is exactly the bug this replaced.
      final e = HerdrApiException(
        code: 'invalid_request',
        message: 'invalid request: cols and rows must be greater than 0',
      );
      expect(e.isUnknownMethod, isFalse);
    });

    test('the daemon hands back a free capability listing', () {
      final reply = HerdrReply.decode(unknownVariantJson) as HerdrFailure;
      final e = HerdrApiException(code: reply.code, message: reply.message);
      expect(e.knownMethods, contains('ping'));
      expect(e.knownMethods, contains('agent.list'));
      expect(e.knownMethods, isNot(contains('pane.stream')));
    });

    test('knownMethods is empty for an ordinary error', () {
      final e = HerdrApiException(code: 'invalid_params', message: 'bad cols');
      expect(e.knownMethods, isEmpty);
    });

    test('an unrelated error is not mistaken for an unsupported feature', () {
      final e = HerdrApiException(code: 'invalid_params', message: 'bad cols');
      expect(e.isUnknownMethod, isFalse);
    });
  });
}
