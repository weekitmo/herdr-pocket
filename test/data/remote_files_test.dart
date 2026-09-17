import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/remote_files.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// What an `@` reference can point at.
///
/// The listing is one command whose reply becomes a menu, so the two things that
/// matter are the generated shell (asserted as text, because a bad `$` is a
/// silently wrong command rather than a compile error) and the three outcomes the
/// menu has to keep apart: paths, an empty directory, and a directory that is
/// gone.
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
  group('the generated script', () {
    final command = RemoteFileIndex.buildScript(cwd: '/home/u/my project');

    test('is handed to a POSIX shell like the capability probe', () {
      // This command has no globs today, so it does not NEED the wrapper — it
      // is wrapped so that the next glob somebody adds is not a bug on half the
      // machines. See `posixShellCommand`.
      expect(
        RemoteFileIndex.buildCommand(cwd: '/home/u'),
        startsWith('/bin/sh -c '),
      );
    });

    test('asks git first, and falls back to a bounded walk', () {
      expect(command, contains("git -C '/home/u/my project'"));
      expect(command, contains('ls-files --cached --others --exclude-standard'));
      expect(command, contains('find . -maxdepth 5 -type f'));
      // Never `node_modules`, and never the repository's own bookkeeping.
      expect(command, contains(r"'./.git/*'"));
      expect(command, contains(r"'*/node_modules/*'"));
    });

    test('both branches are capped, and the cap is a number', () {
      expect('head -n 2000'.allMatches(command), hasLength(2));
      expect(command, isNot(contains(r'$maxPaths')));
    });

    test('a directory that is gone says so, with a marker', () {
      // Not an exit code: `head` owns a pipeline's status, so a failed `cd`
      // would arrive as zero — i.e. as "this folder is empty", which is a
      // different sentence with a much worse answer.
      expect(command, contains('cd ${quoteRemotePath('/home/u/my project')} 2>/dev/null'));
      expect(command, contains("printf '${RemoteFileIndex.noDirectoryMarker}\\n'"));
    });

    test('ends with the sentinel the transport looks for', () {
      expect(command, endsWith("printf '$remoteExitMarkerEscape%s' \"\$?\""));
    });
  });

  group('reading the listing', () {
    test('paths come back in order, deduped, without stray returns', () async {
      final runner = _FakeRunner(
        _reply('lib/main.dart\r\nlib/app.dart\nlib/main.dart\n\n'),
      );
      final result = await RemoteFileIndex(runner).list('/home/u/proj');
      expect(
        (result as FileIndexFound).paths,
        ['lib/main.dart', 'lib/app.dart'],
      );
    });

    test('a directory with nothing to reference is its own outcome', () async {
      final result = await RemoteFileIndex(_FakeRunner(_reply(''))).list('/home/u/proj');
      expect(result, isA<FileIndexEmpty>());
    });

    test('the marker becomes an unreadable directory, not an empty one', () async {
      final runner = _FakeRunner(_reply('${RemoteFileIndex.noDirectoryMarker}\n'));
      final result = await RemoteFileIndex(runner).list('/home/u/gone');
      expect(result, isA<FileIndexUnreadable>());
      expect((result as FileIndexUnreadable).detail, contains('/home/u/gone'));
    });

    test('a reply without the sentinel is unreadable', () async {
      final runner = _FakeRunner('lib/main.dart\n');
      final result = await RemoteFileIndex(runner).list('/home/u/proj');
      expect(result, isA<FileIndexUnreadable>());
    });

    test('a transport failure is reported rather than thrown', () async {
      final result = await RemoteFileIndex(_ThrowingRunner()).list('/home/u/proj');
      expect(result, isA<FileIndexUnreadable>());
    });

    test('a relative directory runs nothing at all', () async {
      // A `.` here would resolve against the login shell's own directory, and
      // the menu would offer files from somewhere the user is not looking.
      final runner = _FakeRunner(_reply('x\n'));
      final result = await RemoteFileIndex(runner).list('.');
      expect(result, isA<FileIndexUnreadable>());
      expect(runner.commands, isEmpty);
    });
  });
}

class _ThrowingRunner implements RemoteCommandRunner {
  @override
  Future<String> runCommand(String command) async {
    throw HerdrTransportException(TransportFailure.unknown, 'the channel died');
  }
}
