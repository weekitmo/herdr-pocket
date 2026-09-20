import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/local/app_lock.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';

/// The app lock's rules, without a keypad in the way.
///
/// THE THREE THINGS THIS FILE EXISTS FOR, in the order they matter:
///
///   1. a cold start LOCKS — the record is on disk and the state is not;
///   2. five minutes in the background does not, four minutes does not, and six
///      does — measured by passing the elapsed time in rather than by waiting;
///   3. nothing about the lock is reachable without the PIN, including turning
///      the lock off.
void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  /// A container standing in for one launch of the app.
  ProviderContainer launch({BiometricGate? biometrics}) {
    final container = ProviderContainer(
      overrides: [
        if (biometrics != null)
          biometricGateProvider.overrideWithValue(biometrics),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<AppLockState> stateOf(ProviderContainer container) =>
      container.read(appLockProvider.future);

  group('the PIN itself', () {
    test('is four digits and nothing else', () {
      expect(isWellFormedPin('0000'), isTrue);
      expect(isWellFormedPin('1234'), isTrue);
      expect(isWellFormedPin('123'), isFalse);
      expect(isWellFormedPin('12345'), isFalse);
      expect(isWellFormedPin('12a4'), isFalse);
      expect(isWellFormedPin(''), isFalse);
    });

    test('is stored salted, and the salt makes the digest different', () {
      final a = hashPin('1234', 'salt-a');
      final b = hashPin('1234', 'salt-b');

      expect(a, isNot(b));
      expect(hashPin('1234', 'salt-a'), a, reason: 'the same input is stable');
      expect(a, isNot(contains('1234')));
    });

    test('a corrupt record reads as no lock rather than as a broken app', () {
      expect(AppLockRecord.fromJson(const {}), isNull);
      expect(AppLockRecord.fromJson(const {'salt': 'x'}), isNull);
      expect(
        AppLockRecord.fromJson(const {
          'salt': 's',
          'pinHash': 'h',
        })?.biometricsEnabled,
        isFalse,
        reason: 'an older record without the flag means off, which is the '
            'default the user would have chosen',
      );
    });
  });

  group('a fresh install', () {
    test('has no lock at all', () async {
      final container = launch();
      final state = await stateOf(container);

      expect(state.pinSet, isFalse);
      expect(state.locked, isFalse);
    });

    test('turns the lock on and is open, because the user just set it', () async {
      final container = launch();
      await container.read(appLockProvider.future);

      await container.read(appLockProvider.notifier).setPin('4207');
      final state = await stateOf(container);

      expect(state.pinSet, isTrue);
      expect(state.locked, isFalse);
    });
  });

  group('a cold start', () {
    test('locks, every time', () async {
      final first = launch();
      await first.read(appLockProvider.future);
      await first.read(appLockProvider.notifier).setPin('4207');

      // A SECOND container over the same store IS the next launch: `main()`
      // awaits the same SharedPreferences, and nothing in between is allowed
      // to remember that this phone was unlocked a moment ago.
      final second = launch();
      final state = await stateOf(second);

      expect(state.pinSet, isTrue);
      expect(state.locked, isTrue);
    });

    test('does not open for the wrong PIN, and does for the right one',
        () async {
      final first = launch();
      await first.read(appLockProvider.future);
      await first.read(appLockProvider.notifier).setPin('4207');

      final second = launch();
      await stateOf(second);
      final notifier = second.read(appLockProvider.notifier);

      expect(await notifier.unlockWithPin('0000'), isFalse);
      expect((await stateOf(second)).locked, isTrue);
      expect(await notifier.unlockWithPin('4207'), isTrue);
      expect((await stateOf(second)).locked, isFalse);
    });
  });

  group('the background grace period', () {
    test('is minutes, not seconds — under it nothing happens', () async {
      final container = launch();
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setPin('4207');
      await container.read(appLockProvider.notifier).unlockWithPin('4207');

      container
          .read(appLockProvider.notifier)
          .resumeAfter(lockGracePeriod - const Duration(seconds: 1));

      expect((await stateOf(container)).locked, isFalse);
    });

    test('and past it the lock comes back', () async {
      final container = launch();
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setPin('4207');
      await container.read(appLockProvider.notifier).unlockWithPin('4207');

      container
          .read(appLockProvider.notifier)
          .resumeAfter(lockGracePeriod + const Duration(seconds: 1));

      expect((await stateOf(container)).locked, isTrue);
    });

    test('is not a way into an app that was never unlocked', () async {
      // The gate calls `resumeAfter` on every foreground, including the one
      // that follows a cold start — and a short trip away must not clear the
      // lock that was never answered.
      final first = launch();
      await first.read(appLockProvider.future);
      await first.read(appLockProvider.notifier).setPin('4207');

      final second = launch();
      await stateOf(second);
      second.read(appLockProvider.notifier).resumeAfter(const Duration(seconds: 3));

      expect((await stateOf(second)).locked, isTrue);
    });
  });

  group('the fingerprint', () {
    test('opens the app when the device says yes', () async {
      final gate = _FakeBiometrics(available: true, approves: true);
      final container = launch(biometrics: gate);
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setPin('4207');
      await container.read(appLockProvider.notifier).setBiometricsEnabled(enabled: true);

      final second = launch(biometrics: gate);
      await stateOf(second);

      expect(
        await second.read(appLockProvider.notifier).unlockWithBiometrics('go'),
        isTrue,
      );
      expect((await stateOf(second)).locked, isFalse);
    });

    test('does not open it when the user cancels', () async {
      final gate = _FakeBiometrics(available: true, approves: false);
      final container = launch(biometrics: gate);
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setPin('4207');
      await container.read(appLockProvider.notifier).setBiometricsEnabled(enabled: true);

      final second = launch(biometrics: gate);
      await stateOf(second);

      expect(
        await second.read(appLockProvider.notifier).unlockWithBiometrics('go'),
        isFalse,
      );
      expect((await stateOf(second)).locked, isTrue);
    });

    test('is never asked for when the user has not turned it on', () async {
      final gate = _FakeBiometrics(available: true, approves: true);
      final container = launch(biometrics: gate);
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setPin('4207');

      final second = launch(biometrics: gate);
      await stateOf(second);

      expect(
        await second.read(appLockProvider.notifier).unlockWithBiometrics('go'),
        isFalse,
      );
      expect(
        gate.prompts,
        0,
        reason: 'a feature that is off must not put a dialog on the screen',
      );
    });
  });

  group('turning it off', () {
    test('removes the record, so the next launch opens', () async {
      final first = launch();
      await first.read(appLockProvider.future);
      await first.read(appLockProvider.notifier).setPin('4207');

      await first.read(appLockProvider.notifier).removePin();

      final second = launch();
      final state = await stateOf(second);
      expect(state.pinSet, isFalse);
      expect(state.locked, isFalse);
    });

    test('can only happen with the current PIN', () async {
      final first = launch();
      await first.read(appLockProvider.future);
      await first.read(appLockProvider.notifier).setPin('4207');
      final notifier = first.read(appLockProvider.notifier);

      expect(notifier.verifyPin('0000'), isFalse);
      expect(notifier.verifyPin('4207'), isTrue);
    });
  });
}

/// A device that answers as the test tells it to.
class _FakeBiometrics implements BiometricGate {
  _FakeBiometrics({required this.available, required this.approves});

  final bool available;
  final bool approves;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return approves;
  }
}
