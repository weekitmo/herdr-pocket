import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/remote_bytes.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// Tests for reading a file's bytes for a preview.
///
/// The two things a preview needs and a download does not are the cap and the
/// "no destination", and both are decided here — where they can be tested
/// without a phone, a host or a connection.
void main() {
  group('RemoteBytes.read', () {
    test('returns the whole file, in order', () async {
      final fetcher = _FakeFetcher(
        sizeBytes: 6,
        chunks: [utf8Bytes('abc'), utf8Bytes('def')],
      );

      final result = await RemoteBytes(fetcher).read('/tmp/shot.png');

      expect(result, isA<RemoteBytesData>());
      expect(bytesOf(result), utf8Bytes('abcdef'));
    });

    test('refuses a file past the cap WITHOUT transferring it', () async {
      // The whole point of asking for the size first: a 300 MB video the user
      // tapped by accident must not come down the wire to be told it is large.
      final fetcher = _FakeFetcher(sizeBytes: 5000, chunks: [utf8Bytes('x')]);

      final result = await RemoteBytes(fetcher, maxBytes: 4096).read('/tmp/big.png');

      expect(result, isA<RemoteBytesTooLarge>());
      expect((result as RemoteBytesTooLarge).sizeBytes, 5000);
      expect(fetcher.downloads, isEmpty, reason: 'the file was opened anyway');
    });

    test('stops mid-stream when the far end did not report a size', () async {
      // A far end that answers `stat` without a size, or lies about one. The
      // read is stopped by what has actually arrived, and the subscription is
      // cancelled rather than drained.
      final fetcher = _FakeFetcher(
        sizeBytes: null,
        chunks: [utf8Bytes('a' * 3000), utf8Bytes('b' * 3000)],
      );

      final result = await RemoteBytes(fetcher, maxBytes: 4096).read('/tmp/unknown.png');

      expect(result, isA<RemoteBytesTooLarge>());
      expect(fetcher.cancelled, isTrue);
    });

    test('a file exactly at the cap is fine', () async {
      // Off-by-one in either direction is the difference between "your
      // screenshot opens" and "your screenshot is too large".
      final fetcher = _FakeFetcher(sizeBytes: 8, chunks: [utf8Bytes('a' * 8)]);
      final result = await RemoteBytes(fetcher, maxBytes: 8).read('/tmp/edge.png');
      expect(result, isA<RemoteBytesData>());
      expect((result as RemoteBytesData).bytes.length, 8);
    });

    test('a directory is its own answer, not an empty file', () async {
      final fetcher = _FakeFetcher(sizeBytes: null, isDirectory: true);
      final result = await RemoteBytes(fetcher).read('/tmp/somedir');
      expect(result, isA<RemoteBytesFailed>());
      expect(
        (result as RemoteBytesFailed).reason,
        RemoteBytesFailure.isDirectory,
      );
      expect(fetcher.downloads, isEmpty);
    });

    test('no SFTP on the host has its own reason', () async {
      // One line in `sshd_config`, and a user told only "could not read" would
      // retry forever. The sentence depends on this distinction.
      final fetcher = _FakeFetcher(
        error: HerdrTransportException(
          TransportFailure.sftpUnavailable,
          'no sftp subsystem',
        ),
      );

      final result = await RemoteBytes(fetcher).read('/tmp/shot.png');

      expect(result, isA<RemoteBytesFailed>());
      expect(
        (result as RemoteBytesFailed).reason,
        RemoteBytesFailure.sftpUnavailable,
      );
    });

    test('a dropped connection is not "the file is gone"', () async {
      final fetcher = _FakeFetcher(
        sizeBytes: 10,
        chunks: [utf8Bytes('abc')],
        streamError: HerdrTransportException(
          TransportFailure.streamClosed,
          'channel closed',
        ),
      );

      final result = await RemoteBytes(fetcher).read('/tmp/shot.png');

      expect(result, isA<RemoteBytesFailed>());
      expect(
        (result as RemoteBytesFailed).reason,
        RemoteBytesFailure.connectionLost,
      );
    });

    test('an empty file is zero bytes, not a failure', () async {
      final fetcher = _FakeFetcher(sizeBytes: 0, chunks: const []);
      final result = await RemoteBytes(fetcher).read('/tmp/empty.png');
      expect(result, isA<RemoteBytesData>());
      expect((result as RemoteBytesData).bytes, isEmpty);
    });

    test('an empty path is a programming error, and throws', () async {
      // Distinct from every failure above: this is a bug in the caller, and it
      // should be loud rather than rendered as a nice sentence.
      expect(
        () => RemoteBytes(_FakeFetcher()).read(''),
        throwsArgumentError,
      );
    });
  });
}

Uint8List bytesOf(RemoteBytesResult result) => (result as RemoteBytesData).bytes;

Uint8List utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);

/// A fetcher that answers with what a test tells it to.
class _FakeFetcher implements RemoteFileFetcher {
  _FakeFetcher({
    this.sizeBytes,
    this.chunks = const [],
    this.isDirectory = false,
    this.error,
    this.streamError,
  });

  final int? sizeBytes;
  final List<Uint8List> chunks;
  final bool isDirectory;
  final HerdrTransportException? error;
  final HerdrTransportException? streamError;

  /// Every path whose bytes were asked for.
  final List<String> downloads = [];

  /// Whether the subscription was cancelled before the stream ended.
  bool cancelled = false;

  @override
  Future<RemoteFileInfo> statFile(String absolutePath) async {
    final error = this.error;
    if (error != null) throw error;
    return RemoteFileInfo(sizeBytes: sizeBytes, isDirectory: isDirectory);
  }

  @override
  Stream<Uint8List> download(String absolutePath) {
    downloads.add(absolutePath);
    final controller = StreamController<Uint8List>();
    chunks.forEach(controller.add);
    final error = streamError ?? this.error;
    if (error != null) {
      controller.addError(error);
    }
    controller.onCancel = () => cancelled = true;
    unawaited(controller.close());
    return controller.stream;
  }
}
