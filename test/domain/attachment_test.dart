import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/attachment.dart';

/// Where an upload lands and what it is called.
///
/// Two things make this worth testing carefully. The file name is derived from
/// UNTRUSTED input (whatever the phone's photo library called it) and ends up
/// pasted into an agent's composer. And the directory is a decision about being
/// a guest on somebody else's machine.
void main() {
  DateTime at(int y, int m, int d, [int hh = 15, int mm = 30, int ss = 12]) =>
      DateTime(y, m, d, hh, mm, ss);

  group('upload directory', () {
    test('lives under the cache, never in the repository', () {
      // Dropping files into somebody's working tree would show up in their
      // `git status` — we are a guest on that machine.
      final dir = uploadDirectory(home: '/home/you');
      expect(dir, '/home/you/.cache/herdr-pocket/uploads');
      expect(dir.contains('/repo'), isFalse);
    });

    test('honours XDG_CACHE_HOME without doubling the cache segment', () {
      expect(
        uploadDirectory(home: '/home/you', xdgCacheHome: '/var/cache/you'),
        '/var/cache/you/herdr-pocket/uploads',
      );
    });

    test('a blank XDG value is treated as unset', () {
      expect(
        uploadDirectory(home: '/home/you', xdgCacheHome: '   '),
        '/home/you/.cache/herdr-pocket/uploads',
      );
    });

    test('a home with a trailing slash does not produce a double slash', () {
      expect(
        uploadDirectory(home: '/home/you/'),
        '/home/you/.cache/herdr-pocket/uploads',
      );
    });
  });

  group('file name', () {
    test('carries a timestamp, the source, and the extension', () {
      expect(
        attachmentFileName(
          kind: AttachmentKind.image,
          source: AttachmentSource.gallery,
          now: at(2026, 9, 14),
        ),
        '20260914-153012-image.png',
      );
    });

    test('keeps the original stem and extension when they are usable', () {
      expect(
        attachmentFileName(
          kind: AttachmentKind.image,
          source: AttachmentSource.gallery,
          now: at(2026, 9, 14),
          originalName: 'IMG_4021.HEIC',
        ),
        '20260914-153012-img-4021.heic',
      );
    });

    test('a path separator in the original name cannot escape the directory', () {
      // The name arrives from the OS and is used to build a path. `../` here
      // would put the file outside the upload directory entirely.
      final name = attachmentFileName(
        kind: AttachmentKind.other,
        source: AttachmentSource.file,
        now: at(2026, 9, 14),
        originalName: '../../../etc/passwd',
      );
      expect(name.contains('/'), isFalse);
      expect(name.contains('..'), isFalse);
      expect(name, '20260914-153012-passwd.bin');
    });

    test('a newline cannot survive — it would submit a half-written prompt', () {
      final name = attachmentFileName(
        kind: AttachmentKind.other,
        source: AttachmentSource.file,
        now: at(2026, 9, 14),
        originalName: 'evil\nname.txt',
      );
      expect(name.contains('\n'), isFalse);
      expect(name, '20260914-153012-evil-name.txt');
    });

    test('quotes and spaces are reduced, not smuggled through', () {
      final name = attachmentFileName(
        kind: AttachmentKind.other,
        source: AttachmentSource.file,
        now: at(2026, 9, 14),
        originalName: "it's a 'test' file.txt",
      );
      expect(name.contains("'"), isFalse);
      expect(name.contains(' '), isFalse);
      expect(name, '20260914-153012-it-s-a-test-file.txt');
    });

    test('an exotic extension falls back to the kind default', () {
      final name = attachmentFileName(
        kind: AttachmentKind.image,
        source: AttachmentSource.camera,
        now: at(2026, 9, 14),
        originalName: r'photo.$$$weird',
      );
      expect(name.endsWith('.png'), isTrue);
    });

    test('a name with nothing usable falls back to the source slug', () {
      expect(
        attachmentFileName(
          kind: AttachmentKind.text,
          source: AttachmentSource.clipboard,
          now: at(2026, 9, 14),
          originalName: '...',
        ),
        '20260914-153012-paste.txt',
      );
    });

    test('a long stem is capped so the path stays manageable', () {
      final name = attachmentFileName(
        kind: AttachmentKind.other,
        source: AttachmentSource.file,
        now: at(2026, 9, 14),
        originalName: '${'x' * 200}.txt',
      );
      expect(name.length, lessThan(70));
    });
  });

  group('size limits are decided before anything moves', () {
    test('an image within the ceiling is fine', () {
      expect(
        checkAttachment(kind: AttachmentKind.image, byteCount: 1024 * 1024),
        isNull,
      );
    });

    test('an over-limit image is refused', () {
      expect(
        checkAttachment(
          kind: AttachmentKind.image,
          byteCount: AttachmentLimits.image + 1,
        ),
        AttachmentRefusal.tooLarge,
      );
    });

    test('clipboard text has a much lower ceiling than an image', () {
      // 300 KB of "snippet" is not a snippet, and a file is the wrong shape.
      expect(
        checkAttachment(kind: AttachmentKind.text, byteCount: 300 * 1024),
        AttachmentRefusal.tooLarge,
      );
    });

    test('nothing to send is a refusal, not an empty upload', () {
      expect(
        checkAttachment(kind: AttachmentKind.text, byteCount: 0),
        AttachmentRefusal.empty,
      );
    });
  });

  group('path joining', () {
    test('produces the absolute path SFTP needs', () {
      expect(
        joinRemotePath('/home/you/.cache/herdr-pocket/uploads', 'a.png'),
        '/home/you/.cache/herdr-pocket/uploads/a.png',
      );
    });

    test('tolerates a trailing slash on the directory', () {
      expect(joinRemotePath('/tmp/', 'a.png'), '/tmp/a.png');
    });
  });

  group('the sentence that mentions the file', () {
    test('says it is a LOCAL path, in both languages', () {
      // An agent that thinks it was handed a URL will try to fetch it, and the
      // failure looks like the agent ignoring the file.
      const path = '/home/you/.cache/herdr-pocket/uploads/a.png';
      expect(attachmentPrompt(remotePath: path, isZh: false), contains('local file'));
      expect(attachmentPrompt(remotePath: path, isZh: false), contains(path));
      expect(attachmentPrompt(remotePath: path, isZh: true), contains('本地文件'));
      expect(attachmentPrompt(remotePath: path, isZh: true), contains(path));
    });
  });
}
