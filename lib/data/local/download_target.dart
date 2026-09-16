import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A folder on the phone the app may keep writing into.
///
/// "Keep" is the load-bearing word. Android's Storage Access Framework grants
/// access to a folder the user picks, and the grant can be made PERSISTENT —
/// which is the difference between "pick your download folder once" and "pick
/// it every single time you download something".
class GrantedDirectory {
  /// Holds one grant.
  const GrantedDirectory({required this.uri, required this.label});

  /// The SAF tree URI. This is the grant itself, not a location: it is what
  /// [DownloadTarget.hasAccess] is checked against on the next launch.
  final String uri;

  /// A readable name for the row, e.g. `Download/Herdr Pocket`.
  final String label;

  @override
  String toString() => 'GrantedDirectory($label)';
}

/// Why a file could not be written to the phone.
enum LocalWriteFailure {
  /// No folder has been granted yet.
  noDirectory,

  /// The grant is gone — the folder was deleted, or the permission was revoked
  /// in system settings. Recoverable only by asking the user to pick again.
  revoked,

  /// Room for the bytes, but not for these bytes.
  outOfSpace,

  /// The platform has no directory-grant mechanism wired up. True of desktop
  /// and iOS today; a real answer rather than a failure.
  unsupported,

  /// Anything else, with the message preserved for diagnostics.
  unknown,
}

class LocalWriteException implements Exception {
  const LocalWriteException(this.reason, {this.detail});

  final LocalWriteFailure reason;
  final String? detail;

  @override
  String toString() =>
      'LocalWriteException(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// Puts bytes on the PHONE, in a folder the user granted once.
///
/// The mirror image of `RemoteFileFetcher`: that one answers "how do the bytes
/// leave the host", this one answers "where do they land". Kept as an interface
/// so the download logic can be tested without a device — the one and only
/// implementation below is a platform channel, and a platform channel cannot
/// run under `flutter test`.
abstract interface class DownloadTarget {
  /// Opens the system folder picker.
  ///
  /// Returns null when the user backed out, which is a real answer and not a
  /// failure: the caller keeps whatever it had.
  Future<GrantedDirectory?> pick();

  /// Whether a previously granted [uri] may still be written to.
  ///
  /// Asked at startup rather than assumed. A grant survives reboots, but it
  /// does not survive the user deleting the folder or revoking the permission,
  /// and a download that fails at 90% is a much worse way to learn that.
  Future<bool> hasAccess(String uri);

  /// Streams [bytes] into `uri/name`, replacing any file already there.
  ///
  /// Returns the number of bytes actually written, WHICH IS NOT NECESSARILY
  /// THE NUMBER [onProgress] LAST REPORTED. Progress is throttled so the UI is
  /// not rebuilt three thousand times for one file, which means the final
  /// callback can be suppressed — and a "saved 24 MiB" line for a 48 MiB file
  /// is exactly the kind of confidently wrong number this app exists not to
  /// print. The return value is counted here, where every byte passes.
  ///
  /// [onProgress] is called with the running byte count. The stream is consumed
  /// as fast as it arrives; cancelling the subscription aborts the write and
  /// leaves no partial file behind under [name].
  Future<int> write({
    required String uri,
    required String name,
    required String mimeType,
    required Stream<List<int>> bytes,
    void Function(int bytesWritten)? onProgress,
  });

  Future<bool> exists({required String uri, required String name});

  Future<void> delete({required String uri, required String name});
}

/// The Android implementation, over a hand-written method channel.
///
/// See `android/app/src/main/kotlin/dev/maddax/herdrpocket/MainActivity.kt` for
/// why this is ours rather than a package's.
class SafDownloadTarget implements DownloadTarget {
  /// Holds the channel.
  SafDownloadTarget({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `CHANNEL` in MainActivity.kt.
  static const String channelName = 'dev.maddax.herdrpocket/download_dir';

  /// How many bytes are gathered before crossing the platform channel.
  ///
  /// ONE CALL PER SSH CHUNK WOULD BE 3000 ROUND TRIPS for a 48 MB file — the
  /// SSH read gives ~16 KiB at a time and a method channel call is not free.
  /// Batching to 256 KiB cuts that to ~190 while keeping the memory ceiling
  /// flat, which is the whole reason the transfer is a stream and not a buffer.
  static const int batchBytes = 256 * 1024;

  final MethodChannel _channel;

  @override
  Future<GrantedDirectory?> pick() async {
    final result = await _invoke<Map<Object?, Object?>>(
      'pickDirectory',
      const {},
    );
    if (result == null) return null;
    final uri = result['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    final label = (result['label'] as String?)?.trim();
    return GrantedDirectory(
      uri: uri,
      label: (label == null || label.isEmpty) ? uri : label,
    );
  }

  @override
  Future<bool> hasAccess(String uri) async =>
      await _invoke<bool>('checkAccess', {'uri': uri}) ?? false;

  @override
  Future<int> write({
    required String uri,
    required String name,
    required String mimeType,
    required Stream<List<int>> bytes,
    void Function(int bytesWritten)? onProgress,
  }) async {
    final session = await _invoke<int>('openWrite', {
      'uri': uri,
      'name': name,
      'mime': mimeType,
    });
    if (session == null) {
      throw const LocalWriteException(
        LocalWriteFailure.noDirectory,
        detail: 'the platform did not open a file',
      );
    }

    var written = 0;
    final batch = BytesBuilder(copy: false);

    Future<void> flush() async {
      if (batch.length == 0) return;
      final payload = batch.takeBytes();
      await _invoke<void>('writeChunk', {
        'session': session,
        'bytes': payload,
      });
      written += payload.length;
      onProgress?.call(written);
    }

    try {
      await for (final chunk in bytes) {
        batch.add(chunk);
        if (batch.length >= batchBytes) await flush();
      }
      await flush();
      await _invoke<void>('closeWrite', {'session': session});
      return written;
    } on Object {
      // Either the transfer failed or the subscription was cancelled. Either
      // way the half-written file must not keep the name it was going to have,
      // so the stream is closed WITHOUT being flushed and the entry deleted.
      //
      // The delete is best-effort on purpose: it is the second thing that can
      // fail here, and letting it throw would replace the real error (the
      // connection dropped) with a misleading one (the cleanup did not work).
      await _invoke<void>('abortWrite', {'session': session}, swallow: true);
      await _invoke<void>('delete', {'uri': uri, 'name': name}, swallow: true);
      rethrow;
    }
  }

  @override
  Future<bool> exists({required String uri, required String name}) async =>
      await _invoke<bool>('exists', {'uri': uri, 'name': name}) ?? false;

  @override
  Future<void> delete({required String uri, required String name}) async {
    await _invoke<void>('delete', {'uri': uri, 'name': name});
  }

  /// Calls the platform, translating its failures into [LocalWriteException].
  ///
  /// [swallow] turns a failure into a silent no-op, for the cleanup paths where
  /// the original error is the one worth reporting.
  Future<T?> _invoke<T>(
    String method,
    Map<String, Object?> args, {
    bool swallow = false,
  }) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (swallow) return null;
      throw LocalWriteException(
        _classify(e),
        detail: '${e.code}: ${e.message}',
      );
    } on MissingPluginException catch (e) {
      if (swallow) return null;
      throw LocalWriteException(
        LocalWriteFailure.unsupported,
        detail: '$e',
      );
    }
  }

  static LocalWriteFailure _classify(PlatformException e) => switch (e.code) {
        'not_persistable' => LocalWriteFailure.revoked,
        'busy' => LocalWriteFailure.unknown,
        _ => LocalWriteFailure.unknown,
      };
}

/// The download target for this platform, or null when there is none.
///
/// Null is a real answer rather than a loading state, matching
/// `remoteUploaderProvider`: the feature genuinely does not exist on a platform
/// without a directory-grant mechanism, and a UI that says so beats one that
/// fails at the last step.
///
/// Only Android, today. iOS writes into its own sandbox and exposes the result
/// through a share sheet, which is a different feature rather than a port of
/// this one.
final downloadTargetProvider = Provider<DownloadTarget?>((ref) {
  if (!Platform.isAndroid) return null;
  return SafDownloadTarget();
});
