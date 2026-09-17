import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';

/// End-to-end verification of the transport architecture against a REAL SSH
/// server, a REAL `direct-streamlocal` channel, and a REAL herdr daemon.
///
/// This is the test that proves the project's central bet: that a pure-Dart SSH
/// stack can reach herdr's Unix socket with no helper binary on the remote
/// host. Everything upstream of this is either unit-tested or verified against
/// a local socket; this is the only place the SSH channel type itself is
/// exercised.
///
/// ## Running it
///
/// It needs an SSH server that (a) accepts a key we hold and (b) permits
/// stream-local forwarding. Rather than touch the developer's own SSH config,
/// `tool/test_sshd.sh` starts a throwaway sshd on port 2222 with its own host
/// key, its own authorised key and its own pid file.
///
///     sh tool/test_sshd.sh start
///     flutter test test/integration/ssh_transport_test.dart
///     sh tool/test_sshd.sh stop
///
/// The suite skips when that server is not running, so `flutter test` stays
/// green on a machine that has never heard of it.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final daemonSocket = '$home/.config/herdr/herdr.sock';

  const testSshPort = 2222;
  final keyFile = File('/tmp/hp-sshd/user_ed25519');
  final host = Platform.environment['USER'] ?? '';

  final ready = keyFile.existsSync() && File(daemonSocket).existsSync();
  final skipReason =
      ready ? null : 'test sshd or herdr socket not present (see tool/test_sshd.sh)';

  HerdrClient connect() {
    final transport = SshSocketTransport(
      credentials: SshCredentials(
        host: '127.0.0.1',
        port: testSshPort,
        username: host,
        privateKeyPem: keyFile.readAsStringSync(),
      ),
      socketPath: daemonSocket,
      // TOFU is the production policy; a scratch server has a key nobody has
      // seen, so this test approves it explicitly rather than pretending.
      verifyHostKey: (prompt) async => HostKeyVerdict.trust,
    );
    return HerdrClient(transport);
  }

  group('ssh transport (live)', () {
    test('connects, forwards to the Unix socket, and completes a round trip',
        () async {
      final c = connect();
      addTearDown(c.close);

      final hello = await c.ping();
      expect(hello.version, isNotEmpty);
      expect(hello.protocol, greaterThan(0));
      print('  over SSH: herdr ${hello.version} protocol ${hello.protocol}');
    }, skip: skipReason);

    test('one channel per request on a single-shot API socket', () async {
      // The daemon accepts ONE request per connection. A transport that reused
      // the channel would succeed once and fail on the second call, so this
      // asserts the property directly rather than trusting the design note.
      final c = connect();
      addTearDown(c.close);

      for (var i = 0; i < 4; i++) {
        final hello = await c.ping();
        expect(hello.protocol, greaterThan(0), reason: 'request #$i failed');
      }
    }, skip: skipReason);

    test('the board composes over SSH, not just over a local socket', () async {
      final c = connect();
      addTearDown(c.close);

      final board = await c.board();
      final sectioned = board.sections.expand((s) => s.rows).length;
      expect(sectioned, board.rows.length);
      print('  over SSH: ${board.rows.length} agents');
    }, skip: skipReason);

    test('a bad key is reported as authentication failure, not a crash',
        () async {
      final transport = SshSocketTransport(
        credentials: SshCredentials(
          host: '127.0.0.1',
          port: testSshPort,
          username: host,
          // A syntactically valid key that the server does not accept.
          privateKeyPem: File('/tmp/hp-sshd/host_ed25519').readAsStringSync(),
        ),
        socketPath: daemonSocket,
        verifyHostKey: (prompt) async => HostKeyVerdict.trust,
      );
      addTearDown(transport.close);

      await expectLater(
        HerdrClient(transport).ping(),
        throwsA(
          isA<HerdrTransportException>().having(
            (e) => e.failure,
            'failure',
            TransportFailure.authenticationFailed,
          ),
        ),
      );
    }, skip: skipReason);

    test('a refusing host-key verifier stops the connection', () async {
      final transport = SshSocketTransport(
        credentials: SshCredentials(
          host: '127.0.0.1',
          port: testSshPort,
          username: host,
          privateKeyPem: keyFile.readAsStringSync(),
        ),
        socketPath: daemonSocket,
        verifyHostKey: (prompt) async => HostKeyVerdict.reject,
      );
      addTearDown(transport.close);

      await expectLater(
        HerdrClient(transport).ping(),
        throwsA(isA<Object>()),
      );
    }, skip: skipReason);
  });
}
