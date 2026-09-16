import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/pairing.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Pairing a phone with a machine, in one screen.
///
/// ## Two doors, one parser
///
/// The card at the top scans the QR code `hdp pair` prints, and it is marked as
/// the recommended way in. The card below takes the same string pasted in. They
/// are not two features: the scan decodes to exactly the bytes the paste
/// contains, and both go through `parsePairingString`.
///
/// That is why the paste path is not a fallback in the apologetic sense. It is
/// the door that keeps working when the phone is nowhere near the host, when
/// the camera permission was refused months ago for some other app, when the
/// terminal is light-on-dark and the scanner will not lock on, or when the
/// screen is simply too small to hold a code steady. Every one of those is a
/// real situation, and all of them end with the same working pairing.
class PairingPage extends ConsumerWidget {
  /// Holds the page.
  const PairingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        obstructs: false,
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          l10n.pairTitle,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
      ),
      child: const PairingView(),
    );
  }
}

/// The pairing UI, without any chrome.
///
/// Split out because it is shown in two places: this page, and as one mode of
/// the add-machine sheet. The sheet is where it is actually reached now; the
/// page is kept because a standalone route is the right thing if a future
/// entry point needs one, and because it is what the widget tests drive.
class PairingView extends ConsumerStatefulWidget {
  /// Holds the view.
  const PairingView({this.sheetMode = false, super.key});

  /// Drops the page-level insets when it is inside a sheet, which supplies
  /// its own.
  final bool sheetMode;

  @override
  ConsumerState<PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends ConsumerState<PairingView> {
  final _controller = TextEditingController();

  /// Whether the camera is open. The scanner is built only when it is, because
  /// a live camera behind a card that is not showing it is a battery drain and
  /// a privacy indicator with no purpose.
  bool _scanning = false;

  /// Set when the camera could not be started — a refusal, or a device with no
  /// camera at all. Shown INSIDE the scan card rather than as a second system
  /// prompt, next to the sentence that says the paste path still works.
  bool _scanUnavailable = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(pairingControllerProvider);
    final busy = state is PairingWorking;

    // The settings scroll feel, because this is a form and not a feed: no
    // overscroll, and no pull-to-refresh to trigger by accident while reaching
    // for the paste field.
    final insets = MediaQuery.paddingOf(context);
    return ScrollConfiguration(
      behavior: settingsScrollBehavior(context),
      child: ListView(
        padding: EdgeInsets.only(
          top: widget.sheetMode ? 0 : insets.top + Space.sm,
          bottom: (widget.sheetMode ? 0 : insets.bottom) + Space.xxl,
        ),
        children: [
          _ScanGroup(
            colors: colors,
            l10n: l10n,
            scanning: _scanning,
            unavailable: _scanUnavailable,
            enabled: !busy,
            onStart: _startScanning,
            onStop: _stopScanning,
            onCode: _onScanned,
          ),
          _PasteGroup(
            colors: colors,
            l10n: l10n,
            controller: _controller,
            enabled: !busy,
          ),
          _StatusRow(colors: colors, l10n: l10n, state: state),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, 0),
            child: _PrimaryButton(
              colors: colors,
              label: state is PairingSucceeded ? l10n.pairRetry : l10n.pairConnect,
              enabled: !busy,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }

  void _submit() {
    ref.read(pairingControllerProvider.notifier).reset();
    unawaited(ref.read(pairingControllerProvider.notifier).start(_controller.text));
  }

  Future<void> _startScanning() async {
    setState(() {
      _scanning = true;
      _scanUnavailable = false;
    });
  }

  void _stopScanning() {
    if (!_scanning) return;
    setState(() => _scanning = false);
  }

  /// One scan, then the camera closes and the string goes straight in.
  ///
  /// Closing on the first decode rather than collecting continuously: a
  /// scanner that keeps running fills the field with whatever it looks at
  /// next, and this field is being filled with a credential.
  void _onScanned(BarcodeCapture capture) {
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;

    _stopScanning();
    _controller.text = raw;
    unawaited(ref.read(pairingControllerProvider.notifier).start(raw));
  }
}

/// The scan card. First, and marked as the way in most people should take.
class _ScanGroup extends StatelessWidget {
  const _ScanGroup({
    required this.colors,
    required this.l10n,
    required this.scanning,
    required this.unavailable,
    required this.enabled,
    required this.onStart,
    required this.onStop,
    required this.onCode,
  });

  final HerdrColors colors;
  final AppLocalizations l10n;
  final bool scanning;
  final bool unavailable;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(BarcodeCapture) onCode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The title row carries the badge, so "recommended" is attached to the
        // thing being recommended rather than floating above both cards.
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  sectionTitle(context, l10n.pairScanTitle),
                  style: TextStyle(
                    color: colors.textFaint,
                    fontSize: TextSize.note,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              _RecommendedBadge(colors: colors, label: l10n.pairScanRecommended),
            ],
          ),
        ),
        if (scanning)
          SettingsGroup(
            rows: [_ScannerView(colors: colors, onCode: onCode, onStop: onStop)],
          )
        else
          SettingsGroup(
            rows: [
              _TapRow(
                label: l10n.pairScanStart,
                colors: colors,
                onTap: enabled ? onStart : null,
              ),
            ],
          ),

        // THE SENTENCE GOES UNDER THE CARD, not inside it as a row label.
        // `SettingsRow.label` is single-line by design — it is a settings label,
        // and a settings label that wraps turns its row into a paragraph — so
        // the first version rendered "Run hdp pair on the computer, the…" on
        // the device and read as broken. This is also where the design rules
        // say an explanation belongs: below the card it explains.
        SettingsNote(
          text: unavailable ? l10n.pairScanDenied : l10n.pairScanBody,
        ),
      ],
    );
  }
}

/// A row that is entirely a tap target, with a chevron.
///
/// The whole row rather than a button at its end: `SettingsRow.label` cannot
/// hold a sentence, so the row is the short action and the sentence explaining
/// it sits below the card. A row that says what it does and opens on a tap is
/// what iOS Settings does with the same shape.
class _TapRow extends StatelessWidget {
  const _TapRow({
    required this.label,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final HerdrColors colors;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SettingsRow(
          label: label,
          labelColor: onTap == null ? colors.textFaint : colors.accent,
          trailing: Icon(
            CupertinoIcons.chevron_forward,
            size: 14,
            color: onTap == null ? colors.textFaint : colors.accent,
          ),
        ),
      ),
    );
  }
}

/// The badge on the scan card.
///
/// ACCENT, NOT A STATUS COLOUR. "Recommended" is not waiting, working, failed
/// or done — borrowing one of those would put a fourth meaning on a colour
/// that already has three, in an app whose whole visual language is "colour is
/// meaning".
class _RecommendedBadge extends StatelessWidget {
  const _RecommendedBadge({required this.colors, required this.label});

  final HerdrColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xxs),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.uniform),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.accent,
          fontSize: TextSize.micro,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ScannerView extends StatelessWidget {
  const _ScannerView({
    required this.colors,
    required this.onCode,
    required this.onStop,
  });

  final HerdrColors colors;
  final void Function(BarcodeCapture) onCode;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.uniform),
          child: SizedBox(
            // A SQUARE PREVIEW, and the aspect ratio is forced rather than
            // inferred: `MobileScanner` fills whatever box it is given, so in a
            // list it would take the height of its own camera stream and push
            // the manual entry card off the screen.
            height: 280,
            width: double.infinity,
            child: MobileScanner(
              onDetect: onCode,
              // Errors land here rather than throwing into the widget tree, so
              // a refused permission becomes a sentence under the card instead
              // of a red box.
              errorBuilder: (context, error) => ColoredBox(
                color: colors.surfaceRaised,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Text(
                      AppLocalizations.of(context).pairScanDenied,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onStop,
          child: SettingsRow(
            label: AppLocalizations.of(context).actionCancel,
            labelColor: colors.accent,
            trailing:
                Icon(CupertinoIcons.xmark, size: 14, color: colors.textFaint),
          ),
        ),
      ],
    );
  }
}

/// The paste card.
class _PasteGroup extends StatelessWidget {
  const _PasteGroup({
    required this.colors,
    required this.l10n,
    required this.controller,
    required this.enabled,
  });

  final HerdrColors colors;
  final AppLocalizations l10n;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.xl, Space.lg, Space.sm),
          child: Text(
            sectionTitle(context, l10n.pairPasteTitle),
            style: TextStyle(
              color: colors.textFaint,
              fontSize: TextSize.note,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        SettingsGroup(
          rows: [
            // The textarea is the whole card. The sentence that explains it is
            // below, for the same reason as the scan card's.
            Padding(
              padding: const EdgeInsets.all(Space.md),
              child: CupertinoTextField(
                controller: controller,
                enabled: enabled,
                placeholder: l10n.pairPastePlaceholder,
                placeholderStyle: TextStyle(
                  color: colors.textFaint,
                  fontSize: TextSize.body,
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
                maxLines: 5,
                minLines: 3,
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: colors.surfaceRaised,
                  borderRadius: BorderRadius.circular(Radii.uniform),
                ),
                // THE STYLE IS SPELLED OUT HERE because a CupertinoTextField
                // hands it straight to `EditableText` without merging with the
                // app's default text style — so the fallback face is not
                // inherited, and without it the Chinese in this field drops out
                // of the monospace grid (AGENTS.md, Phase 10).
                style: TextStyle(
                  color: colors.text,
                  fontSize: TextSize.body,
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
                // A pairing string is base64url: no autocorrect, no
                // capitalisation, and no smart punctuation. The system's quote
                // and dash rewriting is the thing that silently corrupts a
                // pasted credential, and `autocorrect: false` alone does not
                // turn it off.
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                keyboardType: TextInputType.visiblePassword,
              ),
            ),
          ],
        ),
        SettingsNote(text: l10n.pairPasteBody),
      ],
    );
  }
}

/// The status line, which is where every failure is explained.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.colors,
    required this.l10n,
    required this.state,
  });

  final HerdrColors colors;
  final AppLocalizations l10n;
  final PairingUiState state;

  @override
  Widget build(BuildContext context) {
    final (icon, tint, text, detail) = switch (state) {
      PairingIdle() => (
          CupertinoIcons.info,
          colors.textFaint,
          l10n.pairStatusIdle,
          null,
        ),
      PairingWorking(:final step, :final host) => (
          CupertinoIcons.arrow_2_circlepath,
          colors.textDim,
          switch (step) {
            PairingStep.connect => l10n.pairStatusConnect(host ?? ''),
            PairingStep.exchange => l10n.pairStatusExchange,
            PairingStep.verify => l10n.pairStatusVerify,
          },
          null,
        ),
      PairingSucceeded(:final profile) => (
          CupertinoIcons.check_mark_circled_solid,
          colors.statusTextDone,
          l10n.pairStatusDone(profile.label),
          null,
        ),
      PairingRejected(:final reason, :final detail) => (
          CupertinoIcons.exclamationmark_circle_fill,
          colors.statusTextDied,
          _failureText(l10n, reason),
          // AND THE SERVER'S OWN WORDS, when there are any.
          //
          // The sentence above is a CATEGORY — "the code has expired" is one of
          // ten, and several of them are indistinguishable from here: a key
          // that was deleted by another `hdp pair`, a key that was never read
          // because `AuthorizedKeysFile` points elsewhere, and a key that
          // really did expire all arrive as the same authentication failure.
          // Showing what the far end actually said is the difference between a
          // bug report that can be acted on and one that cannot.
          detail,
        ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.xl, Space.lg, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: tint),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    color: state is PairingIdle ? colors.textDim : colors.text,
                    fontSize: TextSize.body,
                    height: 1.4,
                  ),
                ),
                if (detail != null && detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      detail,
                      style: TextStyle(
                        color: colors.textFaint,
                        fontSize: TextSize.micro,
                        height: 1.35,
                        fontFamily: HerdrFonts.mono,
                        fontFamilyFallback: HerdrFonts.monoFallback,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One sentence per failure, and every one of them says what to do next.
///
/// A switch over the ENUM rather than a message: these are the sentences a user
/// reads at the moment something did not work, and the two that can be fixed in
/// this app say where.
String _failureText(AppLocalizations l10n, PairingFailureReason reason) =>
    switch (reason) {
      PairingFailureReason.empty => l10n.pairFailedEmpty,
      PairingFailureReason.malformed => l10n.pairFailedMalformed,
      PairingFailureReason.unsupportedVersion => l10n.pairFailedUnsupported,
      PairingFailureReason.incomplete => l10n.pairFailedIncomplete,
      PairingFailureReason.unreachable => l10n.pairFailedUnreachable,
      PairingFailureReason.hostKeyMismatch => l10n.pairFailedMismatch,
      PairingFailureReason.codeExpired => l10n.pairFailedBootstrap,
      PairingFailureReason.exchangeFailed => l10n.pairFailedExchange,
      PairingFailureReason.verifyFailed => l10n.pairFailedVerify,
      PairingFailureReason.unknown => l10n.pairFailedUnknown,
    };

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.colors,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final HerdrColors colors;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      borderRadius: BorderRadius.circular(Radii.uniform),
      // `accent`, again not a status colour: this is the action, and the
      // status row directly above it is already using the status colours.
      color: enabled ? colors.accent : colors.surfaceRaised,
      onPressed: enabled ? onPressed : null,
      child: Text(
        label,
        style: TextStyle(
          color: enabled ? colors.ground : colors.textFaint,
          fontSize: TextSize.strong,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
