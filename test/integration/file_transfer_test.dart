import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';

/// Live tests for [RemoteFileFetcher] — downloading a file off the host.
///
/// ## Two servers, because one of them is the point
///
/// `tool/test_sshd.sh` writes an `sshd_config` with **no `Subsystem` line** by
/// default, and with one when `HP_TEST_SSHD_SFTP=1`. So the same script produces
/// both halves of this feature's contract, differing by one line:
///
/// | port | SFTP | what it proves |
/// |---|---|---|
/// | 2223 | yes | a download arrives byte-for-byte, and cancels cleanly |
/// | 2224 | no  | the failure is `sftpUnavailable`, reported FAST |
///
/// The second row is the reason this file exists. `SSHClient.sftp()` returns a
/// client without waiting for the server to answer the subsystem request, so a
/// host without SFTP yields an object that looks fine and then blocks forever.
/// A test that only proved the happy path would pass on a machine where the
/// feature hangs for every user whose host is hardened.
///
/// These ports are DEDICATED (2222 is `ssh_transport_test.dart`'s) so that
/// `flutter test`'s parallel test files cannot fight over one sshd. The servers
/// are started here if absent and stopped again only if this file started them.
void main() {
  const sftpPort = 2223;
  const plainPort = 2224;
  const sftpDir = '/tmp/hp-sftp';
  const plainDir = '/tmp/hp-sshd-plain';

  final user = Platform.environment['USER'] ?? '';
  const payloadPath = '/tmp/hp-download-source.bin';

  /// 4 MiB: 256 chunks at the library's 16 KiB read size, so the streaming and
  /// ordering are genuinely exercised, while staying small enough that the
  /// test's own accumulation is not the thing being measured.
  const payloadBytes = 4 * 1024 * 1024;

  final startedByUs = <int>{};

  Future<void> ensureServer({
    required int port,
    required String dir,
    required bool sftp,
  }) async {
    final key = File('$dir/user_ed25519');
    if (key.existsSync() && await _listening(port)) return;

    final env = {
      ...Platform.environment,
      'HP_TEST_SSHD_PORT': '$port',
      'HP_TEST_SSHD_DIR': dir,
      'HP_TEST_SSHD_SFTP': sftp ? '1' : '0',
    };
    final result = await Process.run('sh', ['tool/test_sshd.sh', 'start'], environment: env);
    if (result.exitCode != 0) {
      throw StateError(
        'could not start the test sshd on $port:\n${result.stdout}${result.stderr}',
      );
    }
    startedByUs.add(port);
  }

  Future<void> stopServer({required int port, required String dir}) async {
    if (!startedByUs.contains(port)) return;
    await Process.run(
      'sh',
      ['tool/test_sshd.sh', 'stop'],
      environment: {
        ...Platform.environment,
        'HP_TEST_SSHD_PORT': '$port',
        'HP_TEST_SSHD_DIR': dir,
      },
    );
  }

  setUpAll(() async {
    await ensureServer(port: sftpPort, dir: sftpDir, sftp: true);
    await ensureServer(port: plainPort, dir: plainDir, sftp: false);

    // Content that changes every byte, so "the bytes arrived" is a claim about
    // content and not only about a length.
    final file = File(payloadPath);
    if (!file.existsSync() || file.lengthSync() != payloadBytes) {
      final chunk = Uint8List.fromList(
        List<int>.generate(64 * 1024, (i) => (i * 37 + (i >> 3)) & 0xFF),
      );
      final sink = file.openWrite();
      var written = 0;
      while (written < payloadBytes) {
        final take = payloadBytes - written < chunk.length
            ? payloadBytes - written
            : chunk.length;
        sink.add(take == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, take));
        written += take;
      }
      await sink.close();
    }
  });

  tearDownAll(() async {
    await stopServer(port: sftpPort, dir: sftpDir);
    await stopServer(port: plainPort, dir: plainDir);
    File(payloadPath).deleteSync();
  });

  SshSocketTransport transport({
    required int port,
    required String dir,
    Duration replyTimeout = const Duration(seconds: 10),
  }) =>
      SshSocketTransport(
        credentials: SshCredentials(
          host: '127.0.0.1',
          port: port,
          username: user,
          privateKeyPem: File('$dir/user_ed25519').readAsStringSync(),
        ),
        // Never dialled: none of these cases wants the forwarding channel.
        socketPath: '/nonexistent/herdr.sock',
        verifyHostKey: (prompt) async => HostKeyVerdict.trust,
        replyTimeout: replyTimeout,
      );

  group('a host WITH sftp', () {
    test('a downloaded file is byte-for-byte the remote file', () async {
      final t = transport(port: sftpPort, dir: sftpDir);
      addTearDown(t.close);

      final received = BytesBuilder(copy: false);
      await t.download(payloadPath).forEach(received.add);

      final got = received.takeBytes();
      expect(got.length, payloadBytes, reason: 'a short read must never pass');
      expect(
        got,
        await File(payloadPath).readAsBytes(),
        reason: 'chunks must arrive in order and without gaps',
      );
    });

    test('reports the size before transferring anything', () async {
      final t = transport(port: sftpPort, dir: sftpDir);
      addTearDown(t.close);

      final info = await t.statFile(payloadPath);
      expect(info.sizeBytes, payloadBytes);
      expect(info.isDirectory, isFalse);

      final missing = await t
          .statFile('/tmp/hp-does-not-exist-$pid')
          .then<Object?>((v) => v)
          .catchError((Object e) => e);
      expect(missing, isA<HerdrTransportException>(),
          reason: 'a missing file is a failure, not a zero-byte file');
    });

    test('cancelling the subscription actually stops the transfer', () async {
      final t = transport(port: sftpPort, dir: sftpDir);
      addTearDown(t.close);

      var received = 0;
      final subscription = t.download(payloadPath).listen((chunk) {
        received += chunk.length;
      });

      // Cancel on the first chunk. This is the case the stream shape was chosen
      // for: the file handle and the subsystem channel have to come down
      // without the caller awaiting anything further.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();
      final atCancel = received;

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        received,
        atCancel,
        reason: 'chunks kept arriving after cancel() — the transfer leaked',
      );

      // And the connection is still usable, which is what proves the `finally`
      // unwound cleanly instead of killing the session.
      final info = await t.statFile(payloadPath);
      expect(info.sizeBytes, payloadBytes);
    });
  });

  group('a host WITHOUT sftp', () {
    test('fails as sftpUnavailable, and fails FAST', () async {
      final t = transport(
        port: plainPort,
        dir: plainDir,
        replyTimeout: const Duration(seconds: 2),
      );
      addTearDown(t.close);

      final sw = Stopwatch()..start();
      final error = await t
          .download(payloadPath)
          .toList()
          .then<Object?>((v) => v)
          .catchError((Object e) => e);
      sw.stop();

      expect(
        error,
        isA<HerdrTransportException>()
            .having((e) => e.failure, 'failure', TransportFailure.sftpUnavailable)
            .having((e) => e.isSftpUnavailable, 'isSftpUnavailable', isTrue),
        reason: 'a host with no `Subsystem sftp` must produce a classified '
            'failure — the UI has to be able to name the fix',
      );

      // THE ASSERTION THAT WOULD HAVE CAUGHT THE HANG. Without the explicit
      // handshake wait this call does not throw AT ALL; it blocks until the
      // test times out, which in production is a spinner that never ends.
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 6)),
        reason: 'the failure took ${sw.elapsed} — it is hanging rather than '
            'detecting the refused subsystem',
      );
    });

    test('statFile reports the same thing rather than a timeout', () async {
      final t = transport(
        port: plainPort,
        dir: plainDir,
        replyTimeout: const Duration(seconds: 2),
      );
      addTearDown(t.close);

      final error = await t
          .statFile(payloadPath)
          .then<Object?>((v) => v)
          .catchError((Object e) => e);

      expect(
        error,
        isA<HerdrTransportException>()
            .having((e) => e.isSftpUnavailable, 'isSftpUnavailable', isTrue),
      );
    });

    test('ordinary shell commands still work — only SFTP is missing', () async {
      // The distinction the whole feature rests on: a host can be perfectly
      // usable (status board, terminal, git) and still unable to move a file.
      // Browsing uses `ls` over an exec channel for exactly this reason.
      final t = transport(port: plainPort, dir: plainDir);
      addTearDown(t.close);

      final output = await t.runCommand('echo no-sftp-but-alive');
      expect(output.trim(), 'no-sftp-but-alive');
    });
  });

  group('path discipline', () {
    test('every SFTP entry point refuses a relative path', () async {
      final t = transport(port: sftpPort, dir: sftpDir);
      addTearDown(t.close);

      // `download` is an `async*` generator, so its body does not run until
      // something listens — the ArgumentError arrives as a stream error rather
      // than synchronously. Asserting `throwsArgumentError` on the returned
      // Stream would fail, and would be testing Dart's laziness rather than
      // this class's validation. `.toList()` is what makes the body run.
      await expectLater(t.download('relative/file').toList(), throwsArgumentError);
      await expectLater(t.statFile('relative/file'), throwsArgumentError);
      await expectLater(
        t.uploadBytes(absolutePath: 'relative/file', bytes: const [1]),
        throwsArgumentError,
      );
    });
  });
}

/// Whether something is accepting connections on [port].
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
