import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/update/apk_installer.dart';
import 'package:herdr_pocket/data/update/asset_downloader.dart';
import 'package:herdr_pocket/data/update/release_client.dart';
import 'package:herdr_pocket/data/update/update_controller.dart';
import 'package:herdr_pocket/data/update/update_exception.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/update/app_version.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';
import 'package:herdr_pocket/domain/update/system_proxy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The update path, driven against a local server that speaks like GitHub.
///
/// NOT MOCKED AT THE HTTP LAYER, deliberately. Every case here is about how the
/// bytes MOVE — a Range that came back as 200, a cancel that has to leave the
/// partial file alone, a body that stopped short of the size it promised. A
/// client stub would assert that this code calls the functions this code calls,
/// which is the one thing that cannot be wrong in a way that matters.
void main() {
  // `SharedPreferences.setMockInitialValues` swaps in an in-memory store, and
  // the container work below is plain `test`, not `testWidgets` — so nothing
  // else has initialised the binding this file's platform plugins expect.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeGithub github;
  late Directory staging;
  late UpdateHttp http;

  setUp(() async {
    // FLUTTER'S TEST BINDING STUBS OUT HTTP: every request through `dart:io`'s
    // HttpClient comes back as a 400 with no connection made — the wording of
    // the warning it prints says a test using a real server cannot work. It is
    // a safety net for tests that talk to the network by accident, and this
    // file is the opposite of that: the local server IS the subject.
    HttpOverrides.global = null;

    github = await _FakeGithub.start();
    staging = Directory.systemTemp.createTempSync('herdr-update-');
    http = UpdateHttp(
      resolver: ProxyResolver(source: const _NoProxy()),
      dio: Dio(BaseOptions(baseUrl: github.base)),
    );
  });

  tearDown(() async {
    await github.close();
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  });

  AssetDownloader downloader() =>
      AssetDownloader(http: http, userAgent: 'HerdrPocket/test');
  ReleaseClient client() =>
      ReleaseClient(http: http, userAgent: 'HerdrPocket/test');

  group('AssetDownloader', () {
    test('writes the bytes and reports the size that actually arrived', () async {
      github.body = List.generate(64, (i) => i);
      final asset = _asset('HerdrPocket-0.2.0-arm64-v8a.apk', size: github.body.length);
      final progress = <DownloadProgress>[];

      final result = await downloader().download(
        asset: asset,
        staging: staging,
        cancelToken: CancelToken(),
        onProgress: progress.add,
      );

      expect(result.bytes, github.body.length);
      expect(result.file.readAsBytesSync(), github.body);
      expect(File('${result.file.path}.part').existsSync(), isFalse);
      // The digest is of the file on disk, which is the thing the release's
      // checksums.txt is about.
      expect(result.sha256, hasLength(64));
      expect(progress.last.received, github.body.length);
    });

    test('a cancelled transfer keeps the partial file so it can be resumed', () async {
      // 256 KB IN 16 KB CHUNKS, not eight bytes in eight pieces. dart:io hands
      // the body over in whatever the socket delivered, and a small body
      // arrives as ONE chunk after the response finishes — so a cancel test
      // written on 64 bytes proves nothing about a cancel that happens
      // mid-transfer. Verified: 16 KB chunks arrive roughly every 20 ms.
      github.body = List.filled(256 * 1024, 7);
      github.chunkSize = 16 * 1024;
      github.chunkDelay = const Duration(milliseconds: 20);
      final asset =
          _asset('HerdrPocket-0.2.0-arm64-v8a.apk', size: github.body.length);

      final token = CancelToken();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 150))
            .then((_) => token.cancel()),
      );

      await expectLater(
        downloader().download(asset: asset, staging: staging, cancelToken: token),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.failure,
            'failure',
            UpdateFailure.cancelled,
          ),
        ),
      );

      final part = File('${staging.path}/${asset.name}.part');
      expect(part.existsSync(), isTrue, reason: 'the partial file IS the resume');
      expect(part.lengthSync(), greaterThan(0));
      expect(part.lengthSync(), lessThan(github.body.length));
      // The final name is what the installer would be handed, and a partial
      // file must never wear it.
      expect(File('${staging.path}/${asset.name}').existsSync(), isFalse);
    });

    test('a resumed transfer asks for the rest and appends it', () async {
      github.body = List.generate(64, (i) => i);
      final asset = _asset('HerdrPocket-0.2.0-arm64-v8a.apk', size: 64);
      final part = File('${staging.path}/${asset.name}.part')
        ..writeAsBytesSync(github.body.sublist(0, 40));

      final result = await downloader().download(
        asset: asset,
        staging: staging,
        cancelToken: CancelToken(),
      );

      // The header is the whole feature: without it the server would send all
      // 64 bytes and the file would end up 104 bytes long and corrupt.
      expect(github.ranges.single, 'bytes=40-');
      expect(result.file.readAsBytesSync(), github.body);
      expect(part.existsSync(), isFalse);
    });

    test('a server that ignores Range gets truncated, not appended to', () async {
      github.body = List.generate(64, (i) => i);
      github.supportsRange = false;
      final asset = _asset('HerdrPocket-0.2.0-arm64-v8a.apk', size: 64);
      // 40 bytes of a DIFFERENT download: appending to this produces a file of
      // exactly the right length and completely wrong contents.
      File('${staging.path}/${asset.name}.part')
          .writeAsBytesSync(List.filled(40, 9));

      final result = await downloader().download(
        asset: asset,
        staging: staging,
        cancelToken: CancelToken(),
      );

      expect(result.bytes, 64);
      expect(result.file.readAsBytesSync(), github.body);
    });

    test('a body that stopped short is deleted, because resuming it is worthless', () async {
      github.body = List.filled(64, 3);
      github.truncateTo = 20;
      final asset = _asset('HerdrPocket-0.2.0-arm64-v8a.apk', size: 64);
      final part = File('${staging.path}/${asset.name}.part');

      await expectLater(
        downloader().download(asset: asset, staging: staging, cancelToken: CancelToken()),
        throwsA(
          isA<UpdateException>()
              .having((e) => e.failure, 'failure', UpdateFailure.sizeMismatch),
        ),
      );

      // The server itself finished sending after 20 bytes: resuming from there
      // would resume from a truncated body, so this partial has to go.
      expect(part.existsSync(), isFalse);
    });

    test('a sweep clears other versions and keeps the one in flight', () async {
      const keep = 'HerdrPocket-0.2.0-arm64-v8a.apk';
      File('${staging.path}/$keep.part').writeAsBytesSync(const [1]);
      File('${staging.path}/HerdrPocket-0.1.0-arm64-v8a.apk').writeAsBytesSync(const [2]);
      File('${staging.path}/HerdrPocket-0.1.0-universal.apk.part').writeAsBytesSync(const [3]);

      await downloader().sweep(staging, keep: keep);

      expect(File('${staging.path}/$keep.part').existsSync(), isTrue);
      expect(File('${staging.path}/HerdrPocket-0.1.0-arm64-v8a.apk').existsSync(), isFalse);
      expect(File('${staging.path}/HerdrPocket-0.1.0-universal.apk.part').existsSync(), isFalse);
    });
  });

  group('ReleaseClient', () {
    test('a 403 from GitHub is a rate limit, not a generic error', () async {
      github.releasesStatus = 403;
      await expectLater(
        client().releases(),
        throwsA(
          isA<UpdateException>()
              .having((e) => e.failure, 'failure', UpdateFailure.rateLimited),
        ),
      );
    });

    test('a 200 that is not a release list is a bad payload, not an empty repo', () async {
      // The shape a public Wi-Fi sign-in page arrives in.
      github.releasesBody = '<html>Sign in</html>';
      await expectLater(
        client().releases(),
        throwsA(
          isA<UpdateException>()
              .having((e) => e.failure, 'failure', UpdateFailure.badPayload),
        ),
      );
    });

    test('reads the checksums the release ships', () async {
      github.releases.add(_releaseJson());
      github.checksums = '${'a' * 64}  HerdrPocket-0.2.0-arm64-v8a.apk\n';
      final release = (await client().releases()).single;
      expect(await client().checksums(release), {
        'HerdrPocket-0.2.0-arm64-v8a.apk': 'a' * 64,
      });
    });
  });

  group('UpdateController', () {
    late _FakeTarget target;

    setUp(() {
      target = _FakeTarget(staging);
    });

    Future<ProviderContainer> containerFor({
      required SharedPreferences prefs,
      String abi = 'arm64-v8a',
      String version = '0.1.0',
    }) async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appVersionProvider.overrideWithValue(AppVersion.tryParse(version)),
          deviceAbiProvider.overrideWithValue(abi),
          releaseClientProvider.overrideWith(
            (ref) => ReleaseClient(http: http, userAgent: 'test'),
          ),
          assetDownloaderProvider.overrideWith(
            (ref) => AssetDownloader(http: http, userAgent: 'test'),
          ),
          apkInstallTargetProvider.overrideWithValue(target),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test("a newer release becomes an offer of this device's APK", () async {
      github.body = List.filled(8, 1);
      github.releases
        ..clear()
        ..add(_releaseJson())
        // The CLI publishes into the same repository; it must not win.
        ..add(_releaseJson(tag: 'hdp-v9.0.0', assets: [('hdp-linux-amd64', 4)]));

      final container = await containerFor(prefs: await _prefs());
      final outcome = await container.read(updateControllerProvider.notifier).check();

      expect(outcome, UpdateCheckOutcome.available);
      final phase = container.read(updateControllerProvider).phase;
      expect(phase, isA<UpdateAvailable>());
      expect((phase as UpdateAvailable).asset.name, 'HerdrPocket-0.2.0-arm64-v8a.apk');
      expect(phase.release.version, AppVersion.tryParse('0.2.0'));
    });

    test('the version it found survives a restart', () async {
      final prefs = await _prefs();
      github.releases.add(_releaseJson());

      final first = await containerFor(prefs: prefs);
      await first.read(updateControllerProvider.notifier).check();

      // A fresh container over the same storage: what the settings row shows
      // before anything has been asked this launch.
      final second = await containerFor(prefs: prefs);
      final status = second.read(updateControllerProvider);
      expect(status.phase, isA<UpdateIdle>());
      expect(status.latest, AppVersion.tryParse('0.2.0'));
      expect(status.checkedAt, isNotNull);
    });

    test('the installed version is up to date rather than an offer', () async {
      github.releases.add(_releaseJson());
      final container = await containerFor(prefs: await _prefs(), version: '0.2.0');

      final outcome = await container.read(updateControllerProvider.notifier).check();

      expect(outcome, UpdateCheckOutcome.upToDate);
      expect(
        container.read(updateControllerProvider).phase,
        isA<UpdateUpToDate>(),
      );
    });

    test('a failed request does not forget what a previous one found', () async {
      final prefs = await _prefs();
      github.releases.add(_releaseJson());
      final first = await containerFor(prefs: prefs);
      await first.read(updateControllerProvider.notifier).check();

      github.releasesStatus = 500;
      final second = await containerFor(prefs: prefs);
      final outcome = await second.read(updateControllerProvider.notifier).check();

      expect(outcome, UpdateCheckOutcome.failed);
      // "I could not ask" is not "there is nothing".
      expect(
        second.read(updateControllerProvider).latest,
        AppVersion.tryParse('0.2.0'),
      );
    });

    test('a release with no build for this CPU is a failure, not an offer', () async {
      // No universal build in this one: a release with a universal APK offers
      // it to every CPU, which is the whole point of that file.
      github.releases.add(
        _releaseJson(
          assets: [
            ('HerdrPocket-0.2.0-arm64-v8a.apk', 8),
            ('HerdrPocket-0.2.0-armeabi-v7a.apk', 8),
          ],
        ),
      );
      final container = await containerFor(prefs: await _prefs(), abi: 'x86_64');

      final outcome = await container.read(updateControllerProvider.notifier).check();

      expect(outcome, UpdateCheckOutcome.failed);
      expect(
        (container.read(updateControllerProvider).phase as UpdateFailed).reason,
        UpdateFailure.noAssetForDevice,
      );
    });

    test('downloading reaches a checked, installable APK', () async {
      github.body = List.filled(8, 5);
      github.checksums = '${_sha256(github.body)}  HerdrPocket-0.2.0-arm64-v8a.apk\n';
      github.releases.add(_releaseJson());

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();

      final phase = container.read(updateControllerProvider).phase;
      expect(phase, isA<UpdateReady>());
      final ready = phase as UpdateReady;
      expect(ready.file.readAsBytesSync(), github.body);
      expect(ready.canInstall, isTrue);

      await notifier.install();
      expect(target.installed, isTrue);
    });

    test('a checksum that does not match deletes the file and says so', () async {
      github.body = List.filled(8, 5);
      github.checksums = '${'b' * 64}  HerdrPocket-0.2.0-arm64-v8a.apk\n';
      github.releases.add(_releaseJson());

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();

      final phase = container.read(updateControllerProvider).phase;
      expect((phase as UpdateFailed).reason, UpdateFailure.checksum);
      // 46 MB of a file that failed its checksum is not worth keeping, and a
      // kept one would make the next attempt "resume" from a corrupt prefix.
      expect(File('${staging.path}/HerdrPocket-0.2.0-arm64-v8a.apk').existsSync(), isFalse);
      expect(File('${staging.path}/HerdrPocket-0.2.0-arm64-v8a.apk.part').existsSync(), isFalse);
    });

    test('an APK signed with another key is refused, with the reason', () async {
      github.body = List.filled(8, 5);
      github.releases.add(_releaseJson());
      target.inspection = const ApkInspection(
        packageName: installedApplicationId,
        versionCode: 42,
        signatureMatches: false,
      );

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();

      // The failure the installer would report as "app not installed" with no
      // explanation, and whose only remedy deletes the user's saved machines.
      final failed = container.read(updateControllerProvider).phase as UpdateFailed;
      expect(
        failed.reason,
        UpdateFailure.signatureMismatch,
        reason: 'detail=${failed.detail} releases=${github.releases.length}',
      );
    });

    test('a complete download from an earlier run is adopted, not fetched again', () async {
      github.body = List.filled(64, 5);
      github.checksums = '${_sha256(github.body)}  HerdrPocket-0.2.0-arm64-v8a.apk\n';
      github.releases.add(_releaseJson(assets: [('HerdrPocket-0.2.0-arm64-v8a.apk', 64)]));

      // As if the previous run downloaded it and the process was killed before
      // the user pressed 安装.
      File('${staging.path}/HerdrPocket-0.2.0-arm64-v8a.apk')
          .writeAsBytesSync(github.body);

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();

      expect(container.read(updateControllerProvider).phase, isA<UpdateReady>());
      // 46 MB of the user's data, not spent twice.
      expect(github.assetRequests, isEmpty);
    });

    test('a file left over from an earlier run that is WRONG is not adopted', () async {
      github.body = List.filled(64, 5);
      github.checksums = '${'c' * 64}  HerdrPocket-0.2.0-arm64-v8a.apk\n';
      github.releases.add(_releaseJson(assets: [('HerdrPocket-0.2.0-arm64-v8a.apk', 64)]));
      File('${staging.path}/HerdrPocket-0.2.0-arm64-v8a.apk')
          .writeAsBytesSync(List.filled(64, 9));

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();

      // The checksum did not match, so it went and fetched it — and the failure
      // is the checksum, not an install of the wrong file.
      expect(github.assetRequests, isNotEmpty);
      expect(
        (container.read(updateControllerProvider).phase as UpdateFailed).reason,
        UpdateFailure.checksum,
      );
    });

    test('the install permission is re-read when the app comes back', () async {
      github.body = List.filled(8, 5);
      github.releases.add(_releaseJson());
      target.canInstall = false;

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();
      expect(
        (container.read(updateControllerProvider).phase as UpdateReady).canInstall,
        isFalse,
      );

      // The user went to Settings, granted it, and came back. Found on a device:
      // without this the sheet kept offering 「去允许安装」 and the second tap
      // reopened the same screen — a loop with no exit.
      target.canInstall = true;
      await notifier.refreshInstallPermission();
      expect(
        (container.read(updateControllerProvider).phase as UpdateReady).canInstall,
        isTrue,
      );
    });

    test('the install permission is re-read at the moment of installing', () async {
      github.body = List.filled(8, 5);
      github.releases.add(_releaseJson());
      target.canInstall = false;

      final container = await containerFor(prefs: await _prefs());
      final notifier = container.read(updateControllerProvider.notifier);
      await notifier.check();
      await notifier.download();

      expect(
        (container.read(updateControllerProvider).phase as UpdateReady).canInstall,
        isFalse,
      );

      // The user leaves for Settings, flips the switch, comes back. The state
      // still says false — the state is a snapshot — and the ONLY reason the
      // button works is that `install()` asks again.
      target.canInstall = true;
      await notifier.install();
      expect(target.installed, isTrue);
    });
  });
}

/// A proxy source that reports nothing, which is most phones.
class _NoProxy implements SystemProxySource {
  const _NoProxy();

  @override
  Future<SystemProxy?> read() async => null;
}

/// The install half, faked: no Android, no installer, just the contract.
class _FakeTarget implements ApkInstallTarget {
  _FakeTarget(this.directory);

  final Directory directory;
  bool canInstall = true;
  bool installed = false;
  ApkInspection inspection = const ApkInspection(
    packageName: installedApplicationId,
    versionCode: 42,
    signatureMatches: true,
  );

  @override
  Future<Directory?> stagingDirectory() async => directory;

  @override
  Future<bool> canInstallPackages() async => canInstall;

  @override
  Future<ApkInspection> inspect(File apk) async => inspection;

  @override
  Future<void> install(File apk) async => installed = true;

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<void> openUrl(String url) async {}
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return await SharedPreferences.getInstance();
}

ReleaseAsset _asset(String name, {required int size}) => ReleaseAsset(
      name: name,
      size: size,
      url: '${_FakeGithub.lastBase}/asset/$name',
    );

/// One release document, with the assets this repository actually publishes.
Map<String, Object?> _releaseJson({
  String tag = 'v0.2.0',
  List<(String, int)>? assets,
}) {
  final published = assets ??
      const [
        ('HerdrPocket-0.2.0-arm64-v8a.apk', 8),
        ('HerdrPocket-0.2.0-armeabi-v7a.apk', 8),
        ('HerdrPocket-0.2.0-universal.apk', 8),
      ];
  return {
    'tag_name': tag,
    'name': tag,
    'body': 'What changed',
    'draft': false,
    'prerelease': false,
    'published_at': '2026-09-16T05:49:17Z',
    'html_url': 'https://github.com/weekitmo/herdr-pocket/releases/tag/$tag',
    'assets': [
      // Every release the workflow publishes carries this, in the
      // `<sha256>  <filename>` shape `sha256sum -c` reads.
      {
        'name': 'checksums.txt',
        'size': 390,
        'browser_download_url': '${_FakeGithub.lastBase}/asset/checksums.txt',
      },
      for (final (name, size) in published)
        {
          'name': name,
          'size': size,
          'browser_download_url': '${_FakeGithub.lastBase}/asset/$name',
        },
    ],
  };
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

/// A local stand-in for the two GitHub hosts the updater talks to.
class _FakeGithub {
  _FakeGithub(this._server) {
    _server.listen(_handle);
  }

  /// The port of the most recently started server, for the URLs inside the
  /// release document (which is built before the client asks).
  static String lastBase = '';

  static Future<_FakeGithub> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final github = _FakeGithub(server);
    lastBase = github.base;
    return github;
  }

  final HttpServer _server;

  String get base => 'http://127.0.0.1:${_server.port}';

  final List<Map<String, Object?>> releases = [];

  /// What the releases endpoint answers with, when not JSON.
  String? releasesBody;

  int releasesStatus = 200;

  /// The APK's bytes.
  List<int> body = const [];

  /// Serve fewer bytes than the release claims, to imitate a cut connection.
  int? truncateTo;

  /// Whether the asset endpoint honours `Range`.
  bool supportsRange = true;

  /// Gap between chunks, for the cancellation case.
  Duration chunkDelay = Duration.zero;

  /// How many bytes go out per flush. One by one is more faithful to a slow
  /// connection, but it also means the client's stream may not have delivered
  /// anything by the time a test cancels it.
  int? chunkSize;

  /// The `checksums.txt` body, or null when the release has none.
  String? checksums;

  /// Every Range header the asset endpoint was asked with.
  final List<String?> ranges = [];

  /// Every asset path that was asked for, for the "no request happened" case.
  final List<String> assetRequests = [];

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path.endsWith('/releases')) {
      request.response.statusCode = releasesStatus;
      // The content type is load-bearing: dio only decodes JSON when the
      // server says it is JSON, and a `text/plain` body of JSON is returned as
      // a string — which the client is right to call a bad payload.
      request.response.headers.contentType = releasesBody == null
          ? ContentType.json
          : ContentType.html;
      request.response.write(
        releasesBody ?? jsonEncode(releases),
      );
      await request.response.close();
      return;
    }
    if (path.endsWith('checksums.txt')) {
      if (checksums == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.write(checksums);
      }
      await request.response.close();
      return;
    }
    if (path.contains('/asset/')) {
      await _serveAsset(request);
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _serveAsset(HttpRequest request) async {
    final range = request.headers.value('range');
    ranges.add(range);
    assetRequests.add(request.uri.path);

    var start = 0;
    if (range != null && supportsRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes $start-${body.length - 1}/${body.length}',
      );
    }

    final end = truncateTo ?? body.length;
    request.response.headers.contentLength = end - start;
    final step = chunkSize ?? (end - start).clamp(1, 1 << 30);
    for (var i = start; i < end; i += step) {
      request.response.add(body.sublist(i, (i + step).clamp(i, end)));
      if (chunkDelay > Duration.zero) {
        await request.response.flush();
        await Future<void>.delayed(chunkDelay);
      }
    }
    await request.response.close();
  }
}
