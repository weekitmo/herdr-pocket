/// Reading a file's BYTES, for the previews that cannot be text.
///
/// The mirror of [RemoteFs.read], which reads a file's text over a shell
/// command. An image is not text: running `head` over a PNG gives a byte count
/// and a "binary file" verdict, which is exactly what the app used to say about
/// every screenshot in a repository. The bytes have to come over the channel
/// that moves bytes — SFTP, through the `RemoteFileFetcher` the download feature
/// already uses — and this is that read, with the two things a preview needs and
/// a download does not: a **cap** (a 300 MB video must not be pulled into RAM
/// because the user tapped it) and **no destination** (nothing is written to the
/// phone; the bytes live in memory for as long as the page does).
///
/// The cap is a real answer rather than an error: a file past it is reported as
/// too large, WITH its size, so the sentence can say how large.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';


/// Why a byte read produced nothing.
///
/// A tagged enum for the reason the whole codebase keeps giving: classifying by
/// matching on error text is how guidance erodes, and "this host has no SFTP
/// subsystem" needs a different sentence — and a different user action — from
/// "the connection dropped".
enum RemoteBytesFailure {
  /// This connection cannot move bytes at all. The local-socket transport has
  /// no SFTP, and neither has a phone that is not online.
  noChannel,

  /// SFTP is not enabled on the host. One line in `sshd_config`, and no amount
  /// of retrying will change it.
  sftpUnavailable,

  /// The path is gone, or the far end refused.
  notFound,

  /// The path is a directory, so there are no bytes to show.
  isDirectory,

  /// The connection dropped mid-read.
  connectionLost,

  /// Anything else, with the detail preserved for diagnostics.
  unknown,
}

/// The outcome of [RemoteBytes.read].
sealed class RemoteBytesResult {
  const RemoteBytesResult();
}

/// The bytes, whole.
///
/// Never partial: half a PNG is not a smaller picture, it is a decode failure
/// with a misleading shape.
class RemoteBytesData extends RemoteBytesResult {
  /// Holds one file's bytes.
  const RemoteBytesData(this.bytes);

  final Uint8List bytes;
}

/// The file is bigger than this app will pull into memory.
///
/// Carries the size when the far end reported one, because "48.3 MiB" is what
/// turns "too large" into a decision the reader can make.
class RemoteBytesTooLarge extends RemoteBytesResult {
  /// Holds the size, if it is known.
  const RemoteBytesTooLarge({this.sizeBytes});

  final int? sizeBytes;
}

/// A read that did not produce bytes.
class RemoteBytesFailed extends RemoteBytesResult {
  /// Holds one failure and why.
  const RemoteBytesFailed(this.reason, this.detail);

  final RemoteBytesFailure reason;

  /// What the transport said, for diagnostics. Not shown to the user: the UI
  /// localises from [reason].
  final String detail;
}

/// Reads whole files into memory, over the connection that is already open.
class RemoteBytes {
  /// Wraps one fetcher.
  const RemoteBytes(this._fetcher, {this.maxBytes = defaultMaxBytes});

  /// How much of a file this app will hold in memory.
  ///
  /// 24 MiB, and the number is about the DECODE rather than the transfer: a
  /// 24 MiB JPEG can be 100 megapixels, and at four bytes per pixel that is
  /// 400 MB of bitmap on a phone with 6 GB of RAM and other apps open. The image
  /// view also caps the decode itself, so this is the second of two limits
  /// rather than the only one — but it is the one that can be explained in a
  /// sentence ("this file is 40 MiB"), which is why it exists separately.
  static const int defaultMaxBytes = 24 * 1024 * 1024;

  final RemoteFileFetcher _fetcher;
  final int maxBytes;

  /// Reads [absolutePath] whole, or says why not.
  ///
  /// Never throws: every failure the far end can report is an outcome, and the
  /// page has to say which one it was. A programming error (an empty path) still
  /// throws, because that is a bug rather than a condition.
  Future<RemoteBytesResult> read(String absolutePath) async {
    if (absolutePath.isEmpty) {
      throw ArgumentError.value(absolutePath, 'absolutePath', 'must not be empty');
    }

    // Asked BEFORE the transfer: a size the far end reports is a round trip
    // saved, and for the common case — a 40 MiB video the user tapped by
    // accident — it means the file is never opened at all.
    try {
      final info = await _fetcher.statFile(absolutePath);
      if (info.isDirectory) {
        return const RemoteBytesFailed(
          RemoteBytesFailure.isDirectory,
          'the path is a directory',
        );
      }
      final size = info.sizeBytes;
      if (size != null && size > maxBytes) {
        return RemoteBytesTooLarge(sizeBytes: size);
      }
    } on HerdrTransportException catch (e) {
      return RemoteBytesFailed(_failureFor(e), e.message);
    } on Object catch (e) {
      return RemoteBytesFailed(RemoteBytesFailure.unknown, '$e');
    }

    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in _fetcher.download(absolutePath)) {
        builder.add(chunk);
        // A far end that reports no size, or lies about one, is stopped here.
        // Returning from inside `await for` cancels the subscription, which is
        // what closes the file handle and the channel — the same discipline the
        // download controller uses, for the same reason.
        if (builder.length > maxBytes) {
          return RemoteBytesTooLarge(sizeBytes: builder.length);
        }
      }
    } on HerdrTransportException catch (e) {
      return RemoteBytesFailed(_failureFor(e), e.message);
    } on Object catch (e) {
      return RemoteBytesFailed(RemoteBytesFailure.unknown, '$e');
    }

    return RemoteBytesData(builder.takeBytes());
  }
}

/// Maps a transport failure to the reason the UI has a sentence for.
RemoteBytesFailure _failureFor(HerdrTransportException e) => switch (e.failure) {
      TransportFailure.sftpUnavailable => RemoteBytesFailure.sftpUnavailable,
      TransportFailure.connectFailed ||
      TransportFailure.timeout ||
      TransportFailure.streamClosed =>
        RemoteBytesFailure.connectionLost,
      TransportFailure.authenticationFailed ||
      TransportFailure.hostKeyUnknown ||
      TransportFailure.hostKeyChanged ||
      TransportFailure.forwardingRefused ||
      TransportFailure.unknown =>
        RemoteBytesFailure.unknown,
    };

/// Picks the byte channel out of a live connection.
///
/// Null is a real answer, not a loading state — the same contract
/// [remoteRunnerProvider] has, and for the same reason: a transport that cannot
/// move bytes never will, and the page needs to say so rather than spin.
final remoteFetcherProvider = Provider<RemoteFileFetcher?>(
  (ref) => _fetcherOf(ref.watch(connectionProvider).value),
);

RemoteFileFetcher? _fetcherOf(ConnectionStatus? status) {
  if (status is! Online) return null;
  // Two steps on purpose. Dart does not promote through a getter, so the test
  // has to happen on a local, and the declared type is what makes the answer
  // "a fetcher or nothing" rather than "a transport of some kind".
  final Object transport = status.client.transport;
  return transport is RemoteFileFetcher ? transport : null;
}
