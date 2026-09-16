import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/phone_identity.dart';
import 'package:herdr_pocket/domain/pairing/pairing_ticket.dart';

/// Proves the key the app rebuilds from a pairing string is the SAME KEY the
/// host installed — checked by OpenSSH itself, not by dartssh2.
///
/// ## Why this test has to exist separately
///
/// The app rebuilds an ed25519 private key file from the 32-byte seed the
/// pairing string carries. Every other test here proves that dartssh2 can
/// authenticate with the result — and dartssh2 is forgiving about things
/// OpenSSH is not: a private key section holding the wrong 64 bytes still
/// parses, still signs, and only the SERVER can tell the signature is wrong.
///
/// So this one asks `ssh-keygen -y`, which reads the private section, derives
/// the public key from it, and prints it. If what comes out is not the public
/// key that went into `authorized_keys`, the file is a key file that no sshd
/// will ever accept — and that is invisible from the Dart side, because nothing
/// in Dart ever verifies a signature it made.
///
/// Then it connects for real, with the `ssh` binary, against a throwaway sshd
/// running with `StrictModes yes` — the default, and the setting the earlier
/// interop test turned off to keep its temp directory usable.
void main() {
  final hdpDir = Directory('cli/hdp');
  final hasGo = _which('go') != null && hdpDir.existsSync();
  final hasSsh = _which('ssh-keygen') != null && _which('ssh') != null;

  final skipReason = !hasGo
      ? 'needs the Go toolchain and cli/hdp'
      : (!hasSsh ? 'needs the OpenSSH client' : null);

  late Directory home;
  late int port;

  setUpAll(() async {
    if (skipReason != null) return;

    // UNDER $HOME, NOT /tmp. macOS's /tmp is world-writable, and sshd's
    // `StrictModes` refuses to read an authorized_keys file inside a directory
    // anyone can write to — measured, with the server logging
    // "Authentication refused: bad ownership or modes for directory /private/tmp".
    // A test that used /tmp would fail for a reason that has nothing to do with
    // the code under test.
    home = Directory('${Platform.environment['HOME']}/.hdp-keytest');
    if (home.existsSync()) home.deleteSync(recursive: true);
    Directory('${home.path}/.ssh').createSync(recursive: true);
    await _run('chmod', ['700', home.path, '${home.path}/.ssh']);

    await _run('ssh-keygen',
        ['-q', '-t', 'ed25519', '-f', '${home.path}/host', '-N', '', '-C', 'keytest']);

    final build = await Process.run(
      'go', ['build', '-o', '${home.path}/hdp', '.'],
      workingDirectory: hdpDir.path,
    );
    if (build.exitCode != 0) {
      throw StateError('go build failed: ${build.stdout}${build.stderr}');
    }

    port = 2270 + DateTime.now().microsecond % 100;
    File('${home.path}/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey ${home.path}/host
AuthorizedKeysFile ${home.path}/.ssh/authorized_keys
PidFile ${home.path}/sshd.pid
StrictModes yes
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
LogLevel DEBUG1
''');
    final started = await Process.run(
      '/usr/sbin/sshd',
      ['-f', '${home.path}/sshd_config', '-E', '${home.path}/sshd.log'],
    );
    if (started.exitCode != 0) {
      throw StateError('sshd refused to start: ${started.stderr}');
    }
    // Waited for through the server's OWN log rather than by connecting: a TCP
    // probe that opens and closes without authenticating counts as abuse under
    // OpenSSH 9.8's `PerSourcePenalties` and penalises 127.0.0.1 — the address
    // every connection in this file comes from.
    await _awaitLog(home, 'Server listening on');
  });

  tearDownAll(() {
    if (skipReason != null) return;
    final pidFile = File('${home.path}/sshd.pid');
    if (pidFile.existsSync()) {
      final pid = int.tryParse(pidFile.readAsStringSync().trim());
      if (pid != null) Process.killPid(pid);
    }
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('the rebuilt key is the key the host installed', () async {
    final pair = await Process.start(
      '${home.path}/hdp',
      [
        'pair',
        '--user', Platform.environment['USER'] ?? 'nobody',
        '--host', '127.0.0.1',
        '--port', '$port',
        '--window', '60s',
        '--no-qr',
      ],
      environment: {...Platform.environment, 'HOME': home.path},
    );

    final lines = <String>[];
    final drained = pair.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);

    final payload = await _waitFor(
      () => lines
          .map((l) => l.trim())
          .where((l) => l.length > 80 && !l.contains(' '))
          .firstOrNull,
      what: 'the pairing string',
    );
    final ticket = parsePairingString(payload);

    // ------------------------------------------------------- the rebuild ---

    final rebuilt = File('${home.path}/rebuilt');
    rebuilt.writeAsStringSync(
      openSshEd25519PrivateKeyFromSeed(ticket.bootstrapSeed),
    );
    await _run('chmod', ['600', rebuilt.path]);

    // `ssh-keygen -y` reads the PRIVATE section and prints the public key
    // derived from it. This is the assertion dartssh2 cannot make for us.
    final derived = await _capture('ssh-keygen', ['-y', '-f', rebuilt.path]);

    final installed = File('${home.path}/.ssh/authorized_keys')
        .readAsStringSync()
        .split('\n')
        .firstWhere((l) => l.contains('hdp-bootstrap'));
    // ANCHORED ON THE KEY TYPE, not on a column index — the line starts with
    // `restrict,command="…"`, and the command itself contains SPACES, so a
    // plain split puts `__exchange` at index 1. Same lesson as the Go side's
    // `fingerprintOfAuthorizedKey`.
    final fields = installed.split(RegExp(r'\s+'));
    final typeAt = fields.indexOf('ssh-ed25519');
    expect(typeAt, greaterThanOrEqualTo(0), reason: 'no key type in the line');
    final installedPub = fields[typeAt + 1];

    expect(
      derived.trim(),
      contains(installedPub),
      reason: 'the rebuilt private key does not derive the public key that '
          'authorized_keys was given — sshd would refuse every connection made '
          'with it, and the app can only report that as "the pairing code has '
          'expired"',
    );

    // ---------------------------------------------------- the real client ---

    final result = await Process.run(
      'ssh',
      [
        '-i', rebuilt.path,
        '-p', '$port',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'BatchMode=yes',
        // stdin from /dev/null so the client cannot hang on a prompt that
        // nothing will answer.
        '${Platform.environment['USER']}@127.0.0.1',
        'true',
      ],
      environment: {...Platform.environment, 'HOME': home.path},
    );

    // The bootstrap key runs the forced command, which with no key on stdin
    // reports its own failure — but AUTHENTICATION succeeding is what is being
    // tested, and that shows up as this exact line rather than as an exit code.
    expect(
      '${result.stdout}${result.stderr}',
      isNot(contains('Permission denied')),
      reason: 'OpenSSH refused the rebuilt key:\n${result.stderr}',
    );

    pair.kill();
    await drained.cancel();
  }, timeout: const Timeout(Duration(minutes: 2)), skip: skipReason);
}

Future<T> _waitFor<T>(
  T? Function() probe, {
  required String what,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('timed out waiting for $what');
}

Future<void> _awaitLog(Directory home, String needle) async {
  final log = File('${home.path}/sshd.log');
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (log.existsSync() && log.readAsStringSync().contains(needle)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('sshd never logged "$needle"');
}

Future<void> _run(String program, List<String> args) async {
  final r = await Process.run(program, args);
  if (r.exitCode != 0) throw StateError('$program failed: ${r.stderr}');
}

Future<String> _capture(String program, List<String> args) async {
  final r = await Process.run(program, args);
  if (r.exitCode != 0) throw StateError('$program failed: ${r.stderr}');
  return r.stdout as String;
}

String? _which(String program) {
  final r = Process.runSync('sh', ['-c', 'command -v $program']);
  final out = (r.stdout as String).trim();
  return out.isEmpty ? null : out;
}
