import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_download.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Starts a download and shows what is happening to it.
///
/// A sheet rather than a background task with a toast, because the transfer has
/// three properties that a toast cannot express: it can take minutes, it can be
/// abandoned halfway, and abandoning it has a consequence (a half-written file
/// that must not keep its name). A user who cannot see a progress bar cannot
/// make any of those three decisions.
///
/// The sheet does not own the transfer — [DownloadController] does. Closing the
/// sheet therefore does not cancel anything, which is deliberate: a swipe-down
/// on a modal is a navigation gesture, not a "stop moving my file" gesture, and
/// conflating them would make an accidental swipe destroy a nearly-finished
/// transfer. Cancelling is the button.
Future<void> showDownloadSheet(
  BuildContext context, {
  required String remotePath,
  required String fileName,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (sheetContext) => _DownloadSheet(
      remotePath: remotePath,
      fileName: fileName,
    ),
  );
}

class _DownloadSheet extends ConsumerStatefulWidget {
  const _DownloadSheet({required this.remotePath, required this.fileName});

  final String remotePath;
  final String fileName;

  @override
  ConsumerState<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends ConsumerState<_DownloadSheet> {
  @override
  void initState() {
    super.initState();
    // Started here rather than by the caller so the sheet exists before the
    // first state change: starting first would publish a `TransferRunning`
    // that nobody is listening to yet, and the bar would begin at whatever
    // arrived in the meantime.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(downloadControllerProvider.notifier).start(
              remotePath: widget.remotePath,
              fileName: widget.fileName,
            ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(downloadControllerProvider);

    return _SheetSurface(
      colors: colors,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: TextSize.strong,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
            const SizedBox(height: Space.lg),
            switch (state) {
              TransferIdle() => _Line(
                  colors: colors,
                  text: l10n.downloadPreparing,
                  dim: true,
                ),
              TransferRunning(:final received, :final total) => _Progress(
                  colors: colors,
                  text: total == null
                      ? l10n.downloadUnknownSize(
                          formatByteCount(received),
                          widget.fileName,
                        )
                      : l10n.downloadOf(
                          formatByteCount(received),
                          widget.fileName,
                          formatByteCount(total),
                        ),
                  fraction: transferFraction(received: received, total: total),
                  label: l10n.downloadTitle,
                  cancelLabel: l10n.downloadCancel,
                  onCancel: ref.read(downloadControllerProvider.notifier).cancel,
                ),
              TransferDone(:final directoryLabel) => _Outcome(
                  colors: colors,
                  icon: CupertinoIcons.check_mark_circled_solid,
                  tint: colors.statusTextDone,
                  text: (directoryLabel.isEmpty
                      ? l10n.downloadDoneNoDir
                      : l10n.downloadDone(directoryLabel)),
                  buttonLabel: l10n.downloadClose,
                ),
              TransferFailed(:final reason) => _Outcome(
                  colors: colors,
                  icon: CupertinoIcons.exclamationmark_circle_fill,
                  tint: colors.statusTextDied,
                  text: _failureText(l10n, reason),
                  buttonLabel: l10n.downloadClose,
                ),
            },
            const SizedBox(height: Space.lg),
            if (state is! TransferRunning)
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: Space.md),
                borderRadius: BorderRadius.circular(Radii.uniform),
                color: colors.surfaceRaised,
                onPressed: () {
                  // Reset before popping so the next sheet opens on a clean
                  // state rather than on the last transfer's result — which
                  // would flash "saved" over a file that has not moved yet.
                  ref.read(downloadControllerProvider.notifier).reset();
                  Navigator.of(context).pop();
                },
                child: Text(
                  switch (state) {
                    TransferDone() => l10n.downloadClose,
                    _ => l10n.actionClose,
                  },
                  style: TextStyle(color: colors.text, fontSize: TextSize.body),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The sentence for one failure class.
///
/// A switch over the ENUM, which is the point of the enum: every case here
/// needs a different next step, and the two that are fixable in this app say
/// where to fix them.
String _failureText(AppLocalizations l10n, DownloadFailure reason) =>
    switch (reason) {
      DownloadFailure.featureOff => l10n.downloadFailedFeatureOff,
      DownloadFailure.noDirectory => l10n.downloadFailedNoDir,
      DownloadFailure.directoryRevoked => l10n.downloadFailedRevoked,
      // The one failure that is always the HOST's configuration, and the only
      // one whose message names the thing to change rather than the thing that
      // went wrong.
      DownloadFailure.sftpUnavailable => l10n.downloadFailedSftp,
      DownloadFailure.remoteFailed => l10n.downloadFailedRemote,
      DownloadFailure.connectionLost => l10n.downloadFailedConnection,
      DownloadFailure.unknown => l10n.downloadFailedUnknown,
    };

class _Progress extends StatelessWidget {
  const _Progress({
    required this.colors,
    required this.text,
    required this.fraction,
    required this.label,
    required this.cancelLabel,
    required this.onCancel,
  });

  final HerdrColors colors;
  final String text;
  final double? fraction;
  final String label;
  final String cancelLabel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final value = fraction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
        ),
        const SizedBox(height: Space.sm),
        if (value != null)
          // No Material progress indicator anywhere in this app; the bar is
          // two boxes and a clip, which is also the only way to keep it on the
          // app's own accent rather than Cupertino's blue.
          _Bar(colors: colors, value: value)
        else
          // An indeterminate sweep rather than a stuck-at-zero bar: a bar that
          // does not move is indistinguishable from a hang, and the far end not
          // reporting a size is common enough to deserve an honest answer.
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoActivityIndicator(color: colors.textDim),
          ),
        const SizedBox(height: Space.sm),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.textDim,
            fontSize: TextSize.meta,
            fontFamily: HerdrFonts.mono,
            fontFamilyFallback: HerdrFonts.monoFallback,
          ),
        ),
        const SizedBox(height: Space.md),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          onPressed: onCancel,
          child: Text(
            cancelLabel,
            style: TextStyle(color: colors.accent, fontSize: TextSize.body),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.colors, required this.value});

  final HerdrColors colors;
  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.uniform),
      child: SizedBox(
        height: 6,
        // The full-width requirement from `AGENTS.md`: inside a Column a bare
        // ColoredBox gets a loose cross-axis constraint and resolves to zero
        // width, which draws nothing at all and looks like the transfer is
        // stuck before it started.
        width: double.infinity,
        child: Stack(
          children: [
            Container(color: colors.surfaceRaised),
            FractionallySizedBox(
              widthFactor: value,
              child: Container(color: colors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.colors,
    required this.icon,
    required this.tint,
    required this.text,
    required this.buttonLabel,
  });

  final HerdrColors colors;
  final IconData icon;
  final Color tint;
  final String text;
  final String buttonLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 28, color: tint),
        const SizedBox(height: Space.sm),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.text,
            fontSize: TextSize.body,
            height: 1.4,
            fontFamily: HerdrFonts.mono,
            fontFamilyFallback: HerdrFonts.monoFallback,
          ),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.colors, required this.text, this.dim = false});

  final HerdrColors colors;
  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: dim ? colors.textDim : colors.text,
        fontSize: TextSize.body,
      ),
    );
  }
}

/// The sheet's own surface, so it is the app's material and not Cupertino's.
class _SheetSurface extends StatelessWidget {
  const _SheetSurface({required this.colors, required this.child});

  final HerdrColors colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        // The app's single radius, and only on the top two corners: the
        // bottom edge is the screen's.
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.uniform),
        ),
      ),
      child: SafeArea(top: false, child: child),
    );
  }
}
