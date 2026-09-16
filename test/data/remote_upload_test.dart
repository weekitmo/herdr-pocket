import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/remote_upload.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/attachment.dart';

/// The two-legged upload: a shell `mkdir -p`, then SFTP for the bytes.
///
/// The interesting cases are the ones where a half-done upload would be worse
/// than none: a directory that was not created, a file that is too big, a home
/// directory that could not be found.
class _RecordingPorter implements RemoteFilePorter {
  final List<({String path, List<int> bytes})> uploads = [];

  @override
  Future<void> uploadBytes({
    required String absolutePath,
    required List<int> bytes,
  }) async {
    uploads.add((path: absolutePath, bytes: bytes));
  }
}

class _ScriptedRunner implements RemoteCommandRunner {
  _ScriptedRunner({required this.onRun});

  final String Function(String command) onRun;
  final List<String> commands = [];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    return onRun(command);
  }

  bool ranContaining(String needle) =>
      commands.any((c) => c.contains(needle));
}

/// The exit-code sentinel the runner's output carries, as `RemoteFs` uses it.
String _ok(String body) => '$body$remoteExitMarker' '0';
String _fail(int code) => '$remoteExitMarker$code';

void main() {
  late _RecordingPorter porter;

  setUp(() => porter = _RecordingPorter());

  RemoteUploader uploaderWith(_ScriptedRunner runner) =>
      RemoteUploader(porter: porter, runner: runner);

  _ScriptedRunner happyRunner() => _ScriptedRunner(
        onRun: (command) => command.startsWith('printf %s')
            ? '/home/you'
            : _ok(''),
      );

  test('resolves the remote home, then makes the directory, then uploads',
      () async {
    final runner = happyRunner();
    final result = await uploaderWith(runner).upload(
      bytes: utf8.encode('hello'),
      kind: AttachmentKind.text,
      source: AttachmentSource.clipboard,
    );

    expect(result.remotePath, '/home/you/.cache/herdr-pocket/uploads/'
        '${result.fileName}');
    expect(result.byteCount, 5);
    expect(porter.uploads.single.path, result.remotePath);
    expect(runner.ranContaining('mkdir -p'), isTrue);
    // The directory is quoted — a home with a space in it is normal on macOS.
    expect(runner.ranContaining("mkdir -p -- '/home/you/.cache"), isTrue);
  });

  test('asks for the home once per uploader, not once per upload', () async {
    final runner = happyRunner();
    final uploader = uploaderWith(runner);
    await uploader.uploadText('one');
    await uploader.uploadText('two');

    final homeAsks = runner.commands.where((c) => c.startsWith('printf %s'));
    expect(homeAsks.length, 1);
  });

  test('a home that cannot be resolved stops before anything is written',
      () async {
    final runner = _ScriptedRunner(onRun: (command) => '');
    await expectLater(
      uploaderWith(runner).uploadText('hello'),
      throwsA(isA<UploadException>()
          .having((e) => e.reason, 'reason', UploadFailure.noHome)),
    );
    expect(porter.uploads, isEmpty);
  });

  test('a relative home is refused rather than trusted', () async {
    // A relative path would make SFTP resolve it against a directory we cannot
    // name, which turns "where did my screenshot go" into an unanswerable
    // question.
    final runner = _ScriptedRunner(onRun: (command) => 'you\n');
    await expectLater(
      uploaderWith(runner).uploadText('hello'),
      throwsA(isA<UploadException>()
          .having((e) => e.reason, 'reason', UploadFailure.noHome)),
    );
  });

  test('a failed mkdir stops the upload and says which leg failed', () async {
    final runner = _ScriptedRunner(
      onRun: (command) => command.startsWith('printf %s') ? '/home/you' : _fail(1),
    );
    await expectLater(
      uploaderWith(runner).uploadText('hello'),
      throwsA(isA<UploadException>()
          .having((e) => e.reason, 'reason', UploadFailure.noDirectory)),
    );
    // The bytes never moved: a file with no directory is not a partial success.
    expect(porter.uploads, isEmpty);
  });

  test('an over-limit attachment is refused before ANY traffic', () async {
    final runner = happyRunner();
    await expectLater(
      uploaderWith(runner).upload(
        bytes: List<int>.filled(AttachmentLimits.text + 1, 0x41),
        kind: AttachmentKind.text,
      ),
      throwsA(isA<UploadException>()
          .having((e) => e.reason, 'reason', UploadFailure.refused)),
    );
    expect(porter.uploads, isEmpty);
    // Not even the home lookup: the refusal is a decision, and it is made
    // before touching the machine.
    expect(runner.commands, isEmpty);
  });

  test('clipboard text is UTF-8 and carries no BOM', () async {
    // A BOM is a stray character at the start of the first line — exactly the
    // kind of thing that makes an agent misread the first token of a file.
    await uploaderWith(happyRunner()).uploadText('中文 and ascii');
    final bytes = porter.uploads.single.bytes;
    expect(bytes.sublist(0, 3), isNot([0xEF, 0xBB, 0xBF]));
    expect(utf8.decode(bytes), '中文 and ascii');
  });

  test('discard removes the file, and never throws', () async {
    final runner = happyRunner();
    final uploader = uploaderWith(runner);
    final uploaded = await uploader.uploadText('hello');

    await uploader.discard(uploaded);
    expect(runner.ranContaining('rm -f -- '), isTrue);
    expect(runner.ranContaining(uploaded.remotePath), isTrue);
  });

  test('a transfer failure is reported as a transfer failure', () async {
    final failing = _FailingPorter();
    final uploader = RemoteUploader(porter: failing, runner: happyRunner());
    await expectLater(
      uploader.uploadText('hello'),
      throwsA(isA<UploadException>()
          .having((e) => e.reason, 'reason', UploadFailure.transfer)),
    );
  });
}

class _FailingPorter implements RemoteFilePorter {
  @override
  Future<void> uploadBytes({
    required String absolutePath,
    required List<int> bytes,
  }) async =>
      throw StateError('channel closed');
}
