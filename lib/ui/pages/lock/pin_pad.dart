import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The dots that show how much of a four-digit PIN has been typed.
const Key pinDotsKey = ValueKey('lock.dots');

/// One digit, so a test can press 4-2-0-7 rather than four identical circles.
Key pinDigitKey(int digit) => ValueKey('lock.digit.$digit');

/// The key that takes one digit back.
const Key pinDeleteKey = ValueKey('lock.delete');

/// The line that says a PIN was wrong, when one is.
const Key pinErrorKey = ValueKey('lock.error');

/// Four dots, a keypad, and the moment the fourth digit lands.
///
/// ## Why a pad rather than a text field
///
/// A lock screen is the one place in this app where a keyboard is the wrong
/// instrument: the alphabet is noise, the digits are the four largest targets
/// on the phone, and a field would bring a suggestion bar and an autocorrect
/// with it. It is also the shape every phone user already unlocks with.
///
/// ## The value lives here, the MEANING does not
///
/// The entry owns what has been typed and when it is complete; what the four
/// digits mean is [onSubmit]'s business. It returns an error to show, or null
/// when the answer was accepted — which is what lets the same widget serve the
/// unlock screen (wrong PIN, try again) and the two steps of setting one
/// (the confirmation did not match).
class PinEntry extends StatefulWidget {
  const PinEntry({
    required this.onSubmit,
    this.footer,
    this.initialError,
    super.key,
  });

  /// Called once four digits are in. Null means accepted; anything else is
  /// shown under the dots and the entry clears itself.
  final Future<String?> Function(String pin) onSubmit;

  /// Drawn under the keypad — the fingerprint button, and nothing else so far.
  final Widget? footer;

  /// An error to show before anything has been typed.
  ///
  /// For the sentence a screen has to carry ACROSS a change of question: the
  /// confirmation did not match the first entry, and the pad it is about to
  /// show is a new one. It clears itself the moment a digit is pressed.
  final String? initialError;

  @override
  State<PinEntry> createState() => _PinEntryState();
}

class _PinEntryState extends State<PinEntry> {
  String _value = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
  }

  Future<void> _submit(String pin) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await widget.onSubmit(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      // CLEARED ON REFUSAL, KEPT ON ACCEPTANCE — and the second half matters:
      // the accepted screen is about to be replaced, and clearing the dots
      // first would show the user an empty pad for the frame before it goes.
      if (error != null) _value = '';
    });
    if (error != null) {
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  void _press(int digit) {
    if (_busy || _value.length >= 4) return;
    final next = '$_value$digit';
    setState(() {
      _value = next;
      _error = null;
    });
    unawaited(HapticFeedback.selectionClick());
    // THE FOURTH DIGIT SUBMITS ITSELF. There is no OK button, because there is
    // nothing left to confirm — the length is the answer.
    if (next.length == 4) unawaited(_submit(next));
  }

  void _delete() {
    if (_busy || _value.isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _value = _value.substring(0, _value.length - 1);
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dots(
          key: pinDotsKey,
          count: _value.length,
          busy: _busy,
          failed: _error != null,
          colors: colors,
        ),
        // A FIXED-HEIGHT SLOT, so the keypad does not jump down the screen the
        // moment a PIN is refused — the user is about to press a digit, and it
        // would have moved.
        SizedBox(
          height: Space.xxl,
          child: Center(
            child: _error == null
                ? null
                : Text(
                    _error!,
                    key: pinErrorKey,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.statusTextDied,
                      fontSize: TextSize.note,
                    ),
                  ),
          ),
        ),
        _Keypad(
          colors: colors,
          enabled: !_busy,
          onDigit: _press,
          onDelete: _delete,
        ),
        if (widget.footer != null) ...[
          const SizedBox(height: Space.lg),
          widget.footer!,
        ],
      ],
    );
  }
}

/// The four dots.
class _Dots extends StatelessWidget {
  const _Dots({
    required this.count,
    required this.busy,
    required this.failed,
    required this.colors,
    super.key,
  });

  final int count;
  final bool busy;
  final bool failed;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    final ink = failed ? colors.statusTextDied : colors.accent;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            child: AnimatedContainer(
              duration: Motion.press,
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < count ? ink : const Color(0x00000000),
                border: Border.all(
                  color: i < count ? ink : colors.hairline,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The digits, in the arrangement every phone uses.
class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.colors,
    required this.enabled,
    required this.onDigit,
    required this.onDelete,
  });

  final HerdrColors colors;
  final bool enabled;
  final void Function(int digit) onDigit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          [1, 2, 3],
          [4, 5, 6],
          [7, 8, 9],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final digit in row)
                _KeyButton(
                  buttonKey: pinDigitKey(digit),
                  colors: colors,
                  enabled: enabled,
                  onTap: () => onDigit(digit),
                  child: Text(
                    '$digit',
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 26,
                      fontFamily: HerdrFonts.mono,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The empty cell that keeps `0` centred, exactly as the platform's
            // own keypads leave it.
            const SizedBox(width: _keySize, height: _keySize),
            _KeyButton(
              buttonKey: pinDigitKey(0),
              colors: colors,
              enabled: enabled,
              onTap: () => onDigit(0),
              child: Text(
                '0',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 26,
                  fontFamily: HerdrFonts.mono,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            _KeyButton(
              buttonKey: pinDeleteKey,
              colors: colors,
              enabled: enabled,
              onTap: onDelete,
              // Labelled, because an icon is not a word: seen through
              // `uiautomator` this key is otherwise a button with no name at
              // all, which is what a screen reader would announce.
              child: Semantics(
                label: AppLocalizations.of(context).lockKeypadDelete,
                button: true,
                child: Icon(
                  CupertinoIcons.delete_left,
                  size: 22,
                  color: colors.textDim,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

const double _keySize = 72;

/// One round key.
class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.colors,
    required this.enabled,
    required this.onTap,
    required this.child,
    this.buttonKey,
  });

  final HerdrColors colors;
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      key: buttonKey,
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: 0.5,
      onPressed: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.all(Space.sm),
        child: Container(
          width: _keySize,
          height: _keySize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.surface,
            border: Border.all(color: colors.hairline),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}
