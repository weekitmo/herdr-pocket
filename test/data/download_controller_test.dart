import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/local/download_target.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/remote_download.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The download state machine, driven against fakes.
///
/// Every case here is one where a plausible implementation reports the wrong
/// thing: a transfer that says "done" without writing, a cancel that leaves a
/// half file behind, a revoked grant discovered at the end instead of the start.
/// None of them is visible on a screenshot of the success path.
class _FakeFetcher implements RemoteFileFetcher {
  _FakeFetcher({this.failure});

  /// Sizes of the chunks the fake hands out, in order.
  final List<int> chunks = const [4, 4];

  /// Thrown when the stream is listened to, if set.
  final HerdrTransportException? failure;

  final int? size = 8;

  /// Completes when the consumer stops listening.
  final cancelled = Completer<void>();

  @override
  Stream<Uint8List> download(String absolutePath) async* {
    if (failure != null) throw failure!;
    try {
      for (final n in chunks) {
        yield Uint8List(n);
      }
      // Held open after the last chunk so a test can cancel mid-flight without
      // racing the natural end of the stream.
      await Future<void>.delayed(const Duration(seconds: 5));
    } finally {
      if (!cancelled.isCompleted) cancelled.complete();
    }
  }

  @override
  Future<RemoteFileInfo> statFile(String absolutePath) async =>
      RemoteFileInfo(sizeBytes: size, isDirectory: false);
}

class _FakeTarget implements DownloadTarget {
  bool hasAccessResult = true;
  Object? writeError;

  final List<int> written = [];
  bool deleted = false;
  bool aborted = false;
  int writeCalls = 0;

  @override
  Future<bool> hasAccess(String uri) async => hasAccessResult;

  @override
  Future<GrantedDirectory?> pick() async =>
      const GrantedDirectory(uri: 'content://tree/x', label: 'Download');

  @override
  Future<int> write({
    required String uri,
    required String name,
    required String mimeType,
    required Stream<List<int>> bytes,
    void Function(int bytesWritten)? onProgress,
  }) async {
    writeCalls++;
    try {
      await for (final chunk in bytes) {
        written.addAll(chunk);
        onProgress?.call(written.length);
      }
      final error = writeError;
      if (error != null) throw StateError('$error');
      return written.length;
    } on Object {
      aborted = true;
      deleted = true;
      rethrow;
    }
  }

  @override
  Future<bool> exists({required String uri, required String name}) async => false;

  @override
  Future<void> delete({required String uri, required String name}) async {
    deleted = true;
  }
}

/// A transport that is exactly the two capabilities the download needs.
class _FakeTransport implements HerdrTransport, RemoteFileFetcher {
  _FakeTransport(this.fetcher);

  final _FakeFetcher fetcher;

  @override
  Stream<Uint8List> download(String absolutePath) => fetcher.download(absolutePath);

  @override
  Future<RemoteFileInfo> statFile(String absolutePath) => fetcher.statFile(absolutePath);

  @override
  Future<String> roundTrip(String requestLine) async => '';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError('not used');

  @override
  Future<void> close() async {}
}

void main() {
  late _FakeTarget target;
  late _FakeFetcher fetcher;

  SharedPreferences? prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  setUp(() {
    target = _FakeTarget();
    fetcher = _FakeFetcher();
  });

  /// A container with the settings and the connection overridden, so the
  /// controller is exercised without a keystore, a socket or a host.
  Future<ProviderContainer> containerWith({
    required _FakeTransport? remote,
    bool transferEnabled = true,
    String? dirUri = 'content://tree/x',
    HerdrTransport? transportOverride,
  }) async {
    final clientTransport = transportOverride ?? remote;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs!),
        downloadTargetProvider.overrideWithValue(target),
        connectionProvider.overrideWith(
          () => _FixedConnection(
            clientTransport == null
                ? const Disconnected()
                : Online(
                    client: HerdrClient(clientTransport),
                    hello: const HerdrHello(version: '0.9.0', protocol: 22),
                    socketPath: '/tmp/herdr.sock',
                  ),
          ),
        ),
      ],
    );
    // Resolved BEFORE the controller reads it. `connectionProvider` is an
    // AsyncNotifier, so `ref.read(connectionProvider).value` is null until its
    // first build settles — and a controller that reads null would report
    // "connection lost" for a connection that is perfectly fine.
    await container.read(connectionProvider.future);
    await container
        .read(settingsProvider.notifier)
        .setFileTransferEnabled(enabled: transferEnabled);
    await container.read(settingsProvider.notifier).setDownloadDirectory(
          uri: dirUri,
          label: dirUri == null ? null : 'Download',
        );
    return container;
  }

  test('writes every byte, in order, and reports done', () async {
    final container = await containerWith(remote: _FakeTransport(fetcher));
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(target.written.length, 8, reason: 'a short write must not be "done"');
    expect(
      container.read(downloadControllerProvider),
      isA<TransferDone>()
          .having((s) => s.fileName, 'fileName', 'app.apk')
          .having((s) => s.byteCount, 'byteCount', 8)
          .having((s) => s.directoryLabel, 'directoryLabel', 'Download'),
    );
  });

  test('the setting being off stops it before any bytes move', () async {
    final container = await containerWith(
      remote: _FakeTransport(fetcher),
      transferEnabled: false,
    );
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(
      container.read(downloadControllerProvider),
      isA<TransferFailed>().having((s) => s.reason, 'reason',
          DownloadFailure.featureOff),
    );
    expect(target.writeCalls, 0, reason: 'nothing should have been opened');
  });

  test('no folder granted is its own failure, not a generic one', () async {
    // The distinction the enum exists for: this one is fixed in Settings, and
    // the sentence has to say so.
    final container = await containerWith(
      remote: _FakeTransport(fetcher),
      dirUri: null,
    );
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(
      container.read(downloadControllerProvider),
      isA<TransferFailed>()
          .having((s) => s.reason, 'reason', DownloadFailure.noDirectory),
    );
  });

  test('a revoked grant is caught BEFORE the transfer starts', () async {
    target.hasAccessResult = false;
    final container = await containerWith(remote: _FakeTransport(fetcher));
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(
      container.read(downloadControllerProvider),
      isA<TransferFailed>()
          .having((s) => s.reason, 'reason', DownloadFailure.directoryRevoked),
    );
    // The whole point of asking first: discovering this at 90% costs the user
    // the transfer, and this way it costs them nothing.
    expect(target.writeCalls, 0);
  });

  test('a host with no SFTP says so, rather than "download failed"', () async {
    // A transport with no file capability: exactly what a hardened sshd yields,
    // and the one failure whose message names the fix rather than the symptom.
    final t = _PlainTransport();
    final container = await containerWith(
      remote: _FakeTransport(fetcher),
      transportOverride: t,
    );
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(
      container.read(downloadControllerProvider),
      isA<TransferFailed>()
          .having((s) => s.reason, 'reason', DownloadFailure.sftpUnavailable),
    );
    expect(target.writeCalls, 0);
  });

  test('being offline is its own failure, not a missing subsystem', () async {
    final container = await containerWith(remote: null);
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(
      container.read(downloadControllerProvider),
      isA<TransferFailed>()
          .having((s) => s.reason, 'reason', DownloadFailure.connectionLost),
    );
  });

  test('cancelling is silent, and leaves no file behind', () async {
    // The fake holds its stream open after the last chunk, so the cancel lands
    // mid-flight rather than racing the end of the transfer.
    final container = await containerWith(remote: _FakeTransport(fetcher));
    addTearDown(container.dispose);

    final notifier = container.read(downloadControllerProvider.notifier);
    final running = notifier.start(
      remotePath: '/tmp/app.apk',
      fileName: 'app.apk',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(downloadControllerProvider), isA<TransferRunning>());

    notifier.cancel();
    await running;

    expect(
      container.read(downloadControllerProvider),
      isA<TransferIdle>(),
      reason: 'cancelling is a choice; reporting it as a failure would be a lie',
    );
    expect(target.aborted, isTrue, reason: 'the platform write must be aborted');
    expect(
      target.deleted,
      isTrue,
      reason: 'a half-written file must not keep the name it was given',
    );
    expect(
      fetcher.cancelled.isCompleted,
      isTrue,
      reason: 'the SSH stream must be cancelled, not merely ignored',
    );
  });

  test('a connection lost mid-transfer is reported as such', () async {
    final failing = _FakeFetcher(
      failure: HerdrTransportException(
        TransportFailure.streamClosed,
        'dropped',
      ),
    );
    final container = await containerWith(remote: _FakeTransport(failing));
    addTearDown(container.dispose);

    await container.read(downloadControllerProvider.notifier).start(
          remotePath: '/tmp/app.apk',
          fileName: 'app.apk',
        );

    expect(
      container.read(downloadControllerProvider),
      isA<TransferFailed>()
          .having((s) => s.reason, 'reason', DownloadFailure.connectionLost),
    );
    expect(target.deleted, isTrue);
  });
}

/// A transport with no file capability at all — what a host whose sshd has no
/// `Subsystem sftp` line actually yields to this app.
class _PlainTransport implements HerdrTransport {
  @override
  Future<String> roundTrip(String requestLine) async => '';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError('not used');

  @override
  Future<void> close() async {}
}

/// A connection notifier pinned to one status, so the controller can read a
/// client without there being a socket anywhere.
class _FixedConnection extends ConnectionNotifier {
  _FixedConnection(this._status);

  final ConnectionStatus _status;

  @override
  Future<ConnectionStatus> build() async => _status;
}
