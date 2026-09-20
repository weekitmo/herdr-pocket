import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/local/app_lock.dart';
import 'package:local_auth/local_auth.dart';

/// How long the app may stay in the background without asking again.
///
/// FIVE MINUTES, and the number is the user's: switching to another app to copy
/// a command, or to answer a message, should not mean unlocking on the way back,
/// while a phone left on a table for a quarter of an hour should. Below this the
/// app is the same session; above it, it is a new one.
const Duration lockGracePeriod = Duration(minutes: 5);

/// The device's own biometric prompt, as one small seam.
///
/// A seam rather than a direct `LocalAuthentication()` call for the same reason
/// `RemoteCommandRunner` is one: the prompt cannot exist in a test (there is no
/// platform channel, and no finger), and the rules around it — when it is
/// offered, what happens when it fails, what happens when the sensor is not
/// there — are the parts worth pinning down. The implementation below is the
/// only code in this feature that a CI machine cannot run.
abstract interface class BiometricGate {
  /// Whether this device can even ask: hardware present, and enrolled.
  Future<bool> isAvailable();

  /// Shows the system prompt. True means the user proved who they are.
  ///
  /// False covers every other outcome — cancelled, locked out, no hardware —
  /// because the app does the SAME thing in all of them: stays on the PIN pad.
  Future<bool> authenticate(String reason);
}

/// The real one, over `local_auth`.
class SystemBiometrics implements BiometricGate {
  SystemBiometrics([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } on Object {
      // A device with no biometric hardware at all, and an OEM build whose
      // plugin channel answers with an error both land here — and both mean the
      // same thing to the user: the switch stays off and the PIN opens the app.
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Biometrics ONLY: no device-credential fallback. The app has its own
        // PIN, and offering the phone's PIN/pattern as well would put a second
        // way into the app that the user never chose here.
        biometricOnly: true,
        // An OEM that pauses this activity behind its own prompt is the normal
        // case, not an interruption: without this the attempt is abandoned the
        // moment the system draws the dialog it is waiting for.
        persistAcrossBackgrounding: true,
      );
    } on Object {
      return false;
    }
  }
}

final appLockStoreProvider = Provider<AppLockStore>((ref) => const AppLockStore());

final biometricGateProvider = Provider<BiometricGate>(
  (ref) => SystemBiometrics(),
);

/// Whether the device can ask for a fingerprint at all.
///
/// Read by the settings row, which greys itself out rather than offering a
/// switch that can never do anything.
final biometricAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(biometricGateProvider).isAvailable(),
);

/// The lock, as the app needs to think about it.
class AppLockState {
  const AppLockState({
    this.pinSet = false,
    this.biometricsEnabled = false,
    this.locked = false,
  });

  /// Whether a PIN exists. False means the feature is off, and the app opens.
  final bool pinSet;

  final bool biometricsEnabled;

  /// Whether the screen is up right now.
  ///
  /// Always false when [pinSet] is false: there is nothing to ask for.
  final bool locked;

  AppLockState copyWith({bool? pinSet, bool? biometricsEnabled, bool? locked}) =>
      AppLockState(
        pinSet: pinSet ?? this.pinSet,
        biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
        locked: locked ?? this.locked,
      );
}

/// The lock's state machine: what is configured, and whether it is up.
///
/// ## Cold start always locks
///
/// [build] reads the keystore and, when a PIN exists, comes back LOCKED. There
/// is deliberately no "remember that I unlocked" anywhere on disk: an app that
/// reopens without asking after a reboot is not a lock, and the one thing a
/// phone-in-the-wrong-hands threat model needs is that killing and relaunching
/// the app does not help.
///
/// ## Backgrounding is the gate's business
///
/// [resumeAfter] takes the elapsed time rather than reading a clock, so the
/// grace period is a pure decision and testable without waiting five minutes.
/// The gate is what knows when the app went away.
class AppLockNotifier extends AsyncNotifier<AppLockState> {
  AppLockRecord? _record;

  @override
  Future<AppLockState> build() async {
    final record = await ref.read(appLockStoreProvider).read();
    _record = record;
    if (record == null) return const AppLockState();
    return AppLockState(
      pinSet: true,
      biometricsEnabled: record.biometricsEnabled,
      locked: true,
    );
  }

  /// Whether [pin] is the stored one.
  bool verifyPin(String pin) {
    final record = _record;
    if (record == null) return false;
    return hashPin(pin, record.salt) == record.pinHash;
  }

  /// Opens the app, if [pin] is right. Returns whether it was.
  Future<bool> unlockWithPin(String pin) async {
    if (!verifyPin(pin)) return false;
    _publish(locked: false);
    return true;
  }

  /// Opens the app with the device's own prompt. Returns whether it worked.
  ///
  /// The finger is checked FIRST and the state is only touched when it agreed:
  /// a prompt the user cancelled must leave the PIN pad exactly as it was.
  Future<bool> unlockWithBiometrics(String reason) async {
    final state = this.state.value;
    if (state == null || !state.pinSet || !state.biometricsEnabled) return false;
    final ok = await ref.read(biometricGateProvider).authenticate(reason);
    if (ok) _publish(locked: false);
    return ok;
  }

  /// Stores [pin] and turns the lock on.
  Future<void> setPin(String pin) async {    final salt = newSalt();
    final record = AppLockRecord(
      salt: salt,
      pinHash: hashPin(pin, salt),
      biometricsEnabled: _record?.biometricsEnabled ?? false,
    );
    await ref.read(appLockStoreProvider).write(record);
    _record = record;
    // UNLOCKED, because whoever just set the PIN is holding the phone.
    state = AsyncValue.data(
      AppLockState(
        pinSet: true,
        biometricsEnabled: record.biometricsEnabled,
      ),
    );
  }

  /// Removes the lock entirely.
  Future<void> removePin() async {
    await ref.read(appLockStoreProvider).clear();
    _record = null;
    state = const AsyncValue.data(AppLockState());
  }

  /// Turns the device's prompt on or off. Meaningless without a PIN.
  Future<void> setBiometricsEnabled({required bool enabled}) async {
    final record = _record;
    if (record == null) return;
    final next = AppLockRecord(
      salt: record.salt,
      pinHash: record.pinHash,
      biometricsEnabled: enabled,
    );
    await ref.read(appLockStoreProvider).write(next);
    _record = next;
    _publish(biometricsEnabled: enabled);
  }

  /// Puts the lock back up. Used by the gate when the app has been away too
  /// long.
  void relock() {
    if (_record == null) return;
    _publish(locked: true);
  }

  /// Called when the app comes back, with how long it was away.
  ///
  /// Under [lockGracePeriod] nothing happens at all: this is the same session
  /// the user left.
  void resumeAfter(Duration away) {
    if (away < lockGracePeriod) return;
    relock();
  }

  void _publish({
    bool? biometricsEnabled,
    bool? locked,
  }) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(
      current.copyWith(biometricsEnabled: biometricsEnabled, locked: locked),
    );
  }
}

final appLockProvider =
    AsyncNotifierProvider<AppLockNotifier, AppLockState>(AppLockNotifier.new);
