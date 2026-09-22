import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/git_client.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/git/git_diff.dart';

/// A stand-in for the SSH channel that runs the commands for real.
///
/// It RECORDS what it was asked to run, and that recording is the point: the
/// shell strings these classes build are the security boundary, and asserting on
/// the exact string is the only way a regression in quoting fails the build
/// instead of waiting to be noticed on a machine whose filenames are hostile.
class FakeRunner implements RemoteCommandRunner {
  FakeRunner({this.stdout = '', this.onRun});

  /// What every command answers, unless [onRun] says otherwise.
  String stdout;

  /// Per-command answer, when one canned string is not enough.
  final String Function(String command)? onRun;

  /// Every command, in order.
  final List<String> commands = <String>[];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    return onRun?.call(command) ?? stdout;
  }

  /// The only command that was run. Fails the test if there were others.
  String get onlyCommand {
    expect(commands, hasLength(1), reason: 'expected exactly one command');
    return commands.single;
  }
}

/// Appends git's own exit sentinel the way the real command does.
///
/// Reproduced here rather than imported so the tests exercise the FORMAT the
/// shell actually produces, including the leading newline — a test that used a
/// different shape would pass while the app failed.
String sentinel(int code, {String body = ''}) => '$body$remoteExitMarker$code';

/// The marker's bytes as they appear inside a COMMAND.
///
/// Deliberately spelled out rather than imported: the bytes ARE the assertion.
/// Three things must hold at once, and each has its own way to fail silently.
///
///   1. The newline is the two characters `\` `n`, never a real one — a real
///      newline would split the command into two shell commands.
///   2. The section signs are LITERAL. macOS's `printf` has no `\u` escape and
///      would print the characters `\u00a7` instead, so the marker would never
///      be found in the output.
///   3. `remoteExitMarker` (the constant the PARSER uses) contains the real
///      newline `printf` produces, and matches this once `printf` has run.
const commandMarker = r'\n§EXIT§';

/// The exact string [RemoteFs] must send to read one file.
///
/// Written out in full, by hand, because that is the assertion. If the command
/// builder changes, this test should be the thing that argues about it.
String readCommand(String quotedPath, int byteCount) =>
    'head -c $byteCount -- $quotedPath 2>/dev/null; '
    "printf '$commandMarker%s' \"\$?\"";

/// Fails when a command would be read as more than one command.
void expectOneLine(String command) {
  expect(
    command.contains('\n'),
    isFalse,
    reason: 'the sentinel must be ESCAPED in the command, not a real newline: '
        '$command',
  );
}

void main() {
  group('looksBinary', () {
    test('an empty sample is not binary', () {
      expect(looksBinary(<int>[]), isFalse);
    });

    test('plain ASCII text is not binary', () {
      expect(looksBinary(utf8.encode('hello\nworld\n')), isFalse);
    });

    test('CJK text is NOT binary, even though every byte is above 0x7F', () {
      // The case that matters most here: counting high bytes as non-text would
      // report every Chinese file as binary, in an app whose default locale is
      // Simplified Chinese.
      expect(looksBinary(utf8.encode('你好，世界\n这是中文。\n')), isFalse);
    });

    test('tabs, CR and LF are text', () {
      expect(looksBinary(utf8.encode('\tcolumn\tcolumn\r\n')), isFalse);
    });

    test('a single NUL byte in a leading text run is binary', () {
      // The strong signal, and the one `file(1)` uses. Fourteen characters of
      // perfectly good text do not outvote one NUL.
      final bytes = <int>[...utf8.encode('plain text here'), 0, 0x01];
      expect(looksBinary(bytes), isTrue);
    });

    test('a NUL past the 8 KB sample does not make the head binary', () {
      // Detection is a heuristic over the head of the file, deliberately: the
      // alternative is reading the whole thing on the far end.
      final bytes = <int>[...utf8.encode('a' * (RemoteFs.binarySampleBytes + 10)), 0];
      expect(looksBinary(bytes), isFalse);
    });

    test('fewer than 30% control bytes is tolerated', () {
      // 20% control bytes: a text file with a handful of odd characters.
      final bytes = <int>[...utf8.encode('x' * 80), ...List.filled(20, 0x01)];
      expect(looksBinary(bytes), isFalse);
    });

    test('more than 30% control bytes is binary', () {
      // 40% control bytes, no NUL anywhere.
      final bytes = <int>[...utf8.encode('x' * 60), ...List.filled(40, 0x01)];
      expect(looksBinary(bytes), isTrue);
    });

    test('the ratio is over the sample available, not a fixed 8 KB', () {
      // A forty-byte file that is half control bytes is still binary. Dividing
      // by the nominal sample size would let short binary stubs through.
      final bytes = <int>[...utf8.encode('x' * 20), ...List.filled(20, 0x01)];
      expect(looksBinary(bytes), isTrue);
    });

    test('a real PNG is binary', () {
      // Verified against the icon files in this repository: the first 8 KB of
      // `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png`
      // reads as binary under this heuristic.
      //
      // The signature ALONE is not enough, and that is a property of the ratio
      // rather than a bug — see the next test.
      const pngHeader = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, // IHDR length
        0x49, 0x48, 0x44, 0x52, // "IHDR"
        0x00, 0x00, 0x04, 0x00, // width 1024
        0x00, 0x00, 0x04, 0x00, // height 1024
      ];
      expect(looksBinary(pngHeader), isTrue);
    });

    test('the raw 8-byte signature is too short to classify', () {
      // Documented rather than papered over: five non-text bytes out of eight is
      // 62%, but the heuristic's NUL check is what makes the ratio safe to keep
      // conservative, and an eight-byte sample is below the ratio's resolution.
      // A real image is always read at 8 KB, where this cannot arise.
      const signatureOnly = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      expect(looksBinary(signatureOnly), isFalse);
    });

    test('a long UTF-8 CJK document is text, byte for byte', () {
      // The case the heuristic must not get wrong: every byte above 0x7F, no
      // NUL, valid multi-byte sequences throughout.
      final cjk = utf8.encode('中文测试行，这是一段中文文本。\n' * 200);
      expect(cjk.length, greaterThan(RemoteFs.binarySampleBytes));
      expect(looksBinary(cjk), isFalse);
    });
  });

  group('quoteRemotePath', () {
    test('a plain path is wrapped in single quotes', () {
      expect(quoteRemotePath('/tmp/a.txt'), "'/tmp/a.txt'");
    });

    test('spaces need no escaping inside single quotes', () {
      expect(quoteRemotePath('/x/my notes.txt'), "'/x/my notes.txt'");
    });

    test('a double quote needs no escaping', () {
      // Inside single quotes a `"` is literal, which is why leaving it alone is
      // correct rather than lazy.
      expect(quoteRemotePath('/x/a"b'), "'/x/a\"b'");
    });

    test('a single quote closes, escapes and reopens', () {
      expect(quoteRemotePath("/x/it's"), r"'/x/it'\''s'");
    });

    test('command substitution is inert inside single quotes', () {
      expect(quoteRemotePath(r'/x/$(rm -rf ~)'), r"'/x/$(rm -rf ~)'");
      expect(quoteRemotePath(r'/x/$(a)'), r"'/x/$(a)'");
    });

    test('backticks are inert inside single quotes', () {
      expect(quoteRemotePath('/x/`whoami`'), "'/x/`whoami`'");
    });

    test('a classic injection attempt stays one literal word', () {
      // The whole point: this is a FILENAME. Closing the quote early would turn
      // the rest into a command.
      const hostile = "'; rm -rf ~; echo '";
      final quoted = quoteRemotePath(hostile);
      expect(quoted, r"''\''; rm -rf ~; echo '\'''");

      // Every quote in the result is paired: the shell sees one word.
      expect(_balancedSingleQuotes(quoted), isTrue);
    });

    test('several quotes in a row stay balanced', () {
      final quoted = quoteRemotePath("''''''");
      expect(_balancedSingleQuotes(quoted), isTrue);
    });

    test('a NUL byte is rejected', () {
      expect(
        () => quoteRemotePath('/x/a\u0000b'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a newline is rejected', () {
      expect(
        () => quoteRemotePath('/x/a\nb'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a carriage return is rejected', () {
      expect(
        () => quoteRemotePath('/x/a\rb'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an empty path is rejected', () {
      expect(() => quoteRemotePath(''), throwsA(isA<ArgumentError>()));
    });

    test('high bytes survive byte for byte', () {
      // A CJK filename must round-trip: quoting is not escaping, and mangling
      // it would make a Chinese working directory unusable.
      expect(quoteRemotePath('/x/项目/笔记.md'), "'/x/项目/笔记.md'");
    });
  });

  group('RemoteFs.read', () {
    test('issues one command, with the byte limit and a quoted path', () async {
      const path = '/tmp/a.txt';
      final runner = FakeRunner(stdout: sentinel(0, body: 'hello\n'));
      final fs = RemoteFs(runner, maxBytes: 262144);

      final result = await fs.read(path);

      expect(
        runner.onlyCommand,
        readCommand("'/tmp/a.txt'", 262145),
        reason: 'the request is the cap plus one, so truncation is visible',
      );
      expect(result, isA<RemoteFileContent>());
      expect((result as RemoteFileContent).content, 'hello');
      expect(result.truncated, isFalse);
    });

    test('a trailing newline is not doubled and not lost', () async {
      final runner = FakeRunner(stdout: sentinel(0, body: 'a\nb\n'));
      final result = await RemoteFs(runner).read('/tmp/a.txt')
          as RemoteFileContent;

      expect(result.content, 'a\nb');
      // The shell's `printf` adds one newline; the file's own newline is the
      // one that was already there. The count is of the FILE, so a file ending
      // in a newline is three bytes of text plus its terminator — not four
      // characters plus a separator that was never in the file.
      expect(result.byteCount, 3);
      expect(result.fileEndsWithNewline, isTrue);
    });

    test('a file with no trailing newline keeps its last line', () async {
      final runner = FakeRunner(stdout: sentinel(0, body: 'a\nb'));
      final result = await RemoteFs(runner).read('/tmp/a.txt')
          as RemoteFileContent;

      expect(result.content, 'a\nb');
      expect(result.byteCount, 3);
      expect(result.fileEndsWithNewline, isFalse);
    });

    test('an empty file reports empty, not a failure', () async {
      final runner = FakeRunner(stdout: sentinel(0));
      expect(await RemoteFs(runner).read('/tmp/a.txt'), isA<RemoteFileEmpty>());
    });

    test('a file that is only a newline is empty, not one blank line', () async {
      final runner = FakeRunner(stdout: sentinel(0, body: '\n'));
      expect(await RemoteFs(runner).read('/tmp/a.txt'), isA<RemoteFileEmpty>());
    });

    test('a binary file is reported as binary and its bytes are dropped',
        () async {
      // A NUL in the middle, which is what `file(1)` would call binary.
      final body = String.fromCharCodes([0x41, 0x00, 0x42]);
      final runner = FakeRunner(stdout: sentinel(0, body: body));

      final result = await RemoteFs(runner).read('/tmp/blob');

      expect(result, isA<RemoteFileBinary>());
      // The content is NOT carried: rendering a decoded blob as text invites the
      // reader to believe it.
      expect((result as RemoteFileBinary).byteCount, 3);
    });

    test('truncation is reported when the file is larger than the limit',
        () async {
      // One byte more than the cap, which is exactly what `head -c limit+1`
      // gives for a file that continues.
      final body = 'x' * 11;
      final runner = FakeRunner(stdout: sentinel(0, body: body));
      final fs = RemoteFs(runner, maxBytes: 10);

      final result = await fs.read('/tmp/big') as RemoteFileContent;

      expect(result.truncated, isTrue);
      expect(result.content, 'x' * 10,
          reason: 'one byte past the cap is the evidence; it is not shown');
      expect(result.byteCount, 10);
    });

    test('a file exactly at the limit is not truncated', () async {
      final runner = FakeRunner(stdout: sentinel(0, body: 'x' * 10));
      final fs = RemoteFs(runner, maxBytes: 10);

      final result = await fs.read('/tmp/exact') as RemoteFileContent;

      expect(result.truncated, isFalse);
      expect(result.content, 'x' * 10);
      expect(result.byteCount, 10);
    });

    test('a truncated read that cuts a multi-byte character does not throw',
        () async {
      // `head -c 10` on a CJK file cuts a three-byte character in half, so the
      // decoder is handed an incomplete scalar. It must substitute, not throw:
      // the preview is still worth showing.
      const body = '你好世界再见';
      final bytes = utf8.encode(body);
      final cut = String.fromCharCodes(bytes.sublist(0, 10));
      final runner = FakeRunner(stdout: sentinel(0, body: cut));
      final fs = RemoteFs(runner, maxBytes: 9);

      final result = await fs.read('/tmp/cjk') as RemoteFileContent;

      expect(result.truncated, isTrue);
      expect(result.content, isNotEmpty);
    });

    test('a missing file is a failure with a reason, not a throw', () async {
      // `head` exits 1 for "no such file" and for "is a directory" alike.
      final runner = FakeRunner(stdout: sentinel(1));

      final result = await RemoteFs(runner).read('/tmp/nope');

      expect(result, isA<RemoteReadFailed>());
      expect((result as RemoteReadFailed).reason, RemoteReadFailure.notFound);
    });

    test('an unreadable file maps to permissionDenied', () async {
      final runner = FakeRunner(stdout: sentinel(126));

      final result = await RemoteFs(runner).read('/root/secret')
          as RemoteReadFailed;

      expect(result.reason, RemoteReadFailure.permissionDenied);
    });

    test('a reply with no sentinel is a failure, never a silent empty file',
        () async {
      // What a truncated channel looks like. Returning empty content would
      // present a connection problem as an empty file.
      final runner = FakeRunner(stdout: 'partial output with no sentinel');

      expect(
        await RemoteFs(runner).read('/tmp/a.txt'),
        isA<RemoteReadFailed>(),
      );
    });

    test('a missing sentinel at the very start is not mistaken for one',
        () async {
      // The sentinel never starts at offset zero in real output, and the parser
      // relies on that: a file that literally begins with the marker text must
      // not have its head chopped off.
      final runner = FakeRunner(
        stdout: '${remoteExitMarker}0 trailing text',
      );

      final result = await RemoteFs(runner).read('/tmp/odd');

      expect(result, isA<RemoteReadFailed>());
    });

    test('a file containing the marker mid-content still parses', () async {
      const content = 'before\n§EXIT§9 after\n'; // A file that mentions it.
      final runner = FakeRunner(stdout: sentinel(0, body: content));

      final result = await RemoteFs(runner).read('/tmp/a.txt')
          as RemoteFileContent;

      expect(result.content, 'before\n§EXIT§9 after');
    });

    test('a reply longer than the cap is cut, and the cut is reported', () async {
      // The far end returned a full 1 KB for a request of 11 bytes. Nothing
      // needs to be guessed: exactly one byte over the cap is the truncation
      // signal, so the text is cut at the cap and the flag says so. A retry
      // here would be unreachable code — with a one-byte margin, "complete" and
      // "oversized" cannot both be true.
      final runner = FakeRunner(stdout: sentinel(0, body: 'y' * 1024));

      final result = await RemoteFs(runner, maxBytes: 10).read('/tmp/odd')
          as RemoteFileContent;

      expect(runner.commands, hasLength(1));
      expect(result.truncated, isTrue);
      expect(result.content, 'y' * 10);
      expect(result.byteCount, 10);
    });

    test('a hostile path is quoted, never interpolated', () async {
      const hostile = "/tmp/it's; rm -rf ~";
      final runner = FakeRunner(stdout: sentinel(0, body: 'x\n'));

      await RemoteFs(runner).read(hostile);

      expect(
        runner.onlyCommand,
        contains(r"'/tmp/it'\''s; rm -rf ~'"),
        reason: 'the path must arrive as ONE shell word',
      );
    });

    test('a zero or negative limit is a programming error, and throws', () {
      final fs = RemoteFs(FakeRunner());
      expect(() => fs.read('/tmp/a', maxBytes: 0), throwsA(isA<ArgumentError>()));
    });
  });

  group('RemoteFs.list', () {
    test('issues one command with a quoted path', () async {
      final runner = FakeRunner(stdout: '');
      await RemoteFs(runner).list('/tmp/dir');

      expect(
        runner.onlyCommand,
        "LC_ALL=C ls -lA -- '/tmp/dir' 2>/dev/null "
        "|| printf '$remoteListFailureMarker'",
      );
      expectOneLine(runner.onlyCommand);
    });

    test('a failed listing throws rather than reporting an empty directory',
        () async {
      // This is the whole reason `list` throws where `read` returns a value: an
      // empty list would render as "this folder is empty", which is a different
      // and false statement.
      final runner = FakeRunner(stdout: remoteListFailureMarker);

      expect(
        () => RemoteFs(runner).list('/tmp/nope'),
        throwsA(isA<RemoteFsException>()),
      );
    });

    test('directories sort before files, then case-insensitively', () async {
      // Real `ls -lA --` output shape from macOS, with the `.__pb` files that
      // macOS actually puts in a directory.
      final runner = FakeRunner(
        stdout: 'total 8\n'
            'drwxr-xr-x   3 me  staff    96 Jan  4 10:00 zeta\n'
            '-rw-r--r--   1 me  staff    12 Jan  4 10:00 beta.txt\n'
            'drwxr-xr-x   2 me  staff    64 Jan  4 10:00 Alpha\n'
            '-rw-r--r--   1 me  staff   100 Jan  4 10:00 AAA.md\n',
      );

      final entries = await RemoteFs(runner).list('/tmp/dir');

      expect(entries.map((e) => e.name).toList(), [
        'Alpha',
        'zeta',
        'AAA.md',
        'beta.txt',
      ]);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.isDirectory, isFalse);
    });

    test('a real macOS capture parses, including sizes', () async {
      // Captured from `ls -lA -- /tmp/gitcap` on this machine.
      final runner = FakeRunner(
        stdout: 'total 32\n'
            '-rw-r--r--   1 kit  wheel    7 Jan  4 11:22 a.txt\n'
            'drwxr-xr-x   4 kit  wheel  128 Jan  4 11:22 sub\n'
            'lrwxr-xr-x   1 kit  wheel    5 Jan  4 11:22 link -> a.txt\n',
      );

      final entries = await RemoteFs(runner).list('/tmp/gitcap');

      expect(entries, hasLength(3));
      expect(entries[0].name, 'sub');
      expect(entries[0].isDirectory, isTrue);
      expect(entries[0].sizeBytes, isNull, reason: 'a directory has no size here');

      final file = entries[1];
      expect(file.name, 'a.txt');
      expect(file.isDirectory, isFalse);
      expect(file.sizeBytes, 7);

      // `-l` appends ` -> target` to a symlink's name. The name is the entry's
      // identity, so the suffix is cut — but ONLY for a link, because `a -> b`
      // is a legal name for a regular file, and the entry it names is `link`,
      // not `a.txt`.
      final link = entries[2];
      expect(link.isLink, isTrue);
      expect(link.isDirectory, isFalse);
      expect(link.name, 'link', reason: 'the target is cut off the name');
    });

    test('a filename with a space: the name survives, the size does not', () {
      // `ls -l` separates its columns with RUNS of spaces and prints the name
      // last, so a name containing a space cannot be told apart from extra
      // column padding BY COUNTING. It can by ANCHORING: the name is the last
      // run of non-space characters, and everything from its start offset
      // onwards is the name — which recovers `my notes.txt` intact.
      //
      // The size needs a correction for it: it is found by field index from the
      // end, and one extra name field shifts it onto the month column. Without
      // accounting for the name's token count the size reads as `Jan`, and
      // `int.tryParse('Jan')` -> null, which is how this was found.
      final entry = RemoteDirEntry.parse(
        '-rw-r--r--   1 me  staff    12 Jan  4 11:22 my notes.txt',
      );

      expect(entry!.name, 'my notes.txt');
      expect(entry.sizeBytes, 12);
    });

    test('unparseable lines are skipped, not turned into entries', () async {
      // A shell startup file printing a greeting is the realistic case.
      final runner = FakeRunner(
        stdout: 'Welcome to the machine\n'
            'ls: cannot open directory\n'
            '-rw-r--r--   1 me  staff    12 Jan  4 11:22 real.txt\n',
      );

      final entries = await RemoteFs(runner).list('/tmp/dir');

      expect(entries.map((e) => e.name).toList(), ['real.txt']);
    });
  });

  group('date parsing edge: two-digit days', () {
    test('a single-digit day (two spaces) parses like any other row', () {
      // `ls -l` prints `Jan  4` with TWO spaces for days 1-9. THIS is the case a
      // naive `split(' ')` turns into an empty field and then reads the month as
      // the size.
      final entry = RemoteDirEntry.parse(
        '-rw-r--r--   1 me  staff     5 Jan  4 09:00 a.txt',
      );

      expect(entry!.name, 'a.txt');
      expect(entry.sizeBytes, 5);
    });
  });

  group('GitClient command strings', () {
    test('isAvailable runs git with a pinned locale', () async {
      final runner = FakeRunner(stdout: sentinel(0, body: 'git version 2.53.0\n'));

      expect(await GitClient(runner).isAvailable(), isTrue);
      expect(
        runner.onlyCommand,
        'LC_ALL=C git --version 2>/dev/null; printf \'$commandMarker%s\' "\$?"',
      );
      expectOneLine(runner.onlyCommand);
    });

    test('isAvailable is false when git is missing, not an exception', () async {
      final runner = FakeRunner(stdout: sentinel(127));
      expect(await GitClient(runner).isAvailable(), isFalse);
    });

    test('repoRoot quotes the cwd', () async {
      final runner = FakeRunner(stdout: sentinel(0, body: '/tmp/repo\n'));

      expect(await GitClient(runner).repoRoot('/tmp/repo/sub'), '/tmp/repo');
      expect(
        runner.onlyCommand,
        "LC_ALL=C git -C '/tmp/repo/sub' rev-parse --show-toplevel "
        "2>/dev/null; printf '$commandMarker%s' \"\$?\"",
      );
      expectOneLine(runner.onlyCommand);
    });

    test('repoRoot returns null when git refuses', () async {
      final runner = FakeRunner(stdout: sentinel(128));
      expect(await GitClient(runner).repoRoot('/tmp'), isNull);
    });

    test('status runs the exact porcelain command', () async {
      final runner = FakeRunner(
        stdout: sentinel(0, body: '# branch.head main\x00'),
      );

      final result = await GitClient(runner).status('/tmp/repo');

      expect(
        runner.onlyCommand,
        "LC_ALL=C git -C '/tmp/repo' status --porcelain=v2 --branch "
        '--untracked-files=all -z 2>/dev/null; '
        "printf '$commandMarker%s' \"\$?\"",
      );
      expectOneLine(runner.onlyCommand);
      expect(result, isA<GitStatusBody>());
      expect((result as GitStatusBody).status.branch, 'main');
    });

    test('the leading newline of the sentinel is not part of the status',
        () async {
      // `git status -z` ends with a NUL, so the sentinel's newline is the only
      // thing between the last record and the marker. Keeping it would leave a
      // stray NUL-prefixed record behind.
      final runner = FakeRunner(
        stdout: sentinel(0, body: '# branch.head main\x00? stray.txt\x00'),
      );

      final result = await GitClient(runner).status('/tmp/repo')
          as GitStatusBody;

      expect(result.status.entries.single.path, 'stray.txt');
    });

    test('exit 128 is "not a repository", distinct from "no git"', () async {
      final noRepo = FakeRunner(stdout: sentinel(128));
      final noGit = FakeRunner(stdout: sentinel(127));

      final a = await GitClient(noRepo).status('/tmp') as GitStatusFailure;
      final b = await GitClient(noGit).status('/tmp') as GitStatusFailure;

      expect(a.reason, GitFailure.notARepository);
      expect(b.reason, GitFailure.notInstalled);
      expect(a.reason, isNot(b.reason));
    });

    test('an unrecognised localised message does not change the verdict',
        () async {
      // On this machine `git -C /tmp status` prints 致命错误：不是 Git 仓库 — the
      // message is translated and would be a terrible thing to match on. The
      // exit code is what decides.
      final runner = FakeRunner(stdout: sentinel(128, body: '致命错误：不是 Git 仓库\n'));

      final result = await GitClient(runner).status('/tmp') as GitStatusFailure;

      expect(result.reason, GitFailure.notARepository);
    });

    test('a reply with no exit code is a failure, not a clean tree', () async {
      final runner = FakeRunner(stdout: 'not a status at all');

      final result = await GitClient(runner).status('/tmp/repo');

      expect(result, isA<GitStatusFailure>());
      expect((result as GitStatusFailure).reason, GitFailure.unknown);
    });

    test('diff for one path runs plain git diff with a separator', () async {
      final runner = FakeRunner(stdout: sentinel(0));

      await GitClient(runner).diff('/tmp/repo', path: 'src/a.dart');

      expect(
        runner.onlyCommand,
        "LC_ALL=C git -C '/tmp/repo' diff --no-color --patch "
        "-- 'src/a.dart' 2>/dev/null; printf '$commandMarker%s' \"\$?\"",
      );
      expectOneLine(runner.onlyCommand);
    });

    test('staged diff adds --cached', () async {
      final runner = FakeRunner(stdout: sentinel(0));

      await GitClient(runner).diff('/tmp/repo', path: 'a.txt', staged: true);

      expect(runner.onlyCommand, contains('diff --no-color --patch --cached'));
      expect(runner.onlyCommand, contains("-- 'a.txt'"));
    });

    test('a whole-tree diff has no path separator', () async {
      final runner = FakeRunner(stdout: sentinel(0));

      await GitClient(runner).diff('/tmp/repo');

      expect(runner.onlyCommand, isNot(contains(' -- ')));
    });

    test('diff output is parsed and its truncation reported honestly',
        () async {
      final runner = FakeRunner(
        stdout: sentinel(
          0,
          body: 'diff --git a/a.txt b/a.txt\n'
              '@@ -1 +1,2 @@\n'
              ' one\n'
              '+two\n',
        ),
      );

      final result = await GitClient(runner).diff('/tmp/repo', path: 'a.txt')
          as GitDiffBody;

      expect(result.truncated, isFalse);
      expect(result.diff.hunks, hasLength(1));
      expect(result.diff.addedCount, 1);
      // The line's marker is stripped by the PARSER, so the renderer never has
      // to re-derive it and cannot get it wrong.
      expect(result.diff.hunks.single.lines.first.text, 'one');
      expect(
        result.diff.hunks.single.lines.first.type,
        GitDiffLineType.context,
      );
    });

    test('a huge diff is capped and says so', () async {
      final big = '@@ -1 +1 @@\n${'+x\n' * 5000}';
      final runner = FakeRunner(stdout: sentinel(0, body: big));

      final result = await GitClient(runner, maxDiffBytes: 1024)
          .diff('/tmp/repo') as GitDiffBody;

      expect(result.truncated, isTrue);
      expect(result.diff.hunks, isNotEmpty);
    });

    test('diff for a non-repository is distinguished from no git', () async {
      final noRepo = FakeRunner(stdout: sentinel(128));
      final noGit = FakeRunner(stdout: sentinel(127));

      expect(
        (await GitClient(noRepo).diff('/tmp') as GitDiffFailure).reason,
        GitFailure.notARepository,
      );
      expect(
        (await GitClient(noGit).diff('/tmp') as GitDiffFailure).reason,
        GitFailure.notInstalled,
      );
    });

    test('a hostile cwd is quoted in every command', () async {
      const hostile = "/tmp/it's; echo pwned";
      final runner = FakeRunner(stdout: sentinel(0));

      await GitClient(runner).diff(hostile);

      expect(runner.onlyCommand, contains(r"'/tmp/it'\''s; echo pwned'"));
    });
  });

  group('date-free listing robustness', () {
    test('a listing line from a locale with a different month name still parses',
        () async {
      // 12 月 4 11:22 — `ls -lA` under a non-C locale. The parser must not care
      // what the date fields SAY, only that there are two of them.
      final runner = FakeRunner(
        stdout: '-rw-r--r--   1 me  staff    12 12月  4 11:22 a.txt\n',
      );

      final entries = await RemoteFs(runner).list('/tmp/dir');

      expect(entries.single.name, 'a.txt');
      expect(entries.single.sizeBytes, 12);
    });
  });
}

/// Whether every single quote in [s] pairs up as the shell would read it.
///
/// A correct quoted word has an ODD number of quotes only inside an escaped
/// `'\''` run; the reliable invariant is that the total count is even and the
/// string starts and ends with a quote.
bool _balancedSingleQuotes(String s) {
  if (!s.startsWith("'") || !s.endsWith("'")) return false;
  return "'".allMatches(s).length.isEven;
}
