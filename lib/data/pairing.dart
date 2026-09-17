import 'dart:async';
import 'dart:convert';

import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/host_store.dart';
import 'package:herdr_pocket/data/phone_identity.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';
import 'package:herdr_pocket/domain/pairing/pairing_ticket.dart';

/// What `hdp __exchange` prints when the key was installed.
///
/// MUST MATCH `exchangeOK` in `cli/hdp/main.go`. It is the only thing standing
/// between "the phone's key is on the host" and "the command ran and said
/// something": a `cat` of an empty file, a shell error from a broken forced
/// command, and a successful exchange all return exit 0, and only this string
/// tells them apart.
const exchangeOkMarker = 'HDP-EXCHANGE-OK';

/// Why pairing did not finish.
enum PairingFailure {
  /// The host could not be reached at all.
  unreachable,

  /// The server's host key is not the one the pairing string pinned.
  ///
  /// The serious one. Either the code was scanned from a different machine, or
  /// something is sitting in the middle of the connection — and both look
  /// identical from here, so neither is assumed.
  hostKeyMismatch,

  /// The bootstrap key was rejected: the window closed, or `hdp pair` was
  /// cancelled, or the key is not the one on the host any more.
  bootstrapRejected,

  /// The forced command ran but did not report success — the host's `hdp` is
  /// missing, or the version is too old to have an exchange command.
  exchangeFailed,

  /// The key was installed, but a connection using it did not work. The
  /// exchange claimed success and was wrong, which is worth its own case
  /// because it is the only failure where the host's state is now unknown.
  verifyFailed,

  /// Anything else, with the detail kept for diagnostics.
  unknown,
}

class PairingException implements Exception {
  const PairingException(this.reason, {this.detail});

  final PairingFailure reason;
  final String? detail;

  @override
  String toString() =>
      'PairingException(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// What pairing produced.
///
/// A [HostProfile] plus the identity, ready to be written to the keystore and
/// the machine list. Returned rather than saved, so the flow can be tested
/// without a keystore and so the caller decides when the credentials become
/// real — a half-finished pairing that has already overwritten a working
/// machine's key is much worse than one that saved nothing.
class PairingResult {
  const PairingResult({
    required this.profile,
    required this.identity,
    required this.hostKey,
  });

  final HostProfile profile;
  final PhoneIdentity identity;

  /// The host key to pin, as the app stores it.
  final HostKeyRecord hostKey;
}

/// Runs the phone's half of `hdp pair`.
///
/// ## The sequence, and why it is two connections and not one
///
/// ```text
///   connect with the bootstrap key      (restrict,command="hdp __exchange")
///     └─ send our public key on stdin, read back HDP-EXCHANGE-OK
///   connect with OUR OWN key            (a normal, unrestricted login)
///     └─ run `echo`, to prove the thing we just installed actually works
/// ```
///
/// The second connection is not a formality. The exchange can only report that
/// it APPENDED a line; whether sshd will accept that line is a different
/// question — wrong permissions on `~/.ssh`, a comment field that got mangled,
/// a key type the server has disabled. Saving a machine that cannot connect
/// means the user finds out the next time they open the app, with no way to tell
/// what went wrong.
///
/// Both connections pin the host key from the pairing string, so neither is
/// subject to a trust-on-first-use prompt: the fingerprint arrived out of band,
/// and a mismatch is a hard refusal rather than a question.
class PairingFlow {
  /// Holds the pieces pairing needs, so the whole flow can be driven in a test.
  const PairingFlow({
    required this.connect,
    this.timeout = const Duration(seconds: 20),
  });

  /// Opens a transport for the given credentials.
  ///
  /// Injected rather than constructed here: the real one opens TCP sockets, and
  /// a test that wants to prove the exchange handshake works should not need a
  /// network to do it.
  final SshSocketTransport Function({
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
  }) connect;

  final Duration timeout;

  /// Pairs with the machine described by [ticket].
  Future<PairingResult> run(
    PairingTicket ticket, {
    PhoneIdentity? identity,
    String? label,
  }) async {
    final phone = identity ?? PhoneIdentity.generate(label: label);

    // EVERY connection in this flow trusts exactly one key: the one the pairing
    // string named. Not "the one we saw last time" — there is no last time, and
    // answering yes here would make the fingerprint in the QR code decorative.
    HostKeyVerifier pinner(String expected) =>
        (prompt) async => prompt.fingerprint == expected
            ? HostKeyVerdict.trust
            : HostKeyVerdict.reject;

    // ---------------------------------------------------------- exchange ---
    final bootstrap = _transportFor(
      ticket: ticket,
      // Rebuilt from the seed the pairing string carries — see
      // [openSshEd25519PrivateKeyFromSeed] for why it is not sent ready-made.
      privateKeyPem: openSshEd25519PrivateKeyFromSeed(ticket.bootstrapSeed),
      verifyHostKey: pinner(ticket.hostKeyFingerprint),
    );

    try {
      final duplex = await bootstrap
          .openCommandDuplex('hdp __exchange')
          .timeout(timeout)
          .onError<Object>((e, _) => throw _classify(e, phase: _Phase.connect));

      // What we send is the whole authorized_keys line, comment included. The
      // `hdp-pocket` marker in that comment is not decoration: the waiting
      // `hdp pair` on the host polls its authorized_keys file for exactly that
      // string to decide the phone has arrived. Send the bare key instead and
      // the exchange still succeeds — and pairing times out anyway, which is
      // the hardest version of this bug to read.
      duplex.send(phone.authorizedKeyLine);

      final answer = await duplex.lines
          .firstWhere((line) => line.trim().isNotEmpty)
          .timeout(timeout)
          .onError<Object>((e, _) => throw _classify(e, phase: _Phase.exchange));

      if (!answer.contains(exchangeOkMarker)) {
        throw PairingException(
          PairingFailure.exchangeFailed,
          detail: 'the host said: $answer',
        );
      }
    } finally {
      await bootstrap.close();
    }

    // ------------------------------------------------------------ verify ---
    //
    // A SECOND connection with a different key, and the two must not share a
    // client: the bootstrap session was authenticated as a restricted forced
    // command, and reusing it would prove nothing about the key we just
    // installed.
    final own = _transportFor(
      ticket: ticket,
      privateKeyPem: phone.privateKeyPem,
      verifyHostKey: pinner(ticket.hostKeyFingerprint),
    );

    try {
      final output = await own
          .runCommand('echo $exchangeOkMarker')
          .timeout(timeout)
          .onError<Object>((e, _) => throw _classify(e, phase: _Phase.verify));
      if (!output.contains(exchangeOkMarker)) {
        throw const PairingException(
          PairingFailure.verifyFailed,
          detail: 'the new key authenticated but the command did not run',
        );
      }
    } finally {
      await own.close();
    }

    return PairingResult(
      profile: HostProfile(
        id: 'pair-${ticket.host}-${ticket.port}-${ticket.user}',
        label: ticket.displayName,
        host: ticket.host,
        port: ticket.port,
        username: ticket.user,
        // No socket path, deliberately: it is resolved on the first real
        // connection by asking the host, exactly as a manually added machine
        // is. Guessing it here would bake in a default that a machine with
        // `XDG_CONFIG_HOME` set does not use, and the failure would surface as
        // "herdr is not running" on a machine where it plainly is.
      ),
      identity: phone,
      hostKey: HostKeyRecord(
        keyType: 'ssh-ed25519',
        fingerprint: ticket.hostKeyFingerprint,
        approvedAt: DateTime.now(),
      ),
    );
  }

  SshSocketTransport _transportFor({
    required PairingTicket ticket,
    required String privateKeyPem,
    required HostKeyVerifier verifyHostKey,
  }) =>
      connect(
        credentials: SshCredentials(
          host: ticket.host,
          port: ticket.port,
          username: ticket.user,
          privateKeyPem: privateKeyPem,
        ),
        verifyHostKey: verifyHostKey,
      );

  /// Turns a transport failure into a pairing failure.
  ///
  /// Classified rather than passed through, because the three that matter are
  /// indistinguishable to a user and completely different to fix: an unreachable
  /// host, an expired code, and a pinned key that did not match.
  PairingException _classify(Object error, {required _Phase phase}) {
    if (error is PairingException) return error;
    if (error is TimeoutException) {
      return PairingException(
        phase == _Phase.verify
            ? PairingFailure.verifyFailed
            : PairingFailure.unreachable,
        detail: 'timed out after ${timeout.inSeconds}s',
      );
    }
    if (error is HerdrTransportException) {
      return switch (error.failure) {
        TransportFailure.hostKeyChanged ||
        TransportFailure.hostKeyUnknown =>
          PairingException(
            PairingFailure.hostKeyMismatch,
            detail: error.message,
          ),
        TransportFailure.authenticationFailed => PairingException(
            phase == _Phase.verify
                ? PairingFailure.verifyFailed
                : PairingFailure.bootstrapRejected,
            detail: error.message,
          ),
        TransportFailure.connectFailed => PairingException(
            PairingFailure.unreachable,
            detail: error.message,
          ),
        _ => PairingException(
            PairingFailure.unknown,
            detail: '${error.failure.name}: ${error.message}',
          ),
      };
    }
    return PairingException(PairingFailure.unknown, detail: '$error');
  }
}

/// Which half of the flow a failure came from, so the same exception can be
/// classified differently depending on where it was seen.
enum _Phase { connect, exchange, verify }

/// The real transport factory, for the app.
///
/// The socket path is deliberately a path that is never dialled: pairing uses
/// command channels only, and a wrong-but-plausible value here would silently
/// open a forwarding channel that nothing reads.
SshSocketTransport pairingTransport({
  required SshCredentials credentials,
  required HostKeyVerifier verifyHostKey,
}) =>
    SshSocketTransport(
      credentials: credentials,
      socketPath: '',
      verifyHostKey: verifyHostKey,
    );

/// Encodes a pairing string for display in diagnostics, with the key removed.
///
/// Exists so a support message can quote what was scanned without quoting the
/// credential inside it.
String describeTicketForDiagnostics(Map<String, Object?> payload) =>
    jsonEncode({...payload, 'k': '<redacted>', 'f': '<redacted>'});
