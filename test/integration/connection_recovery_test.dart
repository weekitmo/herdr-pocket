import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/host_store.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE USER'S FAILURE, END TO END, WITH NOTHING FAKED.
///
/// Reported from the phone: "the SSH connection dropped and it never
/// reconnected — I had to go to the machine. It looked connected the whole
/// time." The connection was over a virtual overlay network, which makes a
/// silent death the normal case rather than the exception.
///
/// Every other test of this recovery scripts one half of it: the unit tests
/// fake the transport, and the transport test cuts a connection but stops
/// there. This one runs the whole stack — a real SSH dial, a real
/// `direct-streamlocal` forward to a real herdr socket, a real event
/// subscription — and then cuts the network path underneath it and waits to see
/// whether the app comes back on its own.
///
/// The proxy is what makes it honest: killing the sshd does not kill an
/// established session (the `sshd-session` child stays alive), so a test that
/// stopped the server would pass without ever having dropped anything.
void main() {
  const sshdPort = 2226;
  const sshdDir = '/tmp/hp-sshd-recovery';

  final home = Platform.environment['HOME'] ?? '';
  final socketPath = '$home/.config/herdr/herdr.sock';
  final user = Platform.environment['USER'] ?? '';

  setUpAll(() async {
    if (File('$sshdDir/user_ed25519').existsSync() &&
        await _listening(sshdPort)) {
      return;
    }
    final result = await Process.run(
      'sh',
      ['tool/test_sshd.sh', 'start'],
      environment: {
        ...Platform.environment,
        'HP_TEST_SSHD_PORT': '$sshdPort',
        'HP_TEST_SSHD_DIR': sshdDir,
      },
    );
    if (result.exitCode != 0) {
      throw StateError(
        'could not start the test sshd on $sshdPort:\n'
        '${result.stdout}${result.stderr}',
      );
    }
  });

  test('a cut link comes back by itself, with no user action', () async {
    final proxy = CuttableProxy(sshdPort);
    final proxyPort = await proxy.start();
    addTearDown(proxy.close);

    final key = File('$sshdDir/user_ed25519').readAsStringSync();
    final profile = HostProfile(
      id: 'lossy',
      label: 'lossy',
      host: '127.0.0.1',
      port: proxyPort,
      username: user,
      socketPath: socketPath,
    );

    // The machine is in the LIST, not just in the provider: the notifier
    // re-reads that list before every dial and stops dialling a machine the
    // user no longer has — with an override-only profile, every recovery would
    // be refused as "a machine that was deleted".
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.settings.autoConnect': true,
      'hosts.profiles': jsonEncode([profile.toJson()]),
      'hosts.selected': profile.id,
    });
    final prefs = await SharedPreferences.getInstance();

    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        hostSecretsStoreProvider.overrideWithValue(_MemorySecrets(key)),
        connectionRetryDelayProvider.overrideWithValue(Duration.zero),
        connectionSlowRetryDelayProvider.overrideWithValue(
          const Duration(milliseconds: 50),
        ),
        // A REAL connector — the same one the app dials with — with only its
        // two platform-shaped ends swapped: the keystore, and TOFU approval for
        // a scratch server whose key nobody has seen.
        hostConnectorProvider.overrideWithValue(
          HostConnector(
            credentialsFor: (profile) async => SshSecrets(privateKeyPem: key),
            verifyHostKey: (_) async => HostKeyVerdict.trust,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final seen = <ConnectionStatus>[];
    container.listen(
      connectionProvider,
      (_, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      },
      fireImmediately: true,
    );

    // Up for real: SSH handshake, socket forward, and a ping the daemon
    // answered.
    await _settle(container);
    expect(container.read(connectionProvider).value, isA<Online>());
    expect(seen.whereType<Online>(), hasLength(1));

    // The overlay network drops the flow. No FIN from the far end, no error
    // from anywhere: the sockets are simply destroyed.
    await proxy.dropFlows();
    // THE DEAD CONNECTION IS STILL `Online` FOR A MOMENT — nothing has looked
    // at the socket yet — so waiting for "the state is Online" would pass
    // immediately, on the corpse. What has to happen is a SECOND connection:
    // that is the whole assertion.
    await _waitUntil(
      () => seen.whereType<Online>().length >= 2,
      within: const Duration(seconds: 30),
    );

    expect(
      container.read(connectionProvider).value,
      isA<Online>(),
      reason: 'a dropped link is recovered without the user asking',
    );
    expect(
      seen.whereType<Connecting>().any((c) => c.afterLoss),
      isTrue,
      reason: 'and the user is told the connection is gone, not that the app '
          'is starting up',
    );
    expect(
      seen.whereType<Online>().length,
      greaterThanOrEqualTo(2),
      reason: 'the recovery is a second connection, not the first one again',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// Waits for the connection to settle on a terminal state.
Future<void> _settle(
  ProviderContainer container, {
  Duration within = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final value = container.read(connectionProvider);
    if (!value.isLoading &&
        (value.value is Online || value.value is ConnectionFailed)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Waits for something the STATUS alone cannot express — a second connection,
/// rather than a reading of the first.
Future<void> _waitUntil(
  bool Function() predicate, {
  Duration within = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition never became true within ${within.inSeconds}s');
}

/// A TCP relay whose flows can be dropped while it keeps listening.
///
/// Listening again matters: the recovery dials the SAME host and port, so a
/// proxy that stopped accepting would test "the app gives up cleanly" instead
/// of "the app comes back".
class CuttableProxy {
  CuttableProxy(this.upstreamPort);

  final int upstreamPort;
  final List<Socket> _live = [];
  ServerSocket? _server;

  Future<int> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((client) async {
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        upstreamPort,
      );
      _live
        ..add(client)
        ..add(upstream);
      client.listen(
        upstream.add,
        onDone: upstream.close,
        onError: (Object _) => upstream.destroy(),
      );
      upstream.listen(
        client.add,
        onDone: client.close,
        onError: (Object _) => client.destroy(),
      );
    });
    return server.port;
  }

  /// Destroys every relayed flow, with no goodbye, and keeps listening.
  Future<void> dropFlows() async {
    for (final socket in _live) {
      socket.destroy();
    }
    _live.clear();
  }

  Future<void> close() async {
    await dropFlows();
    await _server?.close();
    _server = null;
  }
}

class _MemorySecrets extends HostSecretsStore {
  const _MemorySecrets(this.pem);

  final String pem;

  @override
  Future<SshSecrets?> read(String hostId) async =>
      SshSecrets(privateKeyPem: pem);

  @override
  Future<void> delete(String hostId) async {}
}

Future<bool> _listening(int port) async {
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 500),
    );
    await socket.close();
    return true;
  } on Object {
    return false;
  }
}
