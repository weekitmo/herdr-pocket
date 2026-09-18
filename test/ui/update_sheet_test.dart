import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/update_sheet.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The update panel as a screen: when it asks, and what may close it.
///
/// WHY THIS IS A WIDGET TEST RATHER THAN ANOTHER CONTROLLER TEST. Two of the
/// bugs reported from the phone live in this widget and nowhere else: the panel
/// opened on a remembered answer instead of asking again, and a download could
/// be interrupted by a back gesture or a tap on the dim. The controller is
/// right in both cases — it is the panel's own wiring that was wrong.
void main() {
  late SharedPreferences prefs;
  late _FakeReleases releases;
  late _SlowDownloader downloader;
  late _FakeTarget target;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    releases = _FakeReleases();
    downloader = _SlowDownloader();
    target = _FakeTarget(Directory.systemTemp.createTempSync('herdr-update-ui-'));
    addTearDown(() {
      if (target.directory.existsSync()) {
        target.directory.deleteSync(recursive: true);
      }
    });
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appVersionProvider.overrideWithValue(AppVersion.tryParse('0.1.0')),
          deviceAbiProvider.overrideWithValue('arm64-v8a'),
          releaseClientProvider.overrideWith((ref) => releases),
          assetDownloaderProvider.overrideWith((ref) => downloader),
          apkInstallTargetProvider.overrideWithValue(target),
        ],
        child: const HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: _Host(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  ProviderContainer containerOf(WidgetTester tester) => ProviderScope.containerOf(
        tester.element(find.byType(_Host)),
        listen: false,
      );

  testWidgets('it asks GitHub again EVERY time it is opened', (tester) async {
    // THE BUG THIS PINS, reported as 「检查更新失效」. The launch check (on by
    // default since the automatic check was flipped) leaves the controller on
    // an answer, and the panel only started a check from IDLE — a state nothing
    // ever returned to. So the row called 检查更新 showed the previous answer
    // forever, and the only way to actually ask again was to restart the app.
    await pump(tester);

    await openSheet(tester);
    expect(releases.calls, 1);
    expect(find.text('Download'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await openSheet(tester);
    expect(
      releases.calls,
      2,
      reason: 'a second tap on 检查更新 has to reach GitHub, not the cache',
    );
  });

  testWidgets('a download cannot be dismissed by back or by the barrier',
      (tester) async {
    await pump(tester);
    await openSheet(tester);

    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);

    // The system back gesture, which is how a sheet is normally closed.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.text('Cancel'),
      findsOneWidget,
      reason: 'a back gesture must not leave a transfer running unwatched',
    );

    // And the dim above the panel.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(
      find.text('Cancel'),
      findsOneWidget,
      reason: 'a stray tap outside must not dismiss it either',
    );

    // The button is the way out: it ends the transfer and closes the panel.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel'), findsNothing);
    // The controller learns the transfer was cancelled from the future
    // unwinding, which is a microtask behind the tap — the file cleanup is
    // awaited there, deliberately, so the state is asserted after letting it
    // run rather than at the instant the button was pressed.
    await tester.pump();
    await tester.pump();
    expect(
      containerOf(tester).read(updateControllerProvider).phase,
      isA<UpdateAvailable>(),
      reason: 'cancelling returns to the offer it came from',
    );
  });

  testWidgets('outside a download the usual gestures still close it',
      (tester) async {
    // The gate is a download-only rule, not a new personality for every sheet.
    await pump(tester);
    await openSheet(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Download'), findsNothing);
  });
}

/// A page with one button, which is all the panel needs to exist.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showUpdateSheet(context),
            child: const Text('open'),
          ),
        ),
      );
}

/// The release list, counted.
class _FakeReleases extends ReleaseClient {
  _FakeReleases()
      : super(
          http: UpdateHttp(
            resolver: ProxyResolver(source: const _NoProxy()),
          ),
          userAgent: 'test',
        );

  int calls = 0;

  static final ReleaseInfo _release = ReleaseInfo(
    tag: 'v0.2.0',
    version: AppVersion.tryParse('v0.2.0')!,
    assets: const [
      ReleaseAsset(
        name: 'HerdrPocket-0.2.0-arm64-v8a.apk',
        size: 8,
        url: 'https://example.test/apk',
      ),
    ],
    htmlUrl: 'https://github.com/weekitmo/herdr-pocket/releases/tag/v0.2.0',
  );

  @override
  Future<List<ReleaseInfo>> releases() async {
    calls++;
    return [_release];
  }

  @override
  Future<Map<String, String>> checksums(ReleaseInfo release) async => const {};
}

/// A transfer that only ever ends by being cancelled.
///
/// No `Future.delayed` anywhere: a pending timer at the end of a widget test is
/// a failure, and `CancelToken.whenCancel` is exactly the event this fake is
/// waiting for.
class _SlowDownloader extends AssetDownloader {
  _SlowDownloader()
      : super(
          http: UpdateHttp(
            resolver: ProxyResolver(source: const _NoProxy()),
          ),
          userAgent: 'test',
        );

  @override
  Future<DownloadedFile> download({
    required ReleaseAsset asset,
    required Directory staging,
    required CancelToken cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    await cancelToken.whenCancel;
    throw const UpdateException(UpdateFailure.cancelled);
  }

  /// Skipped, and not to save work: `sweep` walks a real directory stream, and a
  /// widget test's fake clock never delivers that I/O — which would make the
  /// cancel below look like it hung.
  @override
  Future<void> sweep(Directory staging, {String? keep}) async {}
}

/// The install half, faked: a temp directory and the two answers.
class _FakeTarget implements ApkInstallTarget {
  _FakeTarget(this.directory);

  final Directory directory;

  @override
  Future<Directory?> stagingDirectory() async => directory;

  @override
  Future<bool> canInstallPackages() async => true;

  @override
  Future<ApkInspection> inspect(File apk) async => const ApkInspection(
        packageName: installedApplicationId,
        versionCode: 42,
        signatureMatches: true,
      );

  @override
  Future<void> install(File apk) async {}

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<void> openUrl(String url) async {}
}

/// A proxy source that reports nothing, which is most phones.
class _NoProxy implements SystemProxySource {
  const _NoProxy();

  @override
  Future<SystemProxy?> read() async => null;
}
