import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/local/download_target.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';

/// Why a download could not be carried out.
///
/// A tagged enum rather than a message, for the reason the whole codebase keeps
/// giving: classifying by matching on error text is how guidance erodes, and
/// each of these needs a different sentence and a different next step.
enum DownloadFailure {
  /// The file-transfer setting is off.
  featureOff,

  /// The setting is on but no folder has been granted.
  noDirectory,

  /// The grant is gone — the folder was deleted or the permission revoked.
  directoryRevoked,

  /// The host has no SFTP subsystem, so nothing can move at all.
  sftpUnavailable,

  /// The far end refused, or the path is gone.
  remoteFailed,

  /// The connection dropped mid-transfer.
  connectionLost,

  /// Anything else, with the detail preserved for diagnostics.
  unknown,
}

/// What the transfer UI is showing.
sealed class TransferState {
  const TransferState();
}

/// Nothing happening.
class TransferIdle extends TransferState {
  /// The one idle state.
  const TransferIdle();
}

/// A transfer is in flight.
class TransferRunning extends TransferState {
  /// Holds one in-flight transfer.
  const TransferRunning({
    required this.fileName,
    required this.remotePath,
    this.received = 0,
    this.total,
  });

  final String fileName;
  final String remotePath;
  final int received;

  /// Null when the far end did not report a size. See [transferFraction].
  final int? total;

  /// How far along, as 0..1, or null when it cannot be known.
  double? get fraction => transferFraction(received: received, total: total);
}

/// The bytes landed.
class TransferDone extends TransferState {
  /// Holds one completed transfer.
  const TransferDone({
    required this.fileName,
    required this.byteCount,
    required this.directoryLabel,
  });

  final String fileName;
  final int byteCount;

  /// Where it went, as the folder is named on the phone.
  final String directoryLabel;
}

/// It did not land, and here is the class of reason.
class TransferFailed extends TransferState {
  /// Holds one failure.
  const TransferFailed(this.reason, {this.fileName, this.detail});

  final DownloadFailure reason;
  final String? fileName;

  /// For diagnostics. The UI localises from [reason] — see [DownloadFailure].
  final String? detail;
}

/// Raised internally to unwind the write when the user cancels.
///
/// Private, and never surfaced: cancelling is a choice rather than a failure, so
/// the state machine goes back to idle and says nothing. Carrying it as an error
/// through the write is what makes the half-written file get deleted, which is
/// the part that actually matters.
class _Cancelled implements Exception {
  const _Cancelled();
}

/// Moves one file from the connected host to the phone.
///
/// ## Why the piping happens here rather than inside the target
///
/// Cancellation has to reach the SSH stream. If the platform layer were handed
/// the network stream directly, the only way to stop it would be to tear down
/// the connection — which would also drop the terminal, the status board and
/// every other channel. Feeding the transfer through a local controller keeps
/// the cancel local: the SSH subscription is cancelled, the SSH session lives on.
class DownloadController extends Notifier<TransferState> {
  /// How often the progress state is published.
  ///
  /// The SSH read hands over ~16 KiB at a time, which for a 48 MB file is three
  /// thousand chunks. Rebuilding the UI three thousand times to move a bar is
  /// how a transfer makes the whole app janky — and the number that changes is a
  /// percentage, so it only has ten useful values anyway.
  static const progressInterval = Duration(milliseconds: 120);

  StreamSubscription<List<int>>? _fetcherSubscription;

  /// Aborts the write side. Null when nothing is running.
  void Function()? _abort;

  DateTime _lastPublished = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  TransferState build() {
    ref.onDispose(_tearDown);
    return const TransferIdle();
  }

  /// Starts a download of [remotePath] (named [fileName] on the phone).
  ///
  /// Returns when the transfer finishes, fails or is cancelled — so a caller
  /// that wants to know the outcome can await it, and one that does not can
  /// ignore it. The state stream is the UI's channel either way.
  Future<void> start({
    required String remotePath,
    required String fileName,
  }) async {
    if (state is TransferRunning) return;
    _tearDown();

    final settings = ref.read(settingsProvider);
    if (!settings.fileTransferEnabled) {
      state = const TransferFailed(DownloadFailure.featureOff);
      return;
    }

    final target = ref.read(downloadTargetProvider);
    if (target == null) {
      state = const TransferFailed(DownloadFailure.unknown, detail: 'no target');
      return;
    }

    final dirUri = settings.downloadDirUri;
    if (dirUri == null || dirUri.isEmpty) {
      state = TransferFailed(DownloadFailure.noDirectory, fileName: fileName);
      return;
    }

    final status = ref.read(connectionProvider).value;
    if (status is! Online) {
      state = TransferFailed(DownloadFailure.connectionLost, fileName: fileName);
      return;
    }
    final Object transport = status.client.transport;
    if (transport is! RemoteFileFetcher) {
      state = TransferFailed(DownloadFailure.sftpUnavailable, fileName: fileName);
      return;
    }
    // Promoted by the `is!` above; no cast needed.
    final fetcher = transport;

    // Asked before the first byte rather than assumed: a grant survives
    // reboots, but it does not survive the folder being deleted, and finding
    // that out at 90% is a far worse way to learn it.
    if (!await target.hasAccess(dirUri)) {
      state = TransferFailed(DownloadFailure.directoryRevoked, fileName: fileName);
      return;
    }

    // The size is fetched BEFORE the stream opens, because the message it
    // enables ("48 MiB") is what turns a spinner into an answer.
    int? total;
    try {
      final info = await fetcher.statFile(remotePath);
      total = info.sizeBytes;
    } on HerdrTransportException catch (e) {
      state = TransferFailed(_failureFor(e), fileName: fileName, detail: e.message);
      return;
    } on Object catch (e) {
      state = TransferFailed(DownloadFailure.unknown, fileName: fileName, detail: '$e');
      return;
    }

    state = TransferRunning(
      fileName: fileName,
      remotePath: remotePath,
      total: total,
    );

    // The seam between the network stream and the file stream. Closing it with
    // an error is what makes the platform layer abort AND delete; simply
    // stopping it would look like a short but successful file.
    final feed = StreamController<List<int>>();
    _abort = () {
      if (feed.isClosed) return;
      feed.addError(const _Cancelled());
      unawaited(feed.close());
    };

    final subscription = fetcher.download(remotePath).listen(
      (chunk) {
        if (!feed.isClosed) feed.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!feed.isClosed) {
          feed.addError(e, st);
          unawaited(feed.close());
        }
      },
      onDone: () {
        if (!feed.isClosed) unawaited(feed.close());
      },
      cancelOnError: true,
    );
    _fetcherSubscription = subscription;

    try {
      // The byte count comes back FROM THE WRITE, not from the last published
      // progress state. Progress is throttled, so the state at this moment can
      // be one interval behind — which on a fast transfer is the whole file.
      final written = await target.write(
        uri: dirUri,
        name: fileName,
        mimeType: mimeTypeForName(fileName),
        bytes: feed.stream,
        onProgress: _publishProgress,
      );
      state = TransferDone(
        fileName: fileName,
        byteCount: written,
        directoryLabel: settings.downloadDirLabel ?? '',
      );
    } on _Cancelled {
      // A choice, not a failure. Silent by design.
      state = const TransferIdle();
    } on LocalWriteException catch (e) {
      state = TransferFailed(
        _failureForLocal(e),
        fileName: fileName,
        detail: e.detail,
      );
    } on HerdrTransportException catch (e) {
      state = TransferFailed(_failureFor(e), fileName: fileName, detail: e.message);
    } on Object catch (e) {
      state = TransferFailed(DownloadFailure.unknown, fileName: fileName, detail: '$e');
    } finally {
      _tearDown();
      // Cancelled here as well as in `_tearDown`, which is what actually keeps
      // the two ends of this method's lifecycle visible to the analyzer — the
      // field exists so `cancel()` can reach a transfer that is already running.
      // Cancelling twice is a no-op.
      await subscription.cancel();
    }
  }

  /// Stops the transfer in flight, if there is one.
  void cancel() => _abort?.call();

  /// Clears a finished or failed state so the sheet can close.
  void reset() {
    if (state is TransferRunning) return;
    state = const TransferIdle();
  }

  void _publishProgress(int received) {
    final now = DateTime.now();
    final done = state is TransferDone || state is TransferFailed;
    if (!done && now.difference(_lastPublished) < progressInterval) return;
    _lastPublished = now;

    final current = state;
    if (current is! TransferRunning) return;
    state = TransferRunning(
      fileName: current.fileName,
      remotePath: current.remotePath,
      received: received,
      total: current.total,
    );
  }

  void _tearDown() {
    final sub = _fetcherSubscription;
    _fetcherSubscription = null;
    _abort = null;
    unawaited(sub?.cancel());
  }

  static DownloadFailure _failureFor(HerdrTransportException e) => switch (e.failure) {
        TransportFailure.sftpUnavailable => DownloadFailure.sftpUnavailable,
        TransportFailure.streamClosed => DownloadFailure.connectionLost,
        TransportFailure.timeout => DownloadFailure.connectionLost,
        TransportFailure.unknown => DownloadFailure.remoteFailed,
        _ => DownloadFailure.unknown,
      };

  static DownloadFailure _failureForLocal(LocalWriteException e) =>
      switch (e.reason) {
        LocalWriteFailure.noDirectory => DownloadFailure.noDirectory,
        LocalWriteFailure.revoked => DownloadFailure.directoryRevoked,
        LocalWriteFailure.outOfSpace => DownloadFailure.unknown,
        LocalWriteFailure.unsupported => DownloadFailure.unknown,
        LocalWriteFailure.unknown => DownloadFailure.unknown,
      };
}

/// The transfer state for the UI.
final downloadControllerProvider =
    NotifierProvider<DownloadController, TransferState>(DownloadController.new);
