import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/root_shell.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/update/apk_installer.dart';
import 'package:herdr_pocket/data/update/release_client.dart';
import 'package:herdr_pocket/data/update/update_controller.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/update/app_version.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';
import 'package:herdr_pocket/domain/update/system_proxy.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the automatic check does at a cold start.
///
/// WHY THIS IS ITS OWN FILE. The check and the panel are both tested elsewhere;
/// what this pins is the WIRING between them, and it was wrong in a way that no
/// other test could see: the check ran, found an update, and announced it with
/// one line that expired — which on a phone is easy to miss entirely. The user
/// reported exactly that shape: 「冷启动时不是要先查看有没有新版本吗，弹窗」.
void main() {
  testWidgets('a cold start with an update available OPENS the panel',
      (tester) async {
    await _pump(tester, autoCheck: true);
    await tester.pumpAndSettle();

    expect(
      find.text('Software update'),
      findsOneWidget,
      reason: 'the launch check found 0.2.0 and said so with the panel',
    );
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('the launch panel knows which version it is about', (tester) async {
    await _pump(tester, autoCheck: true);
    await tester.pumpAndSettle();

    expect(find.textContaining('0.2.0'), findsWidgets);
  });

  testWidgets('up to date is silent', (tester) async {
    await _pump(tester, autoCheck: true, installed: '0.2.0');
    await tester.pumpAndSettle();

    expect(
      find.text('Software update'),
      findsNothing,
      reason: 'nothing to announce, and a panel saying so is a chore',
    );
  });

  testWidgets('the switch being off means no check and no panel', (tester) async {
    await _pump(tester, autoCheck: false);
    await tester.pumpAndSettle();

    expect(find.text('Software update'), findsNothing);
  });
}

/// Pumps the real shell: board, dock and the launch hook, nothing else.
Future<void> _pump(
  WidgetTester tester, {
  required bool autoCheck,
  String installed = '0.1.0',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    // `shared_preferences` prefixes every key with `flutter.`.
    'flutter.settings.autoUpdateCheck': autoCheck,
  });
  final prefs = await SharedPreferences.getInstance();
  final releases = _FakeReleases();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        boardProvider.overrideWith(_EmptyBoard.new),
        processKeeperProvider.overrideWithValue(_NoopKeeper()),
        appVersionProvider.overrideWithValue(AppVersion.tryParse(installed)),
        deviceAbiProvider.overrideWithValue('arm64-v8a'),
        releaseClientProvider.overrideWith((ref) => releases),
        // Without an installer the offer shows the release page instead of a
        // download button, which is right on a desktop and wrong for this test.
        apkInstallTargetProvider.overrideWithValue(_FakeTarget()),
      ],
      child: const HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: Locale('en'),
          home: RootShell(),
        ),
      ),
    ),
  );
}

/// The release list, with one newer version in it.
class _FakeReleases extends ReleaseClient {
  _FakeReleases()
      : super(
          http: UpdateHttp(
            resolver: ProxyResolver(source: const _NoProxy()),
          ),
          userAgent: 'test',
        );

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
  Future<List<ReleaseInfo>> releases() async => [_release];
}

/// A board with nothing in it, so nothing subscribes to anything.
class _EmptyBoard extends BoardNotifier {
  @override
  Future<AgentList> build() async => AgentList.empty();
}

/// The install half, faked: this test never downloads anything.
class _FakeTarget implements ApkInstallTarget {
  @override
  Future<Directory?> stagingDirectory() async => null;

  @override
  Future<bool> canInstallPackages() async => true;

  @override
  Future<ApkInspection> inspect(File apk) async => const ApkInspection(
        packageName: installedApplicationId,
        versionCode: 1,
        signatureMatches: true,
      );

  @override
  Future<void> install(File apk) async {}

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<void> openUrl(String url) async {}
}

/// The keep-alive service, absent: this test is not about the notification.
class _NoopKeeper implements ProcessKeeper {
  /// These fakes stand in for the Android one, which is the only platform
  /// where the feature exists -- and the settings row is drawn from this.
  @override
  bool get isSupported => true;

  @override
  Future<bool> start({required String title, required String text}) async =>
      false;

  @override
  Future<void> stop() async {}
}

/// A proxy source that reports nothing, which is most phones.
class _NoProxy implements SystemProxySource {
  const _NoProxy();

  @override
  Future<SystemProxy?> read() async => null;
}
