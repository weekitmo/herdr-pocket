import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/lock/pin_pad.dart';

/// The way into a locked app.
///
/// WHAT IT IS FOR, in the user's words: 「在冷启动时会要求解锁进入界面」 — the
/// app asks once at launch, and again if it has been in the background for more
/// than [lockGracePeriod]. It exists because this app holds an SSH key that
/// opens the user's machine, and a phone handed to somebody for a photo should
/// not be a terminal.
///
/// WHAT IT IS NOT: encryption. The PIN opens a screen; the keystore is what
/// protects the key, and it does so whether or not this screen is up. Saying
/// that plainly here because a lock screen invites the assumption that it is
/// protecting data, and a user who believes a 4-digit PIN encrypts their disk
/// will make worse decisions elsewhere.
class LockPage extends ConsumerStatefulWidget {
  const LockPage({super.key});

  @override
  ConsumerState<LockPage> createState() => _LockPageState();
}

class _LockPageState extends ConsumerState<LockPage> {
  @override
  void initState() {
    super.initState();
    // THE PROMPT COMES TO THE USER, when they have asked for it. A fingerprint
    // button that has to be found and pressed is a worse version of the system
    // prompt the user already chose; and if it fails, the pad is right there
    // underneath — silent, because a cancelled prompt is not an error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_promptBiometrics());
    });
  }

  Future<void> _promptBiometrics() async {
    final state = ref.read(appLockProvider).value;
    if (state == null || !state.biometricsEnabled) return;
    await ref
        .read(appLockProvider.notifier)
        .unlockWithBiometrics(AppLocalizations.of(context).lockBiometricReason);
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(appLockProvider).value ?? const AppLockState();

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.xl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.appTitle,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: TextSize.largeTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Space.sm),
                Text(
                  l10n.lockTitle,
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: TextSize.strong,
                  ),
                ),
                const SizedBox(height: Space.xl),
                PinEntry(
                  onSubmit: (pin) async {
                    final ok = await ref
                        .read(appLockProvider.notifier)
                        .unlockWithPin(pin);
                    return ok ? null : l10n.lockWrongPin;
                  },
                  footer: state.biometricsEnabled
                      ? CupertinoButton(
                          key: lockFingerprintKey,
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          onPressed: () => unawaited(_promptBiometrics()),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.person_crop_circle_badge_checkmark,
                                size: 18,
                                color: colors.accent,
                              ),
                              const SizedBox(width: Space.sm),
                              Text(
                                l10n.lockUseBiometrics,
                                style: TextStyle(
                                  color: colors.accent,
                                  fontSize: TextSize.strong,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The key that asks for the device's own prompt by hand.
const Key lockFingerprintKey = ValueKey('lock.fingerprint');
