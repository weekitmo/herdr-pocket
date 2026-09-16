import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';

/// Tests for the pure decisions behind file download.
///
/// None of these need a device, a host or a connection — which is the point.
/// "Which MIME type does an APK claim" and "what does an unknown size render
/// as" are exactly the kind of thing that is wrong in production and invisible
/// in review.
void main() {
  group('mimeTypeForName', () {
    test('an APK claims the type that makes Android offer to install it', () {
      // The whole reason this function exists. `application/octet-stream` would
      // still download the file and still save it with the right name — and the
      // user would have to go find it in a file manager, which is the step this
      // feature is supposed to remove.
      expect(
        mimeTypeForName('app-release.apk'),
        'application/vnd.android.package-archive',
      );
    });

    test('is case-insensitive', () {
      // Windows and macOS produce `App.APK` and `Logo.PNG`; a build script may
      // too. Matching exactly would silently downgrade them to a blob.
      expect(mimeTypeForName('App.APK'), 'application/vnd.android.package-archive');
      expect(mimeTypeForName('Logo.PNG'), 'image/png');
    });

    test('only the LAST extension counts', () {
      // `app.apk.part` is not an APK. Reporting it as one would have Android
      // offer to INSTALL a half-written file, which is worse than not
      // recognising it at all.
      expect(mimeTypeForName('app.apk.part'), 'application/octet-stream');
      expect(mimeTypeForName('notes.md.bak'), 'application/octet-stream');
    });

    test('falls back rather than guessing', () {
      expect(mimeTypeForName('Makefile'), 'application/octet-stream');
      expect(mimeTypeForName('archive.'), 'application/octet-stream');
      // A dotfile has no extension; `indexOf` returning 0 must not be read as
      // "the name starts with an extension".
      expect(mimeTypeForName('.gitignore'), 'application/octet-stream');
      expect(mimeTypeForName(''), 'application/octet-stream');
    });
  });

  group('formatByteCount', () {
    test('uses binary units under their real names', () {
      // 48 MiB, not "48 MB": this app talks to a shell all day and `ls -l`
      // reports 50331648. Labelling that "50.3 MB" is off by 4.9% and reads as
      // a rounding bug to the one user most likely to check.
      expect(formatByteCount(50331648), '48.0 MiB');
      expect(formatByteCount(1024), '1 KiB');
      expect(formatByteCount(0), '0 B');
      expect(formatByteCount(999), '999 B');
    });

    test('picks exactly one unit, with no double scaling', () {
      expect(formatByteCount(1024 * 1024 - 1), '1024 KiB');
      expect(formatByteCount(1024 * 1024), '1.0 MiB');
      expect(formatByteCount(1024 * 1024 * 1024), '1.0 GiB');
    });

    test('a negative count is not a number worth printing', () {
      // Defensive, and reachable: a progress counter that subtracts can go
      // negative on an error path, and `-1 B` on screen is a bug report.
      expect(formatByteCount(-1), '0 B');
    });
  });

  group('transferFraction', () {
    test('is null when the total is unknown', () {
      // Null rather than 0, and that distinction is the whole function: a bar
      // pinned at zero is indistinguishable from a hang, and the UI draws a
      // different thing for "cannot know" than for "at the start".
      expect(transferFraction(received: 100, total: null), isNull);
      expect(transferFraction(received: 100, total: 0), isNull);
      expect(transferFraction(received: 0, total: 0), isNull);
    });

    test('is clamped, so an over-reporting far end cannot overflow the bar', () {
      expect(transferFraction(received: 0, total: 100), 0);
      expect(transferFraction(received: 50, total: 100), 0.5);
      expect(transferFraction(received: 100, total: 100), 1);
      // A file that grew while being read is a real thing on a machine where an
      // agent is still building.
      expect(transferFraction(received: 150, total: 100), 1);
    });
  });

  group('fileActionsFor', () {
    test('a directory offers nothing', () {
      // "Download a folder" is a recursive archive with a different failure
      // mode, not a button. Saying so here means the row and any future sheet
      // cannot disagree about it.
      expect(fileActionsFor(isDirectory: true), isEmpty);
    });

    test('a file offers a download', () {
      expect(fileActionsFor(isDirectory: false), [FileAction.download]);
    });
  });
}
