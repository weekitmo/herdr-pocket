import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/local/download_target.dart';
import 'package:path_provider/path_provider.dart';

/// Saving to the phone on iOS, where there is nothing to ask for.
///
/// ## Why this is not a port of the Android one
///
/// Android's Storage Access Framework exists because an app's own storage is a
/// private sandbox: to write somewhere the user can find, the user has to grant
/// a folder, and that grant has to be persisted. That is a permission
/// conversation, and it is the whole reason `SafDownloadTarget` is a method
/// channel with a pending-picker bookkeeping problem.
///
/// iOS has the same sandbox and a DIFFERENT answer to it. Every app owns a
/// `Documents` directory, and two Info.plist keys —
/// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` — publish it
/// into the Files app as "On My iPhone › Herdr Pocket". So the user still ends
/// up with files they can browse, share and open in another app; what is
/// missing is the PROMPT, because there was never anything to ask.
///
/// Two consequences worth stating plainly, because they are the difference
/// between this and [SafDownloadTarget]:
///
///   * **No method channel.** Every byte moves through `dart:io`, so the whole
///     class runs under `flutter test` on any machine — unlike its Android
///     sibling, which cannot be tested without a device.
///   * **No grant to lose.** There is no revoked state: the directory exists
///     for as long as the app is installed. `hasAccess` still answers honestly
///     rather than assuming, because "the path exists" and "the path can be
///     written to" are not the same sentence, but it is expected to say yes.
///
/// The one thing this cannot do that Android can: write to a folder OUTSIDE the
/// app, such as a shared Downloads directory. On iOS that is a copy the user
/// makes from the share sheet, in the Files app — a system action, not an app
/// permission, and therefore not something this class can hold open.
class AppleDocumentsDownloadTarget implements DownloadTarget {
  AppleDocumentsDownloadTarget({Future<Directory> Function()? documents})
      : _documents = documents ?? getApplicationDocumentsDirectory;

  /// The app's own Documents directory.
  ///
  /// Injected so the tests can point it at a temporary directory: the real one
  /// is the Keychain-adjacent sandbox, and writing test files into it would
  /// leave litter in the user's own app.
  final Future<Directory> Function() _documents;

  /// The name this folder has in the Files app, and the label on the row.
  ///
  /// Deliberately NOT localised. It is written into the settings on first use
  /// and read back on later launches, so a translated copy would freeze
  /// whatever language the app happened to be in the day the user first
  /// downloaded something. The app is called `Herdr Pocket` in both languages
  /// (see AGENTS.md), which makes the proper noun the one string that is
  /// already right.
  static const String folderLabel = 'Herdr Pocket';

  /// The staging suffix, matching the Android side's contract: a file is built
  /// under a name that cannot be mistaken for the finished one, and only takes
  /// its real name once every byte is on disk.
  static const String _partialSuffix = '.part';

  /// Answers without asking. See the class comment: there is no picker on iOS,
  /// so this returns the folder the app already owns.
  @override
  Future<GrantedDirectory?> pick() => defaultDirectory();

  /// The same folder, as the answer to "nobody has chosen one yet".
  ///
  /// This is what makes the feature work on a FRESH INSTALL. `RemoteDownload`
  /// refuses to start without a directory, which on Android is right — no grant
  /// means nowhere to write. On iOS the directory is always there, so a first
  /// run must not be told to go and choose something that cannot be chosen.
  @override
  Future<GrantedDirectory?> defaultDirectory() async {
    final dir = await _documents();
    return GrantedDirectory(uri: dir.path, label: folderLabel);
  }

  /// Whether [uri] is a directory this app can actually write into.
  ///
  /// ASKED WITH A REAL WRITE, not with `exists()`. The question the interface
  /// asks is "may still be written to", and on iOS the way that goes wrong is
  /// not a revoked permission — it is a full disk, or a backup restore that
  /// brought the recorded path back without the directory. Both are answered by
  /// creating something and deleting it again.
  @override
  Future<bool> hasAccess(String uri) async {
    if (uri.isEmpty) return false;
    final dir = Directory(uri);
    try {
      // SYNCHRONOUS, deliberately, and this is the one place in the file where
      // that is true. `avoid_slow_async_io` is right: for a single `stat` the
      // async form costs more than it saves, and this runs on the main isolate
      // at settings-page load and again before every download. The write probe
      // below stays async because it is real I/O and is allowed to yield.
      if (!dir.existsSync()) return false;
      final probe = File('${dir.path}/.hp-write-probe');
      await probe.writeAsBytes(const <int>[0], flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      // Not writable, not a directory, or gone between the two calls. All three
      // are the same answer to the caller.
      return false;
    }
  }

  @override
  Future<int> write({
    required String uri,
    required String name,
    required String mimeType,
    required Stream<List<int>> bytes,
    void Function(int bytesWritten)? onProgress,
  }) async {
    // `mimeType` is accepted and unused. Android needs it because a SAF
    // document has a type column; a file on a filesystem does not, and inventing
    // one from the extension would be a guess this app would then have to
    // defend. The parameter stays to keep the interface single.
    final dir = await _documents();
    final staging = File('${dir.path}/$name$_partialSuffix');
    final target = File('${dir.path}/$name');

    IOSink? sink;
    var written = 0;
    try {
      sink = staging.openWrite();
      await for (final chunk in bytes) {
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      // Rename LAST, and rename rather than copy: a download that dies at 90%
      // must not leave a file wearing the name the user is about to look for.
      await staging.rename(target.path);
      return written;
    } on Object {
      // Either the transfer failed or the subscription was cancelled. Closing
      // WITHOUT flushing would leave the buffered bytes on disk under the
      // staging name, so the staging file is deleted rather than closed.
      //
      // Every step here is best-effort: this block runs because something else
      // already went wrong, and a cleanup failure that replaced that error
      // would send the reader after the wrong problem.
      try {
        await sink?.close();
      } on Object {
        // Already broken; nothing to add.
      }
      try {
        if (staging.existsSync()) await staging.delete();
      } on Object {
        // Same.
      }
      rethrow;
    }
  }

  @override
  Future<bool> exists({required String uri, required String name}) async {
    final dir = uri.isEmpty ? await _documents() : Directory(uri);
    // Sync for the same reason as `hasAccess`: one `stat`, on the main isolate.
    return File('${dir.path}/$name').existsSync();
  }

  @override
  Future<void> delete({required String uri, required String name}) async {
    final dir = uri.isEmpty ? await _documents() : Directory(uri);
    final file = File('${dir.path}/$name');
    // Deleting something that is not there is the outcome the caller asked for,
    // so a missing file is not an error the way it would be on Android, where
    // the SAF call reports it.
    if (file.existsSync()) await file.delete();
  }
}

/// The iOS download target.
///
/// A provider rather than a constructor for the same reason as its Android
/// sibling: a test wants to point it at a temporary directory, and the real one
/// writes into the user's own app container.
final appleDownloadTargetProvider = Provider<DownloadTarget>(
  (ref) => AppleDocumentsDownloadTarget(),
);
