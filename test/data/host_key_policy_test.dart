import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/host_store.dart';

/// Tests for the host-key pinning POLICY.
///
/// The policy is the part that decides whether a connection proceeds, so it is
/// kept pure — no keystore, no socket, no UI — precisely so it can be tested
/// here. Everything below is a way the "trust on first use" rule could be got
/// wrong in a manner that looks like it works.
void main() {
  /// A store that answers from memory, so the policy can be exercised without
  /// touching the platform keystore.
  HostKeyStore fakeStore(Map<String, HostKeyRecord> pins) =>
      _FakeHostKeyStore(pins);

  HostKeyRecord record(String fingerprint, {String type = 'ssh-ed25519'}) =>
      HostKeyRecord(
        keyType: type,
        fingerprint: fingerprint,
        approvedAt: DateTime(2026),
      );

  group('first contact', () {
    test('an unseen host is UNKNOWN, not changed and not trusted', () async {
      final result = await checkHostKey(
        fakeStore(const {}),
        pinKey: 'host:22',
        presentedType: 'ssh-ed25519',
        presentedFingerprint: 'SHA256:aaa',
      );
      // The distinction matters: calling this "changed" would cry wolf on every
      // first connection and train the user to dismiss the warning that is
      // supposed to stop an interception.
      expect(result.verdict, HostKeyPinVerdict.unknown);
      expect(result.pinned, isNull);
    });
  });

  group('a matching pin', () {
    test('is trusted without asking', () async {
      final result = await checkHostKey(
        fakeStore({'host:22': record('SHA256:aaa')}),
        pinKey: 'host:22',
        presentedType: 'ssh-ed25519',
        presentedFingerprint: 'SHA256:aaa',
      );
      expect(result.verdict, HostKeyPinVerdict.trusted);
      expect(result.pinned?.fingerprint, 'SHA256:aaa');
    });

    test('a different KEY TYPE with the same fingerprint is not trusted',
        () async {
      // A fingerprint alone is not the identity — the key type is part of it.
      // Comparing only the fingerprint would treat an ed25519 key and an RSA
      // key that happen to hash the same as the same machine.
      final result = await checkHostKey(
        fakeStore({'host:22': record('SHA256:aaa')}),
        pinKey: 'host:22',
        presentedType: 'ssh-rsa',
        presentedFingerprint: 'SHA256:aaa',
      );
      expect(result.verdict, HostKeyPinVerdict.changed);
    });
  });

  group('a changed key', () {
    test('is CHANGED and reports what it changed from', () async {
      final result = await checkHostKey(
        fakeStore({'host:22': record('SHA256:old')}),
        pinKey: 'host:22',
        presentedType: 'ssh-ed25519',
        presentedFingerprint: 'SHA256:new',
      );
      expect(result.verdict, HostKeyPinVerdict.changed);
      // The old value has to come back, because "it changed" without showing
      // what it changed FROM gives the user nothing to check against.
      expect(result.pinned?.fingerprint, 'SHA256:old');
    });

    test('is never silently accepted', () async {
      final result = await checkHostKey(
        fakeStore({'host:22': record('SHA256:old')}),
        pinKey: 'host:22',
        presentedType: 'ssh-ed25519',
        presentedFingerprint: 'SHA256:new',
      );
      expect(result.verdict, isNot(HostKeyPinVerdict.trusted));
    });
  });

  group('pins are per-host', () {
    test('one host pinning a key does not trust another host', () async {
      final result = await checkHostKey(
        fakeStore({'a:22': record('SHA256:aaa')}),
        pinKey: 'b:22',
        presentedType: 'ssh-ed25519',
        presentedFingerprint: 'SHA256:aaa',
      );
      // Same fingerprint, different machine. If the pin key were just the
      // fingerprint, connecting to a second machine that reuses a key would
      // inherit the first machine's trust.
      expect(result.verdict, HostKeyPinVerdict.unknown);
    });

    test('the same host on two ports is two identities', () async {
      final result = await checkHostKey(
        fakeStore({'host:22': record('SHA256:aaa')}),
        pinKey: 'host:2222',
        presentedType: 'ssh-ed25519',
        presentedFingerprint: 'SHA256:aaa',
      );
      expect(result.verdict, HostKeyPinVerdict.unknown);
    });
  });
}

/// In-memory [HostKeyStore].
class _FakeHostKeyStore implements HostKeyStore {
  _FakeHostKeyStore(this._pins);

  final Map<String, HostKeyRecord> _pins;

  @override
  Future<HostKeyRecord?> read(String pinKey) async => _pins[pinKey];

  @override
  Future<void> save(String pinKey, HostKeyRecord record) async {
    _pins[pinKey] = record;
  }

  @override
  Future<void> forget(String pinKey) async {
    _pins.remove(pinKey);
  }
}
