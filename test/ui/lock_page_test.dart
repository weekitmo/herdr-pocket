import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/local/app_lock.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/lock/lock_gate.dart';
import 'package:herdr_pocket/ui/pages/lock/lock_page.dart';
import 'package:herdr_pocket/ui/pages/lock/pin_pad.dart';

/// The lock screen and the gate that puts it up.
///
/// The rules being pinned are the ones a user would notice if they broke: the
/// app does not open until the PIN is right, four digits are enough, the
/// fingerprint prompt comes to the user rather than the other way round, and
/// turning the feature off is not something a locked app can do.
void main() {
  /// A stored lock with PIN `4207`, as a previous launch would have left it.
  final storedRecord = AppLockRecord(
    salt: 'salt',
    pinHash: hashPin('4207', 'salt'),
    biometricsEnabled: false,
  );

  void seed({bool biometrics = false}) {
    FlutterSecureStorage.setMockInitialValues({
      'applock.record': jsonEncode(
        AppLockRecord(
          salt: storedRecord.salt,
          pinHash: storedRecord.pinHash,
          biometricsEnabled: biometrics,
        ).toJson(),
      ),
    });
  }

  Future<void> pumpGate(WidgetTester tester, {BiometricGate? biometrics}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (biometrics != null)
            biometricGateProvider.overrideWithValue(biometrics),
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
            // THE SHAPE THE APP USES: content, then the lock above it. A
            // lock that is a sibling in a Stack cannot be covered by a route
            // the app pushes, which is the property this file exists for.
            home: Stack(children: [Text('the app'), LockGate()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.byKey(pinDigitKey(int.parse(digit))));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('with no lock set', () {
    testWidgets('the app is simply there', (tester) async {
      await pumpGate(tester);

      expect(find.text('the app'), findsOneWidget);
      expect(find.byType(LockPage), findsNothing);
    });
  });

  group('with a lock set', () {
    testWidgets('the app is not there until the PIN is', (tester) async {
      seed();
      await pumpGate(tester);

      expect(find.byType(LockPage), findsOneWidget);
      expect(
        find.byType(LockGate),
        findsOneWidget,
        reason: 'the gate stays mounted even while open, because it is what '
            'measures how long the app was in the background',
      );
    });

    testWidgets('the right PIN opens it', (tester) async {
      seed();
      await pumpGate(tester);

      await type(tester, '4207');

      expect(find.byType(LockPage), findsNothing);
    });

    testWidgets('a wrong PIN says so and keeps the lock', (tester) async {
      seed();
      await pumpGate(tester);

      await type(tester, '0000');

      expect(find.byKey(pinErrorKey), findsOneWidget);
      expect(find.text('Wrong PIN'), findsOneWidget);
      expect(find.byType(LockPage), findsOneWidget);

      // And the next attempt starts from nothing — a pad that kept the failed
      // digits would make the user delete them one at a time.
      await type(tester, '4207');
      expect(find.byType(LockPage), findsNothing);
    });

    testWidgets('there is no fingerprint button unless it was turned on',
        (tester) async {
      seed();
      await pumpGate(tester, biometrics: _FakeBiometrics(approves: true));

      expect(find.byKey(lockFingerprintKey), findsNothing);
    });
  });

  group('with the fingerprint turned on', () {
    testWidgets('the prompt comes to the user, and opens the app', (tester) async {
      seed(biometrics: true);
      final gate = _FakeBiometrics(approves: true);
      await pumpGate(tester, biometrics: gate);

      expect(gate.prompts, 1);
      expect(find.byType(LockPage), findsNothing);
    });

    testWidgets('a cancelled prompt leaves the pad, silently', (tester) async {
      seed(biometrics: true);
      final gate = _FakeBiometrics(approves: false);
      await pumpGate(tester, biometrics: gate);

      expect(gate.prompts, 1);
      expect(find.byType(LockPage), findsOneWidget);
      expect(
        find.byKey(pinErrorKey),
        findsNothing,
        reason: 'cancelling the system dialog is not a wrong PIN',
      );
      expect(find.byKey(lockFingerprintKey), findsOneWidget);
    });
  });
}

class _FakeBiometrics implements BiometricGate {
  _FakeBiometrics({required this.approves});

  final bool approves;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return approves;
  }
}
