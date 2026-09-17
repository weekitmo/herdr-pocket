import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';

/// Regression tests for the host-key fingerprint shown to the user.
///
/// This is worth pinning because the bug it guards against is INVISIBLE in the
/// normal sense: a double-encoded fingerprint renders as a perfectly plausible
/// `SHA256:` string. It only fails when a human does the one thing fingerprints
/// exist for — compares it against `ssh-keygen -lf` — and at that moment the
/// honest reading is "this key is not the one I approved", which is the exact
/// alarm that host-key pinning exists to raise.
///
/// A correctness check that displays a wrong value is worse than no check.
void main() {
  group('host key fingerprints', () {
    test('an already-formatted fingerprint is passed through untouched', () {
      // This is what dartssh2 actually hands the callback: the ASCII bytes of
      // the finished string, not a raw digest. Observed against a live Mac:
      //   app showed  SHA256:U0hBMjU20LdEM3NO...
      //   decoding   SHA256:WD3sN28RskMmEa+RcEgnPs1n66gRTS9MiXOuZ871qco
      //   ssh-keygen SHA256:WD3sN28RskMmEa+RcEgnPs1n66gRTS9MiXOuZ871qco
      const real = 'SHA256:WD3sN28RskMmEa+RcEgnPs1n66gRTS9MiXOuZ871qco';
      final bytes = Uint8List.fromList(utf8.encode(real));

      expect(formatSshFingerprint(bytes), real);
    });

    test('a raw digest is still encoded, so an API change degrades visibly',
        () {
      // dartssh2's callback contract has changed across versions. If it ever
      // hands over raw bytes again, this branch produces the right string
      // rather than a mangled one.
      final raw = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final formatted = formatSshFingerprint(raw);

      expect(formatted, startsWith('SHA256:'));
      expect(formatted, isNot(contains('=')));
      // A 32-byte digest is 43 base64 characters without padding.
      expect(formatted.substring('SHA256:'.length).length, 43);
    });

    test('the two paths cannot produce the same output for the same input',
        () {
      // Guards the shape of the bug directly: encoding an already-encoded value
      // yields something twice as long, which is what made the wrong value look
      // plausible rather than obviously broken.
      const real = 'SHA256:WD3sN28RskMmEa+RcEgnPs1n66gRTS9MiXOuZ871qco';
      final right = formatSshFingerprint(
        Uint8List.fromList(utf8.encode(real)),
      );
      final wrong = 'SHA256:'
          '${base64.encode(utf8.encode(real)).replaceAll('=', '')}';

      expect(right, isNot(wrong));
      expect(right.length, lessThan(wrong.length));
    });

    test('an MD5 fingerprint is not re-encoded either', () {
      const legacy = 'MD5:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99';
      final bytes = Uint8List.fromList(utf8.encode(legacy));
      expect(formatSshFingerprint(bytes), legacy);
    });
  });
}
