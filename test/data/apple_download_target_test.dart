import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/local/apple_download_target.dart';
import 'package:herdr_pocket/data/local/download_target.dart';

/// The iOS download target, which is the one platform seam in this app that can
/// be tested WITHOUT a device.
///
/// That is not an accident of this test file: `AppleDocumentsDownloadTarget` is
/// pure `dart:io` precisely because iOS needs no permission and therefore no
/// method channel — see its own comment. Its Android sibling cannot be tested
/// here at all, because every interesting line of it is a platform call.
///
/// The tests below are about the CONTRACT rather than about iOS: what a caller
/// is entitled to assume of any [DownloadTarget], checked against the
/// implementation that can be run anywhere.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('hp-apple-dl-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AppleDocumentsDownloadTarget target() =>
      AppleDocumentsDownloadTarget(documents: () async => root);

  group('choosing a folder', () {
    test('neither pick nor defaultDirectory asks the user anything', () async {
      // THE PROPERTY THAT MAKES THE FEATURE WORK ON A FRESH INSTALL. If either
      // of these returned null, `RemoteDownload` would refuse the first download
      // with "no directory" and tell the user to choose a folder — a folder
      // that on iOS cannot be chosen, because there is no picker.
      final t = target();

      final implicit = await t.defaultDirectory();
      expect(implicit, isNotNull);
      expect(implicit!.uri, root.path);
      expect(implicit.label, AppleDocumentsDownloadTarget.folderLabel);

      final picked = await t.pick();
      expect(picked!.uri, root.path, reason: 'pick is the same answer on iOS');
    });

    test('the label is a proper noun, so it cannot go stale', () {
      // It is stored in the settings the first time a file is saved and read
      // back on later launches, so a translated label would freeze whichever
      // language the app happened to be in that day.
      expect(AppleDocumentsDownloadTarget.folderLabel, 'Herdr Pocket');
    });
  });

  group('hasAccess', () {
    test('says yes to a directory it can write into', () async {
      expect(await target().hasAccess(root.path), isTrue);
    });

    test('leaves no probe file behind', () async {
      // The check writes and deletes. A probe that survived would show up in the
      // user's Files app as a file they did not download.
      await target().hasAccess(root.path);
      expect(root.listSync(), isEmpty);
    });

    test('says no to a path that is not there', () async {
      expect(await target().hasAccess('${root.path}/nope/deeper'), isFalse);
    });

    test('says no to an empty uri rather than resolving it', () async {
      // Empty must not be read as "the app's own folder": on Android an empty
      // uri means no grant, and the two platforms must not disagree about what
      // the caller asked.
      expect(await target().hasAccess(''), isFalse);
    });

    test('says no to a FILE, not a directory', () async {
      final file = File('${root.path}/a-file')..writeAsStringSync('x');
      expect(await target().hasAccess(file.path), isFalse);
    });
  });

  group('write', () {
    test('puts the bytes under the name it was given', () async {
      final t = target();
      final bytes = Uint8List.fromList(List<int>.generate(300, (i) => i % 251));

      final written = await t.write(
        uri: root.path,
        name: 'file.bin',
        mimeType: 'application/octet-stream',
        bytes: Stream<List<int>>.fromIterable(_chunks(bytes, 64)),
      );

      expect(written, bytes.length);
      expect(File('${root.path}/file.bin').readAsBytesSync(), bytes);
    });

    test('reports the count it actually wrote, not the last progress call',
        () async {
      // The interface calls this out because a throttled progress callback can
      // legitimately be suppressed, and a "saved 24 MiB" line for a 48 MiB file
      // is the kind of confidently wrong number this app exists not to print.
      final t = target();
      final reported = <int>[];
      final bytes = Uint8List.fromList(List<int>.filled(500, 7));

      final written = await t.write(
        uri: root.path,
        name: 'f.bin',
        mimeType: 'application/octet-stream',
        bytes: Stream<List<int>>.fromIterable(_chunks(bytes, 100)),
        onProgress: reported.add,
      );

      expect(written, 500);
      expect(reported.last, 500);
    });

    test('replaces a file already there', () async {
      File('${root.path}/f.bin').writeAsStringSync('old contents');

      await target().write(
        uri: root.path,
        name: 'f.bin',
        mimeType: 'application/octet-stream',
        bytes: Stream<List<int>>.value(Uint8List.fromList([1, 2, 3])),
      );

      expect(File('${root.path}/f.bin').readAsBytesSync(), [1, 2, 3]);
    });

    test('a stream that fails leaves NEITHER a half file NOR a stray .part',
        () async {
      // THE REASON THE WRITE GOES THROUGH A STAGING NAME. The failure this
      // guards is the one that matters to a user: a download that dies at 90%
      // must not leave something wearing the name they are about to open.
      final t = target();
      File('${root.path}/f.bin').writeAsStringSync('the good copy');

      final failing = Stream<List<int>>.fromIterable([
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
      ]).asyncMap((chunk) async {
        if (chunk.first == 4) throw const SocketException('link died');
        return chunk;
      });

      await expectLater(
        t.write(
          uri: root.path,
          name: 'f.bin',
          mimeType: 'application/octet-stream',
          bytes: failing,
        ),
        throwsA(isA<SocketException>()),
      );

      // The original file is untouched...
      expect(File('${root.path}/f.bin').readAsStringSync(), 'the good copy');
      // ...and nothing is left over under either name.
      expect(root.listSync().map((e) => e.path.split('/').last), ['f.bin']);
    });
  });

  group('exists and delete', () {
    test('report on the name given', () async {
      final t = target();
      expect(await t.exists(uri: root.path, name: 'x'), isFalse);

      File('${root.path}/x').writeAsStringSync('1');
      expect(await t.exists(uri: root.path, name: 'x'), isTrue);

      await t.delete(uri: root.path, name: 'x');
      expect(await t.exists(uri: root.path, name: 'x'), isFalse);
    });

    test('deleting what is not there is not an error', () async {
      // The caller asked for the file to be gone, and it is gone.
      await expectLater(
        target().delete(uri: root.path, name: 'never-existed'),
        completes,
      );
    });
  });
}

/// Slices [bytes] into chunks of [size], the way a socket would deliver them.
List<List<int>> _chunks(List<int> bytes, int size) => [
      for (var i = 0; i < bytes.length; i += size)
        bytes.sublist(i, (i + size).clamp(0, bytes.length)),
    ];
