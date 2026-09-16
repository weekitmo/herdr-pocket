import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/pairing.dart';
import 'package:herdr_pocket/data/phone_identity.dart';
import 'package:herdr_pocket/domain/pairing/pairing_ticket.dart';

/// The two halves of pairing, tested against each other.
///
/// ## Why this test is the whole argument
///
/// `hdp` is Go and lives on the host; the phone side is Dart and lives in the
/// app. They agree on a wire format, a marker string in a comment field, and a
/// forced-command invocation — four separate agreements, none of which any unit
/// test on either side can check, because each side only ever sees its own
/// opinion of what the other sends.
///
/// A mismatch produces a pairing that HANGS rather than one that fails, since
/// the host's `hdp pair` sits polling for a marker that never arrives. So the
/// only useful test is this one: run the real `hdp` binary, let Dart play the
/// phone, and see whether the two of them actually finish.
///
///     sh cli/hdp/install_test.sh    # not needed; this test builds it itself
///     flutter test test/integration/pairing_test.dart
///
/// Skipped when the Go toolchain is absent, because a Flutter checkout on a
/// machine without Go should still be green.
void main() {
  final hdpDir = Directory('cli/hdp');
  final hasGo = _which('go') != null && hdpDir.existsSync();

  final skipReason = hasGo
      ? null
      : 'needs the Go toolchain and cli/hdp (see cli/hdp/README)';

  late Directory work;
  late String hdpBinary;
  late int sshdPort;

  setUpAll(() async {
    if (!hasGo) return;

    work = Directory.systemTemp.createTempSync('hdp-pairing-test.');
    final sshDir = Directory('${work.path}/.ssh')..createSync();

    // The host side of the story: a real sshd, its own host key, its own
    // authorized_keys. Nothing here touches the machine's own SSH config.
    await _run('ssh-keygen', ['-q', '-t', 'ed25519', '-f', '${work.path}/host', '-N', '', '-C', 'pairing-test-host']);

    sshdPort = 2230 + DateTime.now().microsecond % 200;
    File('${work.path}/sshd_config').writeAsStringSync('''
Port $sshdPort
ListenAddress 127.0.0.1
HostKey ${work.path}/host
AuthorizedKeysFile ${sshDir.path}/authorized_keys
PidFile ${work.path}/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
LogLevel DEBUG1
''');
    final started = await Process.run(
      '/usr/sbin/sshd',
      ['-f', '${work.path}/sshd_config', '-E', '${work.path}/sshd.log'],
    );
    if (started.exitCode != 0) {
      throw StateError('sshd refused to start:\n${started.stdout}${started.stderr}');
    }

    // WAITED FOR, not probed — and the difference is not pedantry.
    //
    // sshd daemonizes, so a zero exit status means the parent forked and
    // nothing more. The obvious check is a TCP connect, and it BREAKS THE TEST:
    // OpenSSH 9.8 added `PerSourcePenalties`, which counts a connection that
    // opens and closes without attempting authentication as abuse and applies a
    // penalty to that source address — here, 127.0.0.1, where every connection
    // in this file comes from. Measured: the probe was logged as
    // `kex_exchange_identification: Connection closed by remote host` followed
    // by `deferred penalty of 1 seconds for penalty: connections without
    // attempting authentication`, and the real connection that followed was
    // dropped before it reached the auth code.
    //
    // The sshd's own log line costs nothing and cannot be mistaken for a client.
    await _awaitLogLine(
      File('${work.path}/sshd.log'),
      'Server listening on',
      onFailure: () => 'sshd reported success but never logged a listening '
          'socket.\nsshd.log:\n'
          '${File('${work.path}/sshd.log').existsSync() ? File('${work.path}/sshd.log').readAsStringSync() : '(none)'}',
    );

    hdpBinary = '${work.path}/hdp';
    final build = await Process.run(
      'go', ['build', '-o', hdpBinary, '.'],
      workingDirectory: hdpDir.path,
    );
    if (build.exitCode != 0) {
      throw StateError('go build failed:\n${build.stdout}${build.stderr}');
    }
  });

  tearDownAll(() {
    if (sshddRunning(work)) {
      final pid = int.tryParse(File('${work.path}/sshd.pid').readAsStringSync().trim());
      if (pid != null) Process.killPid(pid);
    }
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  test('Dart pairing against the real hdp binary, to the end', () async {
    // The host runs `hdp pair` for real, with HOME pointed at the throwaway
    // directory so nothing can reach the developer's own authorized_keys — the
    // exact mistake that was made once while building this, which wrote a test
    // key into ~/.ssh/authorized_keys while reporting success.
    final pair = await Process.start(
      hdpBinary,
      [
        'pair',
        '--user', Platform.environment['USER'] ?? 'nobody',
        '--host', '127.0.0.1',
        '--port', '$sshdPort',
        '--name', 'Pairing test box',
        '--window', '60s',
        '--no-qr',
      ],
      environment: {...Platform.environment, 'HOME': work.path},
    );

    final stdoutLines = <String>[];
    final stdoutDone = pair.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stdoutLines.add);

    // The pairing string is the long base64url line hdp prints; wait for it
    // rather than sleeping a fixed amount, so a slow machine does not flake.
    final ticket = await _waitFor<PairingTicket>(
      () {
        for (final line in stdoutLines) {
          final trimmed = line.trim();
          if (trimmed.length > 80 && !trimmed.contains(' ')) {
            return parsePairingString(trimmed);
          }
        }
        return null;
      },
      timeout: const Duration(seconds: 20),
      what: 'hdp pair to print a pairing string',
    );

    expect(ticket.host, '127.0.0.1');
    expect(ticket.port, sshdPort);
    expect(ticket.name, 'Pairing test box');
    // A SEED, not a PEM — and the length is the point: this is what keeps the
    // code small enough to scan.
    expect(ticket.bootstrapSeed.length, ed25519SeedBytes);
    expect(ticket.hostKeyFingerprint, startsWith('SHA256:'));

    // ---------------------------------------------------- the phone side ---

    final PairingResult result;
    try {
      result = await const PairingFlow(connect: pairingTransport).run(
        ticket,
        label: 'unit test phone',
      );
    } on Object {
      // Dumped on the way past, because this failure is otherwise the least
      // diagnosable kind there is: the phone side sees "the connection closed"
      // and the reason is only ever in the SERVER's log, which lives in a
      // temporary directory that this test is about to delete.
      final log = File('${work.path}/sshd.log');
      if (log.existsSync()) {
        // `print` rather than `debugPrint`: this is a test, `avoid_print` does
        // not apply here, and a diagnostic that only appears when a test is
        // already failing has to be readable in the plainest way there is.
        stdout.writeln('--- sshd log ---\n${log.readAsStringSync()}');
      }
      rethrow;
    }

    // The key genuinely works, and the flow proved it by connecting with it.
    expect(result.identity.authorizedKeyLine, contains(clientKeyMarker));
    expect(result.hostKey.fingerprint, ticket.hostKeyFingerprint);
    expect(result.profile.label, 'Pairing test box');
    expect(result.profile.port, sshdPort);

    // ------------------------------------------------- what the host sees ---

    final finished = await pair.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        pair.kill();
        throw StateError(
          'hdp pair never finished — the phone side did not send what it was '
          'polling for.\nstdout so far:\n${stdoutLines.join('\n')}',
        );
      },
    );
    await stdoutDone.cancel();

    expect(
      finished,
      0,
      reason: 'hdp pair exited $finished.\n${stdoutLines.join('\n')}',
    );

    final keys =
        File('${work.path}/.ssh/authorized_keys').readAsStringSync();
    expect(
      keys,
      contains(clientKeyMarker),
      reason: "the phone's key should be installed with its marker comment",
    );
    expect(
      keys,
      isNot(contains('hdp-bootstrap-')),
      reason: 'the temporary key must be removed once pairing succeeds — a '
          'bootstrap key that outlives its window is a credential nobody '
          'remembers issuing',
    );
  }, timeout: const Timeout(Duration(minutes: 2)), skip: skipReason);
}

/// Polls [probe] until it returns something, or the timeout expires.
Future<T> _waitFor<T>(
  T? Function() probe, {
  required Duration timeout,
  required String what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('timed out waiting for $what');
}

/// Waits for [line] to appear in [file], without connecting to anything.
///
/// See the note where this is called: a TCP probe here would be counted by the
/// server as a connection that never authenticates, and would penalise the very
/// address the test is about to use.
Future<void> _awaitLogLine(
  File file,
  String line, {
  required String Function() onFailure,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync() && file.readAsStringSync().contains(line)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(onFailure());
}

Future<void> _run(String program, List<String> args) async {
  final result = await Process.run(program, args);
  if (result.exitCode != 0) {
    throw StateError('$program ${args.join(' ')} failed:\n${result.stderr}');
  }
}

String? _which(String program) {
  final result = Process.runSync('sh', ['-c', 'command -v $program']);
  final out = (result.stdout as String).trim();
  return out.isEmpty ? null : out;
}

/// Whether the throwaway sshd is still up.
bool sshddRunning(Directory dir) {
  final pidFile = File('${dir.path}/sshd.pid');
  return pidFile.existsSync();
}
