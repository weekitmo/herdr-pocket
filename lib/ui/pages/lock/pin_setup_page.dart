import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/lock/pin_pad.dart';

/// What a visit to this screen is supposed to end with.
enum PinSetupMode {
  /// Choose a PIN where there was none.
  create,

  /// Prove the current one, then choose a new one.
  change,

  /// Prove the current one, then forget it.
  remove,
}

/// Setting, changing and turning off the app lock.
///
/// ONE SCREEN FOR THREE JOBS, because they are the same two questions in
/// different orders: "prove you are the owner" and "choose four digits". The
/// differences are which questions are asked, what the titles say, and what
/// happens at the end — all of which are a few lines here, against three copies
/// of a keypad and its error handling.
///
/// THE CURRENT PIN IS REQUIRED TO CHANGE OR REMOVE IT. Not because the phone is
/// already unlocked — it is — but because of the case this feature exists for: a
/// phone that was handed over unlocked, or left on a table. A lock that can be
/// switched off from the settings screen by whoever is holding the phone is a
/// lock that stops nobody.
class PinSetupPage extends ConsumerStatefulWidget {
  const PinSetupPage({required this.mode, super.key});

  final PinSetupMode mode;

  @override
  ConsumerState<PinSetupPage> createState() => _PinSetupPageState();
}

/// Which question is on screen.
enum _Step {
  /// Prove the PIN that is already stored.
  current,

  /// Choose the new one.
  enter,

  /// Type it a second time.
  confirm,
}

class _PinSetupPageState extends ConsumerState<PinSetupPage> {
  late _Step _step = widget.mode == PinSetupMode.create
      ? _Step.enter
      : _Step.current;

  /// The first entry, waiting for its confirmation.
  String? _first;

  /// An error to hand to the NEXT pad — see [PinEntry.initialError].
  String? _carriedError;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        leading: HerdrBackButton(label: l10n.actionCancel),
        title: Text(
          switch (_step) {
            _Step.current => l10n.lockCurrentTitle,
            _Step.enter => l10n.lockSetTitle,
            _Step.confirm => l10n.lockConfirmTitle,
          },
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
      ),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.xl,
            ),
            // KEYED BY THE STEP, so each question starts with an empty pad —
            // and so the error a step hands to the next one is shown by a pad
            // that has nothing typed on it yet.
            child: PinEntry(
              key: ValueKey(_step),
              initialError: _carriedError,
              onSubmit: _submit,
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _submit(String pin) async {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(appLockProvider.notifier);

    switch (_step) {
      case _Step.current:
        if (!notifier.verifyPin(pin)) return l10n.lockWrongPin;
        if (widget.mode == PinSetupMode.remove) {
          await notifier.removePin();
          if (mounted) Navigator.of(context).pop();
          return null;
        }
        setState(() {
          _step = _Step.enter;
          _carriedError = null;
        });
        return null;

      case _Step.enter:
        setState(() {
          _first = pin;
          _step = _Step.confirm;
          _carriedError = null;
        });
        return null;

      case _Step.confirm:
        if (pin != _first) {
          // BACK TO THE FIRST QUESTION, with the reason on the new pad: a
          // mismatch is almost always a typo in one of the two, and making the
          // user re-enter the second one against a value they cannot see would
          // be guessing.
          setState(() {
            _first = null;
            _step = _Step.enter;
            _carriedError = l10n.lockMismatch;
          });
          return l10n.lockMismatch;
        }
        await notifier.setPin(pin);
        if (mounted) Navigator.of(context).pop();
        return null;
    }
  }
}
