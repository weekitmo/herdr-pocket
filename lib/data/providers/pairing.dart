import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/pairing.dart';
import 'package:herdr_pocket/data/phone_identity.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/domain/pairing/pairing_ticket.dart';

/// Where a pairing has got to.
///
/// The steps are named rather than a fraction, because the three phases take
/// wildly different amounts of time — a key exchange is milliseconds, the
/// exchange command waits on the host's `hdp` to notice a file changed — and a
/// spinner that says nothing for four seconds reads as a hang.
sealed class PairingUiState {
  const PairingUiState();
}

/// Nothing has been attempted, or the last result was cleared.
class PairingIdle extends PairingUiState {
  /// The one idle state.
  const PairingIdle();
}

/// A pairing is in flight.
class PairingWorking extends PairingUiState {
  /// Holds one step.
  const PairingWorking(this.step, {this.host});

  final PairingStep step;

  /// Set once the string parsed, so the screen can name the machine while it
  /// is being contacted. Before that there is nothing truthful to show.
  final String? host;
}

/// Which of the three phases is running.
enum PairingStep { connect, exchange, verify }

/// It worked.
class PairingSucceeded extends PairingUiState {
  /// Holds the machine that was paired.
  const PairingSucceeded({required this.profile});

  final HostProfile profile;
}

/// It did not, and here is the class of reason.
class PairingRejected extends PairingUiState {
  /// Holds one failure.
  const PairingRejected(this.reason, {this.detail});

  final PairingFailureReason reason;

  /// For diagnostics. The UI localises from [reason].
  final String? detail;
}

/// Every reason a pairing can fail, from BOTH layers.
///
/// The parse failures and the connection failures are one enum because the
/// screen shows one message and does not care which half produced it — and
/// because two enums would mean two switches in the UI, which is how one of
/// them ends up with a default case that says something generic about a
/// situation that had a specific answer.
enum PairingFailureReason {
  empty,
  malformed,
  unsupportedVersion,
  incomplete,

  unreachable,

  /// The server's key is not the one the pairing code pinned.
  hostKeyMismatch,

  /// The one-time code has expired or was replaced.
  codeExpired,

  exchangeFailed,
  verifyFailed,
  unknown,
}

/// Runs a pairing and, on success, makes it the machine this app talks to.
///
/// The commit order is inherited from the manual "add machine" form and is
/// load-bearing for the same reason: the credential is written before the
/// profile is added, because adding the profile mutates the host list, the
/// connection layer watches that list, and reacting to a profile whose secret
/// is not on disk yet is an authentication failure nothing retries.
class PairingController extends Notifier<PairingUiState> {
  @override
  PairingUiState build() => const PairingIdle();

  /// Clears a finished or failed state, so reopening the screen is clean.
  void reset() {
    if (state is PairingWorking) return;
    state = const PairingIdle();
  }

  /// Pairs with whoever [source] describes.
  ///
  /// [source] is whatever arrived — a scan result or a paste. There is one
  /// parser behind it, which is the point: a scan and a paste cannot disagree
  /// about what a pairing string is.
  Future<void> start(String source) async {
    if (state is PairingWorking) return;

    final PairingTicket ticket;
    try {
      ticket = parsePairingString(source);
    } on PairingParseException catch (e) {
      state = PairingRejected(_reasonForParse(e.reason), detail: e.detail);
      return;
    }

    state = PairingWorking(PairingStep.connect, host: ticket.displayName);

    try {
      // THE PHONE'S KEY IS READ, NOT MINTED. A fresh one per attempt would
      // install a SECOND key on the host every time — see [PhoneIdentityStore].
      final identity = await ref.read(phoneIdentityProvider.future);
      final result = await ref.read(pairingFlowProvider).run(
        ticket,
        identity: identity,
        label: ticket.displayName,
      );

      // Written in this order deliberately — see the class comment.
      await ref
          .read(hostSecretsStoreProvider)
          .write(result.profile.id, SshSecrets(privateKeyPem: result.identity.privateKeyPem));
      await ref
          .read(hostKeyStoreProvider)
          .save(result.profile.pinKey, result.hostKey);

      await ref.read(hostListProvider.notifier).add(result.profile);
      await ref.read(selectedHostIdProvider.notifier).select(result.profile.id);
      ref.read(connectionProvider.notifier).reconnect();

      state = PairingSucceeded(profile: result.profile);
    } on PairingException catch (e) {
      state = PairingRejected(_reasonFor(e.reason), detail: e.detail);
    } on Object catch (e) {
      state = PairingRejected(PairingFailureReason.unknown, detail: '$e');
    }
  }
}

/// The phone's own SSH identity, created on first use and kept after that.
///
/// A provider rather than a call inside the flow, so the keystore is touched in
/// one place — the same place that writes the per-host credentials, and the
/// only one that can be faked in a test.
final phoneIdentityProvider = FutureProvider<PhoneIdentity>(
  (ref) => const PhoneIdentityStore().readOrCreate(),
);

/// The flow the controller drives.
///
/// A provider rather than a `const` inside [PairingController], so the
/// commit-on-success half — writing the credential, pinning the host key,
/// adding the machine — can be tested without a socket. The flow itself is
/// covered by the interop test against the real `hdp` binary; what this seam
/// buys is a test of the part that touches the keystore.
final pairingFlowProvider = Provider<PairingFlow>(
  (ref) => const PairingFlow(connect: pairingTransport),
);

/// The pairing flow's state, for the screen.
final pairingControllerProvider =
    NotifierProvider<PairingController, PairingUiState>(PairingController.new);

PairingFailureReason _reasonForParse(PairingParseFailure reason) =>
    switch (reason) {
      PairingParseFailure.empty => PairingFailureReason.empty,
      PairingParseFailure.malformed => PairingFailureReason.malformed,
      PairingParseFailure.unsupported => PairingFailureReason.unsupportedVersion,
      PairingParseFailure.incomplete => PairingFailureReason.incomplete,
    };

PairingFailureReason _reasonFor(PairingFailure reason) => switch (reason) {
      PairingFailure.unreachable => PairingFailureReason.unreachable,
      PairingFailure.hostKeyMismatch => PairingFailureReason.hostKeyMismatch,
      PairingFailure.bootstrapRejected => PairingFailureReason.codeExpired,
      PairingFailure.exchangeFailed => PairingFailureReason.exchangeFailed,
      PairingFailure.verifyFailed => PairingFailureReason.verifyFailed,
      PairingFailure.unknown => PairingFailureReason.unknown,
    };
