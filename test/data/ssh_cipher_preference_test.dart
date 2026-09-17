import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';

/// Tests for the SSH **cipher preference order**.
///
/// This looks like a test of a constant, and it is — but the constant is a
/// performance decision with a measured factor of thirty-seven behind it, and
/// the way it fails is silent: put `aes256-gcm` back at the front and the app
/// still connects, still authenticates, still passes every other test. It is
/// just thirty-seven times slower on every byte, which no assertion anywhere
/// else in this suite can see.
///
/// So the assertions below are written against the REASON, not against the
/// list. They do not care which ciphers are present beyond "all of them", and
/// they do not care about the exact order — only that nothing slow is preferred
/// over something fast, and that nothing was dropped.
void main() {
  /// The ciphers whose cost is a carry-less multiply in pure Dart.
  const ghash = {SSHCipherType.aes128gcm, SSHCipherType.aes256gcm};

  group('the reordering', () {
    test('keeps every cipher dartssh2 offers by default', () {
      // The change is a permutation, and this is what makes that claim
      // checkable. Dropping `aes128gcm` because it is slow would be a
      // compatibility change dressed up as a performance one: a server that
      // offers ONLY that cipher would stop connecting, and the failure would
      // look like "herdr-pocket cannot reach my machine".
      final defaults = const SSHAlgorithms().cipher.toSet();
      final ours = herdrSshAlgorithms.cipher.toSet();

      expect(
        ours,
        containsAll(defaults),
        reason: 'the preference list must never remove a cipher dartssh2 '
            'supports — reordering is the fix, removal is a regression',
      );
    });

    test('prefers nothing that needs GHASH over something that does not', () {
      final list = herdrSshAlgorithms.cipher;
      final firstNonGhash = list.indexWhere((c) => !ghash.contains(c));

      expect(
        firstNonGhash,
        isNot(-1),
        reason: 'a list made only of GHASH ciphers is the slow configuration '
            'this constant exists to avoid',
      );

      for (final slow in ghash) {
        final at = list.indexOf(slow);
        if (at == -1) continue;
        expect(
          at,
          greaterThan(firstNonGhash),
          reason: '${slow.name} is preferred over ${list[firstNonGhash].name}. '
              'GHASH in pure Dart measured 1.17 MiB/s against 43.4 for '
              'chacha20-poly1305 and 30.6 for aes-ctr on the same link, so '
              'anything without GHASH must come first. See '
              'docs/research/11-file-transfer-and-pairing.md.',
        );
      }
    });

    test('the transport actually connects with it', () {
      // The constant is only worth anything if it reaches SSHClient. This is
      // the assertion that ties the value to the call site, because a test on
      // the constant alone would keep passing after someone deleted the
      // `algorithms:` argument.
      expect(identical(herdrSshAlgorithms.cipher, dartsshFastCiphers), isTrue);
      expect(herdrSshAlgorithms.cipher.first, SSHCipherType.chacha20poly1305);
    });
  });
}
