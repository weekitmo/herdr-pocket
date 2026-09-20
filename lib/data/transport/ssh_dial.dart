/// Everything about OPENING an SSH connection, and nothing about what it is
/// opened for.
///
/// WHY THIS FILE EXISTS. There are two things this app reaches over SSH and
/// they are not the same thing: the herdr daemon's Unix socket, and a plain
/// PTY on the host. They disagree about almost everything downstream — one
/// speaks NDJSON and lives as long as the board does, the other carries raw
/// bytes and lives as long as you are looking at the terminal — but they agree
/// completely about how you get onto the machine at all: credentials, ciphers,
/// host-key approval, timeouts.
///
/// So the dial lives here once, and each caller holds its OWN [SSHClient].
/// Sharing one client would tie two unrelated lifetimes together: a shell
/// would die when the board reconnects, and the board would be holding a
/// channel open for a terminal the user closed twenty minutes ago.
///
/// A separate client costs one extra handshake and no extra trust: the host
/// key is already pinned by the time a second connection is opened, so the
/// user is never asked about a machine they have already approved.
library;

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';


/// Credentials for one machine. Never logged; never serialised to disk whole.
class SshCredentials {
  const SshCredentials({
    required this.host,
    required this.username,
    this.port = 22,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.password,
  });

  final String host;
  final String username;
  final int port;

  /// OpenSSH-format private key. Preferred over [password].
  final String? privateKeyPem;
  final String? privateKeyPassphrase;

  /// Only used when no key is supplied.
  final String? password;

  @override
  String toString() => 'SshCredentials($username@$host:$port)';
}

/// The cipher preference list this client connects with.
///
/// WHY THIS IS NOT `const SSHAlgorithms()`. dartssh2's defaults put
/// `aes256-gcm@openssh.com` first, and AES-GCM's GHASH — a carry-less multiply
/// over GF(2^128) — is catastrophically slow in pure Dart. Measured over
/// loopback against OpenSSH 10.2, moving one 48 MiB file:
///
///     aes256-gcm@openssh.com             41.0 s     1.17 MiB/s  (39.1 s of CPU)
///     aes256-ctr                          1.57 s    30.6 MiB/s
///     chacha20-poly1305@openssh.com       1.11 s    43.4 MiB/s
///
/// …while a plain `ssh` binary on the same loopback and the same server moves
/// the same file in 0.41 s. So the default list costs a factor of thirty-seven,
/// and it costs it on EVERY byte this app moves: the terminal stream,
/// `events.subscribe`, and every one-shot request channel all ride this one
/// client. The CPU is the bottleneck, not the link — 39 of those 41 seconds
/// were one core pinned at 100%.
///
/// The fix is a REORDERING, never a removal: every cipher in dartssh2's default
/// list is still here, so no server loses anything it could negotiate before.
/// The order is not a security property — all five are AEAD or encrypt-then-MAC
/// and none of them is the weak one — it decides only how fast the CLIENT's own
/// CPU can decrypt what the server sends.
///
/// chacha20: CTR needs no GHASH, and it measured 26x faster. Legacy CBC modes
/// are deliberately absent, exactly as they are from the default list.
///
/// Reproduce the numbers with `dart run tool/probe_sftp.dart` (and `HP_CIPHERS=`
/// to compare lists without editing this file); the write-up is
/// `docs/research/11-file-transfer-and-pairing.md`.
const List<SSHCipherType> dartsshFastCiphers = [
  SSHCipherType.chacha20poly1305,
  SSHCipherType.aes256ctr,
  SSHCipherType.aes128ctr,
  SSHCipherType.aes256gcm,
  SSHCipherType.aes128gcm,
];

/// The algorithm set handed to every [SSHClient] this app opens.
///
/// Only [SSHAlgorithms.cipher] is overridden; kex, host key and MAC keep
/// dartssh2's defaults, which follow modern OpenSSH and omit the legacy
/// algorithms that need an explicit opt-in.
const SSHAlgorithms herdrSshAlgorithms = SSHAlgorithms(
  cipher: dartsshFastCiphers,
);

/// Decides whether to trust a host key.
///
/// A callback rather than a hard-coded TOFU policy so the policy is testable
/// and so a future "show me the fingerprint and ask" sheet can slot in without
/// touching the transport.
///
/// Returning false for an *unknown* key is a hard refusal; returning false for
/// a *changed* key is a security event, and the transport reports the two
/// differently.
typedef HostKeyVerifier = Future<HostKeyVerdict> Function(HostKeyPrompt prompt);

class HostKeyPrompt {
  const HostKeyPrompt({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.isNewHost,
  });

  final String host;
  final int port;

  /// e.g. `ssh-ed25519`.
  final String keyType;

  /// SHA-256 fingerprint in the usual `SHA256:...` form.
  final String fingerprint;

  /// True when this host has never been approved. False means the key differs
  /// from the stored one — which is a different, louder situation.
  final bool isNewHost;
}

enum HostKeyVerdict {
  /// Store it and continue.
  trust,

  /// Refuse this connection.
  reject,
}

/// The fingerprint, in the form every other SSH tool prints.
///
/// dartssh2 already hands this over as the ASCII bytes of `SHA256:<base64>`,
/// NOT as a raw digest. Base64-encoding it again produces a string that looks
/// plausible and is silently wrong — and the one thing a user does with a
/// fingerprint is compare it against `ssh-keygen -lf` output. A mismatch there
/// reads as "this key is not what I approved", which is the exact alarm
/// pinning exists to raise. A check that reports a wrong value is worse than
/// no check.
///
/// The raw-digest case is still handled, because the callback's contract has
/// changed across versions and a defensive branch is cheaper than another
/// silent mis-display.
///
/// WAS `SshSocketTransport.formatFingerprint`. It moved here when the shell
/// transport arrived, because a fingerprint is a property of the CONNECTION
/// and not of the socket behind it — and two copies of a display format is
/// exactly how one machine's fingerprint ends up disagreeing with the other's.
String formatSshFingerprint(List<int> raw) {
  final asText = String.fromCharCodes(raw);
  if (asText.startsWith('SHA256:') || asText.startsWith('MD5:')) {
    return asText;
  }
  return 'SHA256:${base64.encode(raw).replaceAll('=', '')}';
}

/// Opens one SSH connection. One instance may be dialled more than once, and
/// each [dial] is a FRESH session the caller owns and must close.
class SshDialer {
  const SshDialer({
    required this.credentials,
    required this.verifyHostKey,
    this.connectTimeout = const Duration(seconds: 15),
  });

  final SshCredentials credentials;
  final HostKeyVerifier verifyHostKey;
  final Duration connectTimeout;

  /// Connects, authenticates, and hands back a live client.
  ///
  /// Throws [HerdrTransportException] with a tagged [TransportFailure] for
  /// every way this can go wrong, because the UI has different screens for
  /// "cannot reach the machine" and "the machine said no" and classifying by
  /// matching on error text is how that erodes.
  ///
  /// [onStage] is how the screen learns which of those things is happening
  /// right now. Optional because a caller that has nothing to narrate (a
  /// throwaway connection opened to measure latency) should not have to pass
  /// one.
  Future<SSHClient> dial({void Function(DialStage)? onStage}) async {
    onStage?.call(DialStage.resolving);
    final socket = await SSHSocket.connect(
      credentials.host,
      credentials.port,
      timeout: connectTimeout,
    ).onError<Object>((e, _) {
      throw HerdrTransportException(
        TransportFailure.connectFailed,
        'could not reach ${credentials.host}:${credentials.port}',
        cause: e,
      );
    });

    // The socket is up; everything from here to `authenticated` is the
    // handshake, and on a slow link it is where most of the wait lives.
    onStage?.call(DialStage.dialling);

    final client = SSHClient(
      socket,
      username: credentials.username,
      identities: _identities(),
      onPasswordRequest: credentials.password == null
          ? null
          : () => credentials.password!,
      // The one line that decides whether this connection runs at 43 MiB/s or
      // at 1.2. See [dartsshFastCiphers] — this is not a preference, it is the
      // difference between usable and not.
      algorithms: herdrSshAlgorithms,
      onVerifyHostKey: (keyType, fingerprint) async {
        // Two stages around one await, and both are honest: the first is "a
        // human is being asked" (the verifier only shows a sheet for a key it
        // does not already trust), the second is "the handshake resumed".
        // A pinned host passes through here in milliseconds, which is why a
        // stage is a report rather than a promise about how long it lasts.
        onStage?.call(DialStage.hostKey);
        final verdict = await verifyHostKey(
          HostKeyPrompt(
            host: credentials.host,
            port: credentials.port,
            keyType: keyType,
            fingerprint: formatSshFingerprint(fingerprint),
            // Always false, and always has been. The verifier looks the pin up
            // in its own store and works out "first contact" from that — see
            // `PendingHostKeyPrompt.previous` — so this field is a hint it does
            // not read. Kept for the contract, not for the answer.
            isNewHost: false,
          ),
        );
        onStage?.call(DialStage.dialling);
        return verdict == HostKeyVerdict.trust;
      },
      // Keepalive uses dartssh2's 10 s default deliberately: an idle session
      // must survive a long agent turn without the NAT dropping it, and 10 s
      // is short enough to notice a dead link quickly without being chatty.
      handshakeTimeout: connectTimeout,
      authTimeout: connectTimeout,
    );

    try {
      await client.authenticated;
    } on SSHAuthFailError catch (e) {
      await client.close();
      throw HerdrTransportException(
        TransportFailure.authenticationFailed,
        'authentication failed for ${credentials.username}@${credentials.host}',
        cause: e,
      );
    } on Object catch (e) {
      await client.close();
      throw HerdrTransportException(
        TransportFailure.connectFailed,
        'SSH handshake failed: $e',
        cause: e,
      );
    }

    // AUTHENTICATED: the transport is up and whatever happens next is the
    // daemon's turn. Reported HERE rather than by the caller because the caller
    // cannot see this moment — the session is opened lazily, by the first
    // request it makes.
    onStage?.call(DialStage.verifying);

    return client;
  }

  List<SSHKeyPair>? _identities() {
    final pem = credentials.privateKeyPem;
    if (pem == null || pem.trim().isEmpty) return null;
    try {
      return SSHKeyPair.fromPem(pem, credentials.privateKeyPassphrase);
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.authenticationFailed,
        'the private key could not be parsed',
        cause: e,
      );
    }
  }
}
