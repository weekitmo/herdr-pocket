import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';

/// Regression test for the cipher preference order, measured through the REAL
/// transport rather than through a constant.
///
/// ## What this actually guards
///
/// `const SSHAlgorithms()` makes dartssh2 prefer `aes256-gcm@openssh.com`, whose
/// GHASH is a pure-Dart carry-less multiply. Measured here over loopback, a
/// 48 MiB read took 36–41 s that way and about one second with
/// [dartsshFastCiphers]. Nothing in the suite notices: the connection works
/// either way, authentication works either way, and every other test passes
/// either way. It is simply thirty-seven times slower.
///
/// There is a second consequence that turns that from "slow" into "broken":
/// [SshSocketTransport.runCommand] applies a 15 s deadline, and
/// [SshSocketTransport.replyTimeout] defaults to it. At 1.2 MiB/s a 48 MiB read
/// cannot finish inside that deadline — it fails with a timeout instead of a
/// result. So the assertion below is not "faster than X MiB/s", which would be
/// a flaky benchmark; it is "finishes at all, through the same code path the
/// app uses", which is the property that was actually broken.
///
/// ## Running it
///
///     sh tool/test_sshd.sh start
///     flutter test test/integration/ssh_throughput_test.dart
///     sh tool/test_sshd.sh stop
///
/// Skips when that server is not running, like the other live suites, so
/// `flutter test` stays green on a machine that has never heard of it.
void main() {
  const port = 2222;
  final keyFile = File('/tmp/hp-sshd/user_ed25519');
  final user = Platform.environment['USER'] ?? '';

  final skipReason = keyFile.existsSync()
      ? null
      : 'test sshd not running (see tool/test_sshd.sh)';

  /// The payload size, chosen to be far past the point where a rate difference
  /// matters: 48 MiB is the size of the APK this feature exists for, and it is
  /// 36 s at the old rate against 1 s at the new one.
  const sizeBytes = 48 * 1024 * 1024;

  const payloadPath = '/tmp/hp-throughput.bin';

  SshSocketTransport transport() => SshSocketTransport(
        credentials: SshCredentials(
          host: '127.0.0.1',
          port: port,
          username: user,
          privateKeyPem: keyFile.readAsStringSync(),
        ),
        // Never dialled in this test: none of these cases asks for the
        // forwarding channel, only for exec. Kept pointing at the real path so
        // the object is built exactly the way the app builds it.
        socketPath: '/nonexistent/herdr.sock',
        verifyHostKey: (prompt) async => HostKeyVerdict.trust,
      );

  setUpAll(() async {
    if (skipReason != null) return;
    final file = File(payloadPath);
    if (file.existsSync() && file.lengthSync() == sizeBytes) return;
    // Written as one buffer rather than line by line: 48 MiB of small writes is
    // most of a second on its own, and this file is setup, not the measurement.
    final chunk = Uint8List.fromList(
      List<int>.generate(64 * 1024, (i) => 0x41 + (i % 26)),
    );
    final sink = file.openWrite();
    var written = 0;
    while (written < sizeBytes) {
      final take = sizeBytes - written < chunk.length
          ? sizeBytes - written
          : chunk.length;
      sink.add(take == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, take));
      written += take;
    }
    await sink.close();
  });

  group('cipher preference (live)', () {
    test('a 48 MiB read through the transport finishes inside the command '
        'deadline', () async {
      final t = transport();
      addTearDown(t.close);

      final sw = Stopwatch()..start();
      final output = await t.runCommand('cat -- $payloadPath');
      sw.stop();

      expect(
        output.length,
        sizeBytes,
        reason: 'a short read must not be reported as a fast one',
      );

      // The deadline is [SshSocketTransport.replyTimeout]'s default of 15 s,
      // and exceeding it is the failure mode, so the assertion is written as
      // the margin against that rather than as a rate.
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 15)),
        reason: 'the read did not finish inside the transport deadline — the '
            'slow GHASH-based cipher is probably preferred again. '
            'Rate: ${(sizeBytes / 1024 / 1024 / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)} MiB/s',
      );

      // Reported rather than asserted: the number is machine-dependent, and
      // pinning it would turn a design change into a fake regression.
      print(
        '  48 MiB over the real transport: ${sw.elapsedMilliseconds} ms '
        '(${(sizeBytes / 1024 / 1024 / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)} MiB/s)',
      );
    }, skip: skipReason);

    test('a small command still round-trips', () async {
      // Cheap counterweight: the throughput case proves the new list carries
      // data, this proves it did not break the ordinary path.
      final t = transport();
      addTearDown(t.close);

      final output = await t.runCommand('echo herdr-pocket-cipher-ok');
      expect(output.trim(), 'herdr-pocket-cipher-ok');
    }, skip: skipReason);
  });
}
