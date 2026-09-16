// Measures the two ways a file can leave the remote machine.
//
// RUN IT WITH:
//
//     sh tool/test_sshd.sh start                  # 2222, NO sftp subsystem
//     HP_TEST_SSHD_PORT=2223 HP_TEST_SSHD_DIR=/tmp/hp-sftp \
//       HP_TEST_SSHD_SFTP=1 sh tool/test_sshd.sh start   # 2223, sftp enabled
//
//     dart run tool/probe_sftp.dart               # against 2222
//     HP_PORT=2223 dart run tool/probe_sftp.dart  # against 2223
//
//     # and the measurement that matters most:
//     HP_PORT=2223 HP_CIPHERS=chacha20-poly1305@openssh.com,aes256-ctr \
//       dart run tool/probe_sftp.dart
//
// WHY IT EXISTS. `docs/research/04-flutter-stack.md` carries one UNVERIFIED line
// that the whole file-transfer feature rests on: "whether the target host's
// `sshd` has the `sftp` subsystem enabled (not probed)". And the transfer design
// has a second assumption under it — that a plain `cat` over an exec channel is
// a usable fallback when the subsystem is missing. Neither can be settled by
// reading documentation, because both are properties of a running sshd.
//
// `tool/test_sshd.sh` is the right server to ask: its generated config has NO
// `Subsystem` line by default, which is precisely the hardened-host case, so it
// answers the fallback question first and the happy path second (`HP_TEST_SSHD_SFTP=1`
// adds that one line and nothing else).
//
// The numbers are LOOPBACK numbers and must not be quoted as network throughput.
// What they do settle is the SHAPE: whether SFTP streams incrementally or buffers
// the whole file, whether exec can carry bytes at all, and — the finding this
// probe was written to find — whether the CIPHER moves the needle. It does, by
// a factor of thirty-seven. See `docs/research/11-file-transfer-and-pairing.md`.

// Printing IS the output of this file. It is a benchmark that a human runs and
// reads, not a library, and a logging framework would only put a prefix in front
// of the numbers it exists to report.
// ignore_for_file: avoid_print

// the whole file, whether exec can carry bytes at all, and how the two compare
// once the file is far larger than one SSH window.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

const _host = '127.0.0.1';

/// Which throwaway sshd to talk to.
///
/// Two of them, on purpose, because the whole point of this probe is the
/// DIFFERENCE between them. Both come from `tool/test_sshd.sh`, which generates
/// its config with NO `Subsystem` line by default — the hardened host — and with
/// one when `HP_TEST_SSHD_SFTP=1`:
///
///     sh tool/test_sshd.sh start                            # 2222, no sftp
///     HP_TEST_SSHD_PORT=2223 HP_TEST_SSHD_DIR=/tmp/hp-sftp \
///       HP_TEST_SSHD_SFTP=1 sh tool/test_sshd.sh start      # 2223, sftp enabled
///     HP_PORT=2223 dart run tool/probe_sftp.dart
///
/// Same user, same host key shape, one config line apart. Nothing else differs,
/// so any behaviour difference is attributable.
final int _port = int.tryParse(Platform.environment['HP_PORT'] ?? '') ?? 2222;

/// Where the matching private key lives.
final String _keyPath = Platform.environment['HP_KEY'] ??
    (_port == 2223 ? '/tmp/hp-sftp/user_ed25519' : '/tmp/hp-sshd/user_ed25519');

/// Exact byte counts, so a report of "match" means something.
///
/// The fixtures are written to exactly these lengths. An earlier version filled
/// to "at least this many" bytes, which made the probe print `match=false` for a
/// file that had transferred perfectly — an assertion that cannot fail is worse
/// than no assertion, and one that fails when it is right is worse still.
const int _smallBytes = 256 * 1024;
const int _largeBytes = 48 * 1024 * 1024;

/// Which cipher to force, if any.
///
/// The negotiated cipher is the whole reason this probe has a cipher switch at
/// all: the transfer is CPU-bound and the CPU is doing pure-Dart crypto, so
/// WHICH pure-Dart crypto matters enormously. Defaults to null, which leaves
/// dartssh2's own preference list in charge — that is the number that describes
/// the shipping app.
///
/// `HP_CIPHERS` takes a COMMA-SEPARATED, ORDERED list, which is the shape the
/// real fix takes: not "force one cipher" but "reorder the preference list".
/// A single forced cipher proves a cipher is fast; only a reordered list proves
/// the fix works when the server is free to choose.
final String? _cipherName = Platform.environment['HP_CIPHER'];

final List<String> _cipherList = (Platform.environment['HP_CIPHERS'] ?? '')
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// Skips the exec phase. Useful when only the SFTP number is wanted, because
/// the exec phase re-transfers 48 MB and doubles the wall clock.
final bool _sftpOnly = Platform.environment['HP_SFTP_ONLY'] == '1';

Future<void> main() async {
  final keyFile = File(_keyPath);
  if (!keyFile.existsSync()) {
    stderr.writeln('no private key at $_keyPath');
    exit(2);
  }

  const bigPath = '/tmp/hp-probe-large.bin';
  const smallPath = '/tmp/hp-probe-small.txt';
  await _makeFixtures(bigPath, smallPath);

  final socket = await SSHSocket.connect(_host, _port);
  final client = SSHClient(
    socket,
    username: Platform.environment['USER'] ?? '',
    identities: SSHKeyPair.fromPem(keyFile.readAsStringSync()),
    onVerifyHostKey: (type, fingerprint) async => true,
    algorithms: _algorithms(),
  );
  await client.authenticated;

  print('== connected to $_host:$_port (key $_keyPath) ==');
  print('   cpu before: ${_cpuTime()}');

  // ---------------------------------------------------------------- SFTP ---
  print('\n== SFTP ==');
  try {
    final sftp = await client.sftp();
    // THE HANDSHAKE IS THE ONLY REAL ANSWER. `client.sftp()` returns an
    // SftpClient as soon as the channel is opened, BEFORE the server has said
    // anything about the subsystem request — so a host with no `Subsystem sftp`
    // line gets an object that looks fine and then waits forever. Leaving this
    // un-awaited is what made the first run of this probe hang for five minutes
    // with no output past this line.
    final handshake = await sftp.handshake.timeout(const Duration(seconds: 10));
    print('subsystem: AVAILABLE (version ${handshake.version})');

    for (final entry in [
      ('small', smallPath, _smallBytes),
      ('large', bigPath, _largeBytes),
    ]) {
      final (label, path, expected) = entry;
      final bytes = BytesBuilder(copy: false);
      var callbacks = 0;
      final sw = Stopwatch()..start();
      final sink = _CountingSink(bytes, onAdd: () => callbacks++);
      final got = await sftp.download(path, sink, onProgress: (_) {});
      sw.stop();
      print(
        '  $label: sent=$got expected=$expected '
        'chunks=$callbacks ms=${sw.elapsedMilliseconds} '
        'MiB/s=${_rate(got, sw.elapsedMilliseconds)} '
        'match=${bytes.length == expected}',
      );
    }

    // Does `download` respect backpressure, or does it buffer the file? The
    // answer decides whether a 48 MB APK is safe on a phone.
    //
    // READ THE RSS LINE WITH CARE: this probe's sink accumulates every byte in
    // a BytesBuilder so it can verify the count, so the ~190 MiB below is the
    // PROBE's memory, not the library's. `download` itself streams — the app
    // must write to a file (or a hashing sink) and keep the same number flat.
    print('  peak RSS after downloads: ${_rss()}');
    await sftp.close();
  } on Object catch (e) {
    print('subsystem: UNAVAILABLE');
    print('  error type: ${e.runtimeType}');
    print('  message: $e');
  }

  // ---------------------------------------------------------------- exec ---
  if (_sftpOnly) {
    await client.close();
    print('\ncpu at end:      ${_cpuTime()}');
    return;
  }
  print('\n== exec `cat` (the no-subsystem fallback) ==');
  print('   cpu before: ${_cpuTime()}');
  for (final entry in [
    ('small', smallPath, _smallBytes),
    ('large', bigPath, _largeBytes),
  ]) {
    final (label, path, expected) = entry;
    var total = 0;
    var chunks = 0;
    final sw = Stopwatch()..start();
    final session = await client.execute('cat -- $path');
    await for (final chunk in session.stdout) {
      total += chunk.length;
      chunks++;
    }
    // `exitCode` is a SYNCHRONOUS getter that returns null until the exit-status
    // request has arrived, so the two things this line gets right matter:
    // drain stdout FIRST, then wait for the channel to close. `await exitCode`
    // looks like it does this and does not — it is `await` on an `int?`, which
    // yields the same int immediately — and the version of this probe that had
    // that line reported `exit=null` on transfers that had in fact succeeded.
    await session.done;
    final code = session.exitCode;
    sw.stop();
    print(
      '  $label: bytes=$total expected=$expected chunks=$chunks exit=$code '
      'ms=${sw.elapsedMilliseconds} MiB/s=${_rate(total, sw.elapsedMilliseconds)}',
    );
  }

  // ------------------------------------------------------- base64 in exec ---
  // The honest third option: exec + base64, for a far end where the byte
  // channel itself is unusable. It costs a third more on the wire (x1.33) and
  // it is the only path left when both SFTP and raw exec are refused.
  //
  // NOTE the flag: BSD `base64` (macOS) takes `-i <file>` and has no `--`,
  // GNU `base64` takes a positional argument. Neither accepts the other's
  // spelling, so this probe sidesteps the question by piping through stdin,
  // which both understand. A first version passed the path positionally after
  // `--` and silently transferred zero bytes.
  if (!Platform.isMacOS) {
    print('\n== exec `base64` skipped (this probe only wires it for macOS) ==');
  } else {
    print('\n== exec `base64` (works when even the byte channel is dirty) ==');
    var wire = 0;
    final sw = Stopwatch()..start();
    final session = await client.execute(
      'base64 < ${_shellQuote(smallPath)}',
    );
    await for (final chunk in session.stdout) {
      wire += chunk.length;
    }
    await session.done;
    final code = session.exitCode;
    sw.stop();
    print(
      '  small: wire bytes=$wire for $_smallBytes file '
      '(x${(wire / _smallBytes).toStringAsFixed(2)}) exit=$code '
      'ms=${sw.elapsedMilliseconds} MiB/s=${_rate(_smallBytes, sw.elapsedMilliseconds)}',
    );
  }

  await client.close();
  print('\npeak RSS at end: ${_rss()}');
  print('cpu at end:      ${_cpuTime()}');
}

/// The algorithm preference set to connect with.
///
/// With no environment override this is `const SSHAlgorithms()` — dartssh2's
/// own default, which is the one the app ships today.
SSHAlgorithms _algorithms() {
  if (_cipherList.isNotEmpty) {
    return SSHAlgorithms(cipher: _cipherList.map(_cipherByName).toList());
  }
  if (_cipherName != null) return SSHAlgorithms(cipher: [_cipherByName(_cipherName!)]);
  return const SSHAlgorithms();
}

SSHCipherType _cipherByName(String name) {
  for (final c in SSHCipherType.values) {
    if (c.name == name) return c;
  }
  throw ArgumentError(
    'unknown cipher "$name"; known: '
    '${SSHCipherType.values.map((c) => c.name).join(', ')}',
  );
}

/// Single-quotes [path] for the remote shell.
///
/// Duplicated from `lib/data/remote_fs.dart` on purpose: a probe that imports
/// app code is a probe that can be broken by editing the app, and the whole
/// point of this file is to measure the LIBRARY. The escaping is the standard
/// close-quote / escaped-quote / reopen form.
String _shellQuote(String path) => "'${path.replaceAll("'", r"'\''")}'";

/// A sink that counts what it is handed and keeps it, so a short download
/// cannot be mistaken for a fast one.
class _CountingSink implements StreamSink<List<int>> {
  _CountingSink(this._bytes, {required this.onAdd});

  final BytesBuilder _bytes;
  final void Function() onAdd;

  @override
  void add(List<int> data) {
    _bytes.add(data);
    onAdd();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // Rethrown rather than stored: this sink exists to fail the probe loudly if
    // a download errors, and `addError` is the only place it is told.
    throw StateError('sink received an error: $error');
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(add);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}

double _rate(int bytes, int ms) {
  if (ms <= 0) return double.infinity;
  return bytes / 1024 / 1024 / (ms / 1000);
}

String _rss() {
  final result = Process.runSync('ps', ['-o', 'rss=', '-p', '$pid']);
  final kb = int.tryParse((result.stdout as String).trim()) ?? 0;
  return '${(kb / 1024).toStringAsFixed(1)} MiB';
}

/// Cumulative CPU time of THIS process, as `ps` prints it.
///
/// The number that tells crypto apart from latency. A transfer that is slow
/// because it waits on a socket burns almost no CPU; one that is slow because
/// every 32 KiB packet is decrypted in Dart burns a whole core for the whole
/// transfer. Wall-clock alone cannot distinguish the two, and the fix for each
/// is completely different.
String _cpuTime() {
  final result = Process.runSync('ps', ['-o', 'time=', '-p', '$pid']);
  return (result.stdout as String).trim();
}

Future<void> _makeFixtures(String bigPath, String smallPath) async {
  // A 64-byte line of repeating ASCII plus a newline: 65 bytes, which does not
  // divide either fixture size, so the final write is always a partial one.
  final line = Uint8List.fromList(
    List<int>.generate(64, (i) => 0x41 + (i % 26))..add(0x0A),
  );

  await _writeExactly(File(bigPath), _largeBytes, line);
  await _writeExactly(
    File(smallPath),
    _smallBytes,
    Uint8List.fromList('hello from herdr pocket\n'.codeUnits),
  );
}

/// Writes exactly [total] bytes to [file], truncating any longer leftover.
Future<void> _writeExactly(File file, int total, Uint8List line) async {
  if (file.existsSync() && file.lengthSync() == total) return;
  final sink = file.openWrite();
  var written = 0;
  while (written < total) {
    final take = total - written < line.length ? total - written : line.length;
    sink.add(take == line.length ? line : Uint8List.sublistView(line, 0, take));
    written += take;
  }
  await sink.close();
}
