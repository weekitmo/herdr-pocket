import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/local/app_lock.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/settings/settings_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Security group: two switches, and the order they have to be turned on in.
///
/// THE ONE RULE THIS FILE EXISTS FOR: a fingerprint switch that can be turned on
/// before there is a PIN is a switch that would lock the user out of their own
/// app — the biometric is an alternative entry, not a replacement for the only
/// one. So it is drawn DISABLED, with the reason in its note, and the row that
/// changes the PIN only exists once there is one.
void main() {
  final packageInfo = PackageInfo(
    appName: 'Herdr Pocket',
    packageName: 'dev.herdr.herdr_pocket',
    version: '1.0.0',
    buildNumber: '1',
  );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    FlutterSecureStorage.setMockInitialValues({});
  });

  void seedPin({bool biometrics = false}) {
    const salt = 'salt';
    FlutterSecureStorage.setMockInitialValues({
      'applock.record': jsonEncode(
        AppLockRecord(
          salt: salt,
          pinHash: hashPin('4207', salt),
          biometricsEnabled: biometrics,
        ).toJson(),
      ),
    });
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool deviceHasBiometrics = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectionProvider.overrideWith(_OfflineConnection.new),
          currentHostProvider.overrideWithValue(null),
          packageInfoProvider.overrideWith((ref) async => packageInfo),
          biometricGateProvider.overrideWithValue(
            _FakeBiometrics(available: deviceHasBiometrics),
          ),
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
            home: SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The switch ON THE ROW whose label is [label].
  CupertinoSwitch switchIn(WidgetTester tester, String label) =>
      tester.widget<CupertinoSwitch>(
        find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(SettingsSwitchRow),
          ),
          matching: find.byType(CupertinoSwitch),
        ),
      );

  Future<void> scrollTo(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(find.text(label), 200);
    await tester.pumpAndSettle();
  }

  testWidgets('the group is there, and only the lock itself is on offer',
      (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, 'App lock');

    expect(switchIn(tester, 'App lock').value, isFalse);
    expect(
      find.text('Change PIN'),
      findsNothing,
      reason: 'there is no PIN to change until one is set',
    );
  });

  testWidgets('the fingerprint waits for the PIN, and says why', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, 'Unlock with fingerprint');

    expect(find.text('Set a PIN first.'), findsOneWidget);
    final off = switchIn(tester, 'Unlock with fingerprint');

    // Disabled, not merely off: the tap has to do nothing at all.
    await tester.tap(find.text('Unlock with fingerprint'));
    await tester.pumpAndSettle();
    expect(switchIn(tester, 'Unlock with fingerprint').value, off.value);
  });

  testWidgets('turning the lock on asks for four digits', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, 'App lock');

    await tester.tap(find.text('App lock'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a 4-digit PIN'), findsOneWidget);
  });

  testWidgets('a stored PIN shows the change row, and a working switch',
      (tester) async {
    seedPin();
    await pumpSettings(tester);
    await scrollTo(tester, 'App lock');

    expect(switchIn(tester, 'App lock').value, isTrue);
    expect(find.text('Change PIN'), findsOneWidget);

    await scrollTo(tester, 'Unlock with fingerprint');
    expect(find.text('Set a PIN first.'), findsNothing);

    await tester.tap(find.text('Unlock with fingerprint'));
    await tester.pumpAndSettle();

    expect(
      switchIn(tester, 'Unlock with fingerprint').value,
      isTrue,
      reason: 'with a PIN stored and a sensor present, the switch does its job',
    );
  });

  testWidgets('a phone with no sensor says so instead of lying',
      (tester) async {
    seedPin();
    await pumpSettings(tester, deviceHasBiometrics: false);
    await scrollTo(tester, 'Unlock with fingerprint');

    expect(find.text('This device has no fingerprint enrolled.'), findsOneWidget);
    await tester.tap(find.text('Unlock with fingerprint'));
    await tester.pumpAndSettle();
    expect(switchIn(tester, 'Unlock with fingerprint').value, isFalse);
  });
}

class _FakeBiometrics implements BiometricGate {
  _FakeBiometrics({required this.available});

  final bool available;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async => false;
}

class _OfflineConnection extends ConnectionNotifier {
  @override
  Future<ConnectionStatus> build() async => const Disconnected();
}
