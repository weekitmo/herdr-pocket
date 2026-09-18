import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/files/file_meta.dart';

/// The metadata COMMAND, asserted as text.
///
/// A generated shell is the one thing here that can fail with no exception and
/// no visible symptom: a wrong flag still returns a string, and the sheet still
/// draws — with the wrong numbers in it.
class _FakeRunner implements RemoteCommandRunner {
  _FakeRunner(this.stdout);

  String stdout;
  final List<String> commands = <String>[];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    return stdout;
  }
}

String _reply(String body) => '$body$remoteExitMarker' '0';

void main() {
  test('asks GNU stat first and BSD second, in that order', () async {
    // The order is the whole command. On GNU, `-f` means "file system" and
    // SUCCEEDS — so a BSD-first command on a Linux box does not fail, it
    // returns a filesystem record, and the sheet would show its fields as a
    // file's size and dates.
    final runner = _FakeRunner(_reply('1\t2\t3\t-rw-\tu\tg\n'));
    await RemoteFs(runner).stat('/tmp/x');

    final command = runner.commands.single;
    final gnu = command.indexOf("stat -c '");
    final bsd = command.indexOf("stat -f '");
    expect(gnu, greaterThanOrEqualTo(0));
    expect(bsd, greaterThan(gnu));
    expect(command, contains('||'));
  });

  test('the six fields are separated by a real tab', () async {
    // Measured on this machine: BSD `stat` does NOT expand `\t` in its format
    // string, so a command carrying the two characters `\` `t` comes back as a
    // single field and every read fails as "no usable record".
    final runner = _FakeRunner(_reply('1\t2\t3\t-rw-\tu\tg\n'));
    await RemoteFs(runner).stat('/tmp/x');

    final command = runner.commands.single;
    expect(command, contains('\t'));
    expect(command, isNot(contains(r'\t')));
  });

  test('quotes the path, so a hostile filename is a name', () async {
    final runner = _FakeRunner(_reply('1\t2\t3\t-rw-\tu\tg\n'));
    RemoteFs(runner).stat("/tmp/it's here").ignore();

    expect(runner.commands.single, contains(r"'/tmp/it'\''s here'"));
  });

  test('the same six fields, in the same order, in both dialects', () async {
    final runner = _FakeRunner(_reply('1\t2\t3\t-rw-\tu\tg\n'));
    await RemoteFs(runner).stat('/tmp/x');
    final command = runner.commands.single;

    const gnuFormat = '%s\t%Y\t%W\t%A\t%U\t%G';
    const bsdFormat = '%z\t%m\t%B\t%Sp\t%Su\t%Sg';
    expect(command, contains(gnuFormat));
    expect(command, contains(bsdFormat));
  });

  test('parses a good reply into metadata', () async {
    final runner = _FakeRunner(_reply('2048\t1700000000\t0\t-rw-r--r--\tme\tstaff\n'));
    final meta = await RemoteFs(runner).stat('/tmp/x');

    expect(meta.sizeBytes, 2048);
    expect(meta.owner, 'me');
    expect(meta.created, isNull);
  });

  test('a failing stat throws rather than inventing a record', () async {
    final runner = _FakeRunner('stat: /nope: No such file or directory\n$remoteExitMarker' '1');
    await expectLater(
      RemoteFs(runner).stat('/nope'),
      throwsA(isA<RemoteFsException>()),
    );
  });

  test('a truncated reply (no sentinel) throws too', () async {
    final runner = _FakeRunner('1\t2\t3\t-rw-\tu\tg\n');
    await expectLater(
      RemoteFs(runner).stat('/tmp/x'),
      throwsA(isA<RemoteFsException>()),
    );
  });

  test('a reply with no usable record throws', () async {
    final runner = _FakeRunner(_reply('garbage\n'));
    await expectLater(
      RemoteFs(runner).stat('/tmp/x'),
      throwsA(isA<RemoteFsException>()),
    );
  });

  group('against a real shell', () {
    // The one thing a fake runner cannot check is whether the generated command
    // is a command. The two dialects are covered by accident here, and that is
    // the point: CI is Linux (GNU `stat -c`) and the development machine is
    // macOS (BSD `stat -f`), so this test exercises a different branch on each
    // — the same split its `||` exists for.
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('herdr_stat'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the command the app sends is one a shell can actually run', () async {
      final file = File('${dir.path}/probe.txt')..writeAsStringSync('hello\n');
      final runner = _FakeRunner(_reply('1\t2\t3\t-rw-\tu\tg\n'));
      await RemoteFs(runner).stat(file.path);

      final result = await Process.run('/bin/sh', ['-c', runner.commands.single]);
      final stdout = result.stdout as String;
      final (body, exitCode) = splitTrailingSentinel(stdout);

      expect(exitCode, 0, reason: '$stdout\n${result.stderr}');
      final meta = parseFileMeta(body);
      expect(meta, isNotNull, reason: body);
      expect(meta!.sizeBytes, 6);
      expect(meta.kind, RemoteFileKind.file);
      expect(meta.permissions, isNotNull);
    });

    test('a path that does not exist reports a non-zero status', () async {
      final runner = _FakeRunner(_reply('1\t2\t3\t-rw-\tu\tg\n'));
      await RemoteFs(runner).stat('${dir.path}/nope.txt');

      final result = await Process.run('/bin/sh', ['-c', runner.commands.single]);
      final (_, exitCode) = splitTrailingSentinel(result.stdout as String);
      expect(exitCode, isNot(0));
    });
  });
}
