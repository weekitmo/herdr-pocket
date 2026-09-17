import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';

/// A REAL SSH session whose PATH is cut, and what the transport does about it.
///
/// WHY THIS CANNOT BE A UNIT TEST. `ConnectionLiveness.lost` is a claim about
/// dartssh2 and about the kernel underneath it: that when the connection stops
/// working, `SSHClient.done` completes and the transport can say so. A fake can
/// be written to make that true whether or not it is.
///
/// ## Why the connection goes through a proxy
///
/// The failure being reproduced is the USER'S: a phone on a virtual overlay
/// network, an app that went to the background, and a flow that quietly stopped
/// existing in the middle — a NAT mapping expiring, a path re-establishing, a
/// machine asleep. Nothing at either end says goodbye, and the far end is
/// usually still perfectly healthy.
///
/// Killing the test sshd does NOT reproduce that: `tool/test_sshd.sh stop`
/// signals the listener, and (measured here) the already-established
/// `sshd-session` children stay alive and keep the connection up for as long as
/// the test cares to wait. Cutting the path does reproduce it, byte for byte:
/// the client's socket is destroyed with no protocol goodbye.
///
/// Port 2225 is this file's own (2222 is `ssh_transport_test.dart`'s, 2223 and
/// 2224 are the file transfer's), so parallel test files cannot fight over one
/// server.
void main() {
  const port = 2225;
  const dir = '/tmp/hp-sshd-loss';

  final user = Platform.environment['USER'] ?? '';

  setUpAll(() async {
    final key = File('$dir/user_ed25519');
    if (key.existsSync() && await _listening(port)) return;

    final result = await Process.run(
      'sh',
      ['tool/test_sshd.sh', 'start'],
      environment: {
        ...Platform.environment,
        'HP_TEST_SSHD_PORT': '$port',
        'HP_TEST_SSHD_DIR': dir,
      },
    );
    if (result.exitCode != 0) {
      throw StateError(
        'could not start the test sshd on $port:\n${result.stdout}${result.stderr}',
      );
    }
  });

  /// Opens a transport through a fresh [CuttableProxy] in front of the sshd.
  Future<(SshSocketTransport, CuttableProxy)> connect() async {
    final proxy = CuttableProxy(port);
    final proxyPort = await proxy.start();
    final key = File('$dir/user_ed25519');
    final transport = SshSocketTransport(
      credentials: SshCredentials(
        host: '127.0.0.1',
        port: proxyPort,
        username: user,
        privateKeyPem: key.readAsStringSync(),
      ),
      socketPath: '$dir/nothing-here.sock',
      verifyHostKey: (prompt) async => HostKeyVerdict.trust,
    );
    return (transport, proxy);
  }

  group('a live SSH connection', () {
    test('reports itself alive, and does not fire `lost` while it is', () async {
      final (transport, proxy) = await connect();
      addTearDown(transport.close);
      addTearDown(proxy.close);

      expect(await transport.runCommand('echo hello'), contains('hello'));
      expect(transport.isAlive, isTrue);
      expect(await _fired(transport.lost), isFalse);
    });

    test('a deliberate close is NOT a loss', () async {
      // The two want opposite responses — one is left alone and one is
      // re-dialled — so a transport that reported its own close as a loss would
      // make the app dial a machine the user had just walked away from.
      final (transport, proxy) = await connect();
      addTearDown(proxy.close);
      expect(await transport.runCommand('echo hi'), contains('hi'));

      await transport.close();

      expect(transport.isAlive, isFalse);
      expect(
        await _fired(transport.lost, within: const Duration(milliseconds: 500)),
        isFalse,
        reason: 'close() is the app speaking, not the network',
      );
    });

    test('a cut path fires `lost`, and every command afterwards says so',
        () async {
      final (transport, proxy) = await connect();
      addTearDown(transport.close);
      expect(await transport.runCommand('echo hi'), contains('hi'));

      await proxy.cut();

      expect(
        await _fired(transport.lost, within: const Duration(seconds: 10)),
        isTrue,
        reason: 'a dead connection has to announce itself, or the app sits '
            'there claiming to be online',
      );
      expect(transport.isAlive, isFalse);

      // And what a caller is told afterwards. The message names the machine,
      // carries no command, and — the bug that started all of this — is not
      // mistaken for "herdr is not installed" by any of the three screens that
      // classify it.
      await expectLater(
        transport.runCommand('echo never'),
        throwsA(
          isA<HerdrTransportException>()
              .having((e) => e.failure, 'failure', TransportFailure.streamClosed)
              .having(
                (e) => e.message,
                'message',
                'the SSH connection to 127.0.0.1 is gone',
              )
              .having(
                (e) => reportsHerdrMissing(e.message),
                'reads as a missing herdr',
                isFalse,
              ),
        ),
      );
    });
  });
}

/// A TCP relay that can be cut, so a live connection can be killed the way a
/// network kills one: silently, from the middle.
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

  /// Destroys both halves of every relayed flow, with no goodbye.
  Future<void> cut() async {
    for (final socket in _live) {
      socket.destroy();
    }
    _live.clear();
    await _server?.close();
    _server = null;
  }

  Future<void> close() => cut();
}

/// Whether [future] completes within [within].
Future<bool> _fired(
  Future<void> future, {
  Duration within = const Duration(milliseconds: 250),
}) async {
  try {
    await future.timeout(within);
    return true;
  } on TimeoutException {
    return false;
  }
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
