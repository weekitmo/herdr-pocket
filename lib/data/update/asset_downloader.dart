import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:herdr_pocket/data/update/update_exception.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';

/// A file that finished downloading.
class DownloadedFile {
  /// Holds the result.
  const DownloadedFile({
    required this.file,
    required this.bytes,
    required this.sha256,
  });

  /// Where it landed. The final name, not the `.part` it wore while arriving.
  final File file;

  /// How many bytes were actually read off the wire.
  ///
  /// COUNTED HERE, NOT TAKEN FROM THE LAST PROGRESS CALLBACK. Progress is
  /// throttled (below), so the last callback is routinely a few hundred
  /// kilobytes behind — and a "saved 45.8 MB" line for a 46 MB file is exactly
  /// the kind of confidently wrong number this app refuses to print.
  final int bytes;

  /// Lowercase hex SHA-256 of the file on disk.
  final String sha256;
}

/// How far along a download is.
class DownloadProgress {
  /// Holds one reading.
  const DownloadProgress({required this.received, required this.total});

  /// Bytes on disk, including anything resumed from a previous attempt.
  final int received;

  /// The expected total, or null when nothing knows it.
  final int? total;

  /// 0..1, or null when the total is unknown.
  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (received / total).clamp(0, 1);
  }
}

/// The SHA-256 of a file on disk, as lowercase hex.
///
/// Public because the controller needs the same answer for a file it did NOT
/// download through here: one that a previous run left complete.
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Downloads one release asset to a file, resuming when it can.
///
/// THE `.part` FILE IS THE FEATURE. A 46 MB APK over a phone connection is
/// minutes, not seconds, and the interesting failure is not "it failed" but "it
/// failed at 80%". So the bytes go to `<name>.part` as they arrive, the file is
/// renamed only once it is complete, and a cancelled or failed transfer leaves
/// the partial file **in place** — the next attempt sends
/// `Range: bytes=<n>-` and continues instead of starting over.
///
/// The counterpart of that promise is the rule this class obeys: the partial
/// file is deleted ONLY when it is known to be worthless — the wrong length, a
/// failed checksum — never merely because the transfer did not finish.
class AssetDownloader {
  /// Holds the client and the identity it reports.
  AssetDownloader({required this.http, required this.userAgent});

  /// Sent as `User-Agent` on the asset request.
  final String userAgent;

  /// The HTTP client, pointed at whatever proxy is configured.
  final UpdateHttp http;

  /// How often progress is reported.
  ///
  /// The SSH download path learned this the visible way: a callback per chunk
  /// is ~3000 widget rebuilds for one file, and the UI spends the transfer
  /// rebuilding instead of painting. 100 ms is under the threshold where a
  /// progress bar looks like it is jumping.
  static const Duration progressInterval = Duration(milliseconds: 100);

  /// Fetches [asset] into [staging], returning the finished file.
  ///
  /// [cancelToken] cancels the transfer and leaves the partial file behind.
  /// Throws [UpdateException] with a classified [UpdateFailure].
  Future<DownloadedFile> download({
    required ReleaseAsset asset,
    required Directory staging,
    required CancelToken cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final name = _safeName(asset.name);
    await http.resolver.refresh();
    final proxied = http.resolver.current?.isUsable ?? false;

    await staging.create(recursive: true);
    final target = File('${staging.path}/$name');
    final part = File('${target.path}.part');

    // A previous run that died between the last byte and the rename leaves a
    // COMPLETE `.part`. Promoting it costs one stat and saves the whole
    // download, which is the difference between "retry" meaning "wait another
    // five minutes" and meaning "carry on".
    var existing = part.existsSync() ? part.lengthSync() : 0;
    if (asset.size > 0 && existing == asset.size) {
      await _promote(part, target);
      return await _digest(target, asset.size);
    }

    // Declared out here because the value decides the write mode AFTER the
    // response arrives: whether the partial file is a prefix (206) or worthless
    // (200) is the server's answer, not our assumption.
    var resumed = false;
    final ResponseBody body;
    try {
      final response = await http.dio.get<ResponseBody>(
        asset.url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'user-agent': userAgent,
            // The size of a compressed transfer is not the size of the file,
            // and the progress line reports the file's size. Asking for no
            // compression keeps the two the same number.
            'accept-encoding': 'identity',
            if (existing > 0) 'range': 'bytes=$existing-',
          },
        ),
      );

      final status = response.statusCode;
      if (status == null || status >= 400) {
        throw UpdateException(
          switch (status) {
            403 || 429 => UpdateFailure.rateLimited,
            _ => UpdateFailure.httpStatus,
          },
          detail: 'GET ${asset.name} → HTTP $status',
        );
      }

      // 206 means the server honoured the Range and the partial file is a
      // prefix. 200 means it did not — and appending a full body to a partial
      // one produces a file that is exactly the right length and completely
      // corrupt, which is the worst possible outcome. Truncate instead.
      resumed = existing > 0 && status == 206;
      if (!resumed) existing = 0;
      body = response.data!;
    } on DioException catch (error) {
      throw classifyDio(error, proxied: proxied);
    }

    var received = existing;
    final total = asset.size > 0 ? asset.size : _contentLength(body);
    final stopwatch = Stopwatch()..start();
    var lastReport = Duration.zero;

    void report() {
      if (onProgress == null) return;
      final now = stopwatch.elapsed;
      if (now - lastReport < progressInterval) return;
      lastReport = now;
      onProgress(DownloadProgress(received: received, total: total));
    }

    report();
    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in body.stream) {
        // Checked on every chunk rather than relying on the adapter to abort
        // the socket: by the time a streamed response is being consumed the
        // request has already been sent, so whether cancelling it reaches the
        // transfer is an implementation detail of dio's HTTP adapter. This is
        // not.
        if (cancelToken.isCancelled) {
          throw const UpdateException(UpdateFailure.cancelled);
        }
        sink.add(chunk);
        received += chunk.length;
        report();
      }
      await sink.flush();
      await sink.close();
    } on Object {
      // Best effort: the transfer is already failing, and letting the close
      // throw would replace a real diagnosis (the connection dropped) with a
      // misleading one (the cleanup did not work). The partial file stays.
      await sink.close().catchError((Object _) {});
      if (cancelToken.isCancelled) {
        throw const UpdateException(UpdateFailure.cancelled);
      }
      rethrow;
    }

    onProgress?.call(DownloadProgress(received: received, total: total));

    if (asset.size > 0 && received != asset.size) {
      // A short file is the one case where the partial is KNOWN to be
      // worthless: resuming from it would resume from a truncated body the
      // server itself finished sending.
      await _delete(part);
      throw UpdateException(
        UpdateFailure.sizeMismatch,
        detail: 'expected ${asset.size} bytes, got $received',
      );
    }

    await _promote(part, target);
    return await _digest(target, received);
  }

  /// Deletes every `.part` and `.apk` in [staging] except the one named [keep].
  ///
  /// Called when the offer changes: a half-downloaded 0.2.0 is 46 MB of nothing
  /// the moment the user is being offered 0.3.0.
  Future<void> sweep(Directory staging, {String? keep}) async {
    if (!staging.existsSync()) return;
    await for (final entry in staging.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (name == keep || name == '$keep.part') continue;
      if (name.endsWith('.part') || name.endsWith('.apk')) await _delete(entry);
    }
  }

  Future<void> _promote(File part, File target) async {
    // Rename over an existing file is not portable, and on the phone the old
    // APK has to go first. `rename` is atomic within a filesystem, which is
    // what makes this the safe moment to trust the name.
    if (target.existsSync()) await _delete(target);
    await part.rename(target.path);
  }

  Future<DownloadedFile> _digest(File file, int bytes) async {
    // Hashed from disk in one pass rather than fed chunk by chunk, because a
    // RESUMED download has a prefix this process never saw: the only place the
    // whole file exists is the file.
    return DownloadedFile(
      file: file,
      bytes: bytes,
      sha256: await sha256OfFile(file),
    );
  }

  Future<void> _delete(FileSystemEntity entity) async {
    try {
      await entity.delete();
    } on FileSystemException {
      // A sweep that cannot delete is not a reason to fail the download that
      // followed it; the file will be overwritten by name anyway.
    }
  }

  static int? _contentLength(ResponseBody body) {
    final raw = body.headers[Headers.contentLengthHeader]?.firstOrNull;
    final parsed = raw == null ? null : int.tryParse(raw);
    return (parsed == null || parsed <= 0) ? null : parsed;
  }

  /// Refuses a name that would write outside [Directory].
  ///
  /// The name comes from the release JSON. It is GitHub's answer about a
  /// repository the user trusts, so this is not the threat model — but a name
  /// is a path component and this is the one place that decides to treat it as
  /// one, which is cheaper than trusting every future caller to remember.
  static String _safeName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed == '.' ||
        trimmed == '..') {
      throw UpdateException(
        UpdateFailure.badPayload,
        detail: 'refusing to write "$name"',
      );
    }
    return trimmed;
  }
}
