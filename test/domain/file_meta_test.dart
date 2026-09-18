import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/files/file_meta.dart';

/// The `stat` parse, and the two dialect quirks that make it worth a test.
///
/// Every failure this guards against is SILENT: a mis-split record still
/// produces a file info sheet, it just says the file is 0 bytes and was created
/// in 1970. Nothing on screen would look broken.
void main() {
  group('parseFileMeta', () {
    test('reads a GNU record', () {
      final meta = parseFileMeta('1024\t1700000000\t1690000000\t-rw-r--r--\tme\tstaff');

      expect(meta, isNotNull);
      expect(meta!.sizeBytes, 1024);
      expect(meta.modified.millisecondsSinceEpoch, 1700000000000);
      expect(meta.created!.millisecondsSinceEpoch, 1690000000000);
      expect(meta.permissions, '-rw-r--r--');
      expect(meta.owner, 'me');
      expect(meta.group, 'staff');
      expect(meta.kind, RemoteFileKind.file);
    });

    test('reads a BSD record the same way', () {
      // Same six fields, different dialect flags — the shape is what the parser
      // promises, and the command is what makes the shapes agree.
      final meta = parseFileMeta('6\t1789714430\t1789714430\t-rw-r--r--\tweekit\twheel');

      expect(meta!.sizeBytes, 6);
      expect(meta.owner, 'weekit');
    });

    test('birth time 0 is unknown, not 1970', () {
      // GNU prints 0 on any filesystem without a birth time, which is most of
      // Linux. Rendering that as a date would be a confident lie.
      final meta = parseFileMeta('10\t1700000000\t0\t-rw-------\tu\tg');
      expect(meta!.created, isNull);
    });

    test('a missing or malformed record is null rather than zeroes', () {
      expect(parseFileMeta(''), isNull);
      expect(parseFileMeta('\n'), isNull);
      expect(parseFileMeta('1024\t1700000000'), isNull);
      expect(parseFileMeta('not-a-size\t1700000000\t0\t-rw-\tu\tg'), isNull);
      expect(parseFileMeta('1024\tnot-a-time\t0\t-rw-\tu\tg'), isNull);
    });

    test('the trailing newline from the command does not matter', () {
      expect(parseFileMeta('1\t2\t3\t-rw-\tu\tg\n'), isNotNull);
    });

    test('a directory is recognised by its first permission character', () {
      final meta = parseFileMeta('4096\t1700000000\t0\tdrwxr-xr-x\tu\tg')!;
      expect(meta.kind, RemoteFileKind.directory);
      expect(meta.isDirectory, isTrue);

      expect(
        parseFileMeta('9\t1700000000\t0\tlrwxrwxrwx\tu\tg')!.kind,
        RemoteFileKind.link,
      );
      expect(
        parseFileMeta('9\t1700000000\t0\tprw-------\tu\tg')!.kind,
        RemoteFileKind.other,
      );
      expect(kindFromPermissions(null), RemoteFileKind.other);
      expect(kindFromPermissions(''), RemoteFileKind.other);
    });
  });

  test('formatFileTimestamp is year-first and zero-padded', () {
    expect(
      formatFileTimestamp(DateTime(2026, 9, 18, 6, 5)),
      '2026-09-18 06:05',
    );
    expect(
      formatFileTimestamp(DateTime(2026, 12, 31, 23, 59)),
      '2026-12-31 23:59',
    );
  });
}
