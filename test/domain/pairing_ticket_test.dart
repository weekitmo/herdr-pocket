import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/pairing/pairing_ticket.dart';

/// Tests for the one parser behind both doors.
///
/// The scan and the paste produce the same bytes — that is the whole reason
/// there is one of these — so every case here is a case that would otherwise
/// have to be got right twice, and would be got right once.
void main() {
  /// A payload shaped exactly like the one `hdp pair` prints.
  String encode({
    int version = pairingProtocolVersion,
    String host = '10.0.0.2',
    int port = 22,
    String user = 'you',
    // base64 of the 32 bytes 0x00..0x1f — a valid ed25519 seed, and what
    // `hdp pair` now puts in the payload. Written out rather than computed
    // because a default value has to be a constant expression.
    String key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
    String fingerprint = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
    String? name = 'Mac mini',
    Map<String, Object?> extra = const {},
  }) {
    final map = <String, Object?>{
      'v': version,
      'h': host,
      'p': port,
      'u': user,
      'k': key,
      'f': fingerprint,
      if (name != null) 'n': name,
      ...extra,
    };
    return base64Url.encode(utf8.encode(jsonEncode(map))).replaceAll('=', '');
  }

  group('a good string', () {
    test('decodes every field', () {
      final ticket = parsePairingString(encode());

      expect(ticket.host, '10.0.0.2');
      expect(ticket.port, 22);
      expect(ticket.user, 'you');
      expect(ticket.name, 'Mac mini');
      expect(ticket.bootstrapSeed.length, ed25519SeedBytes);
      expect(ticket.hostKeyFingerprint, startsWith('SHA256:'));
      expect(ticket.displayName, 'Mac mini');
    });

    test('falls back to the address when there is no name', () {
      final ticket = parsePairingString(encode(name: null));
      expect(ticket.name, isNull);
      expect(
        ticket.displayName,
        '10.0.0.2',
        reason: 'a row has to say something, and the address is what the user '
            'typed into the other end',
      );
    });

    test('survives the way a paste actually arrives', () {
      final encoded = encode();

      // Wrapped at 72 columns — which is how `hdp pair` prints it, so this is
      // the shape a real copy-out-of-the-terminal produces.
      final wrapped = StringBuffer();
      for (var i = 0; i < encoded.length; i++) {
        if (i > 0 && i % 72 == 0) wrapped.write('\n  ');
        wrapped.write(encoded[i]);
      }

      // HOW MUCH PADDING THIS FIXTURE ACTUALLY NEEDS, computed rather than
      // written as a literal `==`. A base64url string of length L needs
      // `(4 - L % 4) % 4` of them, and that number depends on the LENGTH of the
      // payload — so a fixture that happens to need two makes a hard-coded `==`
      // pass for the wrong reason. This one did exactly that until the example
      // host and user in the fixture got shorter, at which point the case
      // started testing "reject a malformed string" instead of "accept a
      // re-padded one".
      final pad = (4 - encoded.length % 4) % 4;

      for (final variant in {
        'as printed': wrapped.toString(),
        'trailing newline': '$encoded\n',
        'surrounded by spaces': '  $encoded  ',
        'windows line endings': '${encoded.substring(0, 40)}\r\n${encoded.substring(40)}',
        'padded': '$encoded${'=' * pad}',
        'non-breaking space': '${encoded.substring(0, 20)}\u00a0${encoded.substring(20)}',
      }.entries) {
        expect(
          () => parsePairingString(variant.value),
          returnsNormally,
          reason: 'a paste arriving as "${variant.key}" must work — refusing it '
              'would be refusing the exact use the paste path exists for',
        );
      }
    });
  });

  group('a bad string', () {
    test('empty is its own reason, not "malformed"', () {
      for (final input in ['', '   ', '\n\t ']) {
        expect(
          () => parsePairingString(input),
          throwsA(
            isA<PairingParseException>().having(
              (e) => e.reason,
              'reason',
              PairingParseFailure.empty,
            ),
          ),
        );
      }
    });

    test('not base64 at all', () {
      expect(
        () => parsePairingString('this is not a pairing string!'),
        throwsA(
          isA<PairingParseException>().having(
            (e) => e.reason,
            'reason',
            PairingParseFailure.malformed,
          ),
        ),
      );
    });

    test('valid base64 that is not a payload', () {
      final junk = base64Url.encode(utf8.encode('hello')).replaceAll('=', '');
      expect(() => parsePairingString(junk), throwsA(isA<PairingParseException>()));
    });

    test('a NEWER version says so, rather than "invalid"', () {
      // The user is holding a perfectly valid string produced by a newer hdp.
      // Telling them it is invalid sends them to look at the string.
      final future = encode(version: pairingProtocolVersion + 1);
      expect(
        () => parsePairingString(future),
        throwsA(
          isA<PairingParseException>()
              .having((e) => e.reason, 'reason', PairingParseFailure.unsupported)
              // The detail names BOTH numbers, so a support thread can tell
              // which end is behind without asking.
              .having((e) => e.detail, 'detail', contains('protocol ${pairingProtocolVersion + 1}')),
        ),
      );
    });

    test('each missing field is caught', () {
      final cases = {
        'host': encode(host: ''),
        'user': encode(user: ''),
        'key': encode(key: ''),
        'fingerprint': encode(fingerprint: ''),
        'port': encode(port: 0),
        'port out of range': encode(port: 70000),
      };
      for (final entry in cases.entries) {
        expect(
          () => parsePairingString(entry.value),
          throwsA(
            isA<PairingParseException>().having(
              (e) => e.reason,
              'reason',
              anyOf(PairingParseFailure.incomplete, PairingParseFailure.malformed),
            ),
          ),
          reason: 'a payload with no ${entry.key} must not reach the flow',
        );
      }
    });

    test('a fingerprint that is not SHA256 is refused', () {
      // It would never match a real one, and the failure it produces — "the
      // host key changed" on a machine nobody touched — is the loudest alarm
      // this app has. Better to refuse the payload that cannot be true.
      expect(
        () => parsePairingString(encode(fingerprint: 'MD5:aa:bb')),
        throwsA(
          isA<PairingParseException>().having(
            (e) => e.reason,
            'reason',
            PairingParseFailure.incomplete,
          ),
        ),
      );
    });
  });

  test('the ticket never prints its key', () {
    // A `PairingTicket` in a log or an error message must not be a private key
    // in a log or an error message.
    final ticket = parsePairingString(encode());
    expect(ticket.toString(), isNot(contains('BEGIN OPENSSH')));
    expect(ticket.toString(), isNot(contains('abc')));
    expect(ticket.toString(), contains('you@10.0.0.2:22'));
  });
}
