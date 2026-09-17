import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/shell_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';

/// Builds the runner the SSH shell page dials through.
///
/// A PROVIDER RATHER THAN A LITERAL INSIDE THE PAGE, for the same reason
/// `hostConnectorProvider` is one: it is the only way to exercise the page
/// against a scripted session instead of against an SSH server. The tests that
/// matter here — the pty is opened at the box's size, a key sends exactly the
/// bytes it names, the exit status reaches the screen — are all assertions
/// about what the page DOES with a session, and none of them needs a real one.
///
/// It is also the right layer. The page should not know that credentials live
/// in a keystore under a profile id, or that a blank command means a login
/// shell; both are answers this returns.
///
/// The returned function is async because the keystore is: secrets are read at
/// dial time and never held on the profile, which is what keeps a profile safe
/// to log or export.
final shellRunnerProvider =
    Provider<Future<RemoteShellRunner> Function(HostProfile)>((ref) {
  return (profile) async {
    final secrets = await ref.read(hostSecretsStoreProvider).read(profile.id);
    if (secrets == null) {
      // The same sentence the board shows for a machine with no credential:
      // the user's next move is the same one either way.
      throw HerdrTransportException(
        TransportFailure.authenticationFailed,
        'no stored credential for ${profile.label}',
      );
    }

    return SshShellTransport(
      credentials: SshCredentials(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: secrets.privateKeyPem,
        privateKeyPassphrase: secrets.privateKeyPassphrase,
        password: secrets.password,
      ),
      // The SAME verifier the board dials through, so a machine approved once is
      // never asked about again — and a machine whose key CHANGED raises the
      // same alarm on this connection as on that one.
      verifyHostKey: ref.read(hostKeyVerifierProvider),
      // Read at dial time rather than at page construction: the setting is
      // edited on a different screen, and a terminal opened after the change
      // should run the new command.
      command: ref.read(settingsProvider).sessionCommand,
    );
  };
});
