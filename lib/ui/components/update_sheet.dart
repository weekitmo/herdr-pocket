import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/update/apk_installer.dart';
import 'package:herdr_pocket/data/update/update_controller.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';
import 'package:herdr_pocket/domain/update/system_proxy.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/herdr_sheet.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/components/transfer_progress.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Opens the update panel and, if nothing is known yet, starts a check.
///
/// A SHEET RATHER THAN A PAGE, and one sheet for every phase of the update.
/// Checking, being told, downloading, and installing are four states of one
/// question the user asked; splitting them across a page and two dialogs would
/// mean the answer to "what happened to my download" depends on which screen
/// the user happened to be on when it finished.
Future<void> showUpdateSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showHerdrSheet<void>(
    context: context,
    title: l10n.updateSheetTitle,
    builder: (_, _) => const _UpdateSheetBody(),
  );
}

class _UpdateSheetBody extends ConsumerStatefulWidget {
  const _UpdateSheetBody();

  @override
  ConsumerState<_UpdateSheetBody> createState() => _UpdateSheetBodyState();
}

class _UpdateSheetBodyState extends ConsumerState<_UpdateSheetBody>
    with WidgetsBindingObserver {
  @override
  void initState() {
    // The install permission can only change while the user is in ANOTHER app
    // — the system settings screen this sheet sent them to — so the only way to
    // notice is to look again on the way back. Without this the sheet keeps
    // offering 「去允许安装」 forever, and the user's second tap reopens the same
    // screen: from their side, a button that does nothing.
    WidgetsBinding.instance.addObserver(this);
    super.initState();
    // Started here rather than by the caller, and only from IDLE. A sheet that
    // opens on the previous answer ("you are up to date") is right; a sheet
    // that opens on "nothing has happened" has to start something, or the user
    // is looking at an empty panel wondering what the button they pressed was
    // for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(updateControllerProvider).phase is UpdateIdle) {
        unawaited(ref.read(updateControllerProvider.notifier).check());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(
      ref.read(updateControllerProvider.notifier).refreshInstallPermission(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(updateControllerProvider);
    final notifier = ref.read(updateControllerProvider.notifier);
    // Null on every platform that has no installer to hand a file to. The
    // update still CHECKS everywhere; what changes is what can be done next.
    final installable = ref.watch(apkInstallTargetProvider) != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          switch (status.phase) {
            UpdateIdle() || UpdateChecking() => _Checking(colors: colors),
            UpdateUpToDate(:final current) => TransferOutcome(
                colors: colors,
                icon: CupertinoIcons.check_mark_circled_solid,
                tint: colors.statusTextDone,
                text: l10n.updateUpToDate(current.toString()),
              ),
            UpdateAvailable(:final release, :final asset, :final partialBytes) =>
              _Offer(
                colors: colors,
                release: release,
                asset: asset,
                partialBytes: partialBytes,
                installable: installable,
              ),
            UpdateDownloading(:final received, :final total, :final fraction) =>
              TransferProgress(
                colors: colors,
                label: l10n.updateDownloading,
                text: total == null
                    ? formatByteCount(received)
                    : '${formatByteCount(received)} / ${formatByteCount(total)}',
                fraction: fraction,
                // The sentence the user needs before pressing it: cancelling
                // keeps what has arrived. Without it, nobody dares.
                cancelLabel: l10n.updateCancelDownload,
                onCancel: notifier.cancel,
              ),
            UpdateReady(:final release, :final canInstall) => _Ready(
                colors: colors,
                release: release,
                canInstall: canInstall,
              ),
            UpdateFailed(:final reason, :final detail) => _Failure(
                colors: colors,
                reason: reason,
                detail: detail,
                proxy: ref.watch(updateHttpProvider).resolver.current,
              ),
          },
          const SizedBox(height: Space.lg),
          ..._buttonsFor(
            context: context,
            colors: colors,
            l10n: l10n,
            status: status,
            notifier: notifier,
            installable: installable,
          ),
        ],
      ),
    );
  }

  /// The buttons each phase ends with.
  ///
  /// Returned as a list of widgets rather than a switch inside the tree because
  /// the decision is about the STATE, not about the layout — and the state
  /// switch above already ran.
  List<Widget> _buttonsFor({
    required BuildContext context,
    required HerdrColors colors,
    required AppLocalizations l10n,
    required UpdateStatus status,
    required UpdateController notifier,
    required bool installable,
  }) {
    final close = _SheetButton(
      colors: colors,
      label: l10n.actionClose,
      onPressed: () => Navigator.of(context).pop(),
    );

    return switch (status.phase) {
      // Nothing to press while a question is in flight: a second tap would join
      // the same future and change nothing visible.
      UpdateIdle() || UpdateChecking() => const [],
      UpdateUpToDate() => [close],
      UpdateAvailable(:final release, :final partialBytes) => [
          // No download button on a platform with no installer: 46 MB arriving
          // in a place nothing can install it is not a feature. The URL in the
          // body is the honest alternative there.
          if (installable)
            _SheetButton(
              colors: colors,
              label: partialBytes > 0 ? l10n.updateResume : l10n.updateDownload,
              primary: true,
              onPressed: notifier.download,
            ),
          if (installable && release.htmlUrl.isNotEmpty)
            _SheetButton(
              colors: colors,
              label: l10n.updateOpenRelease,
              onPressed: notifier.openReleasePage,
            ),
          close,
        ],
      UpdateDownloading() => const [],
      UpdateReady(:final canInstall) => [
          if (canInstall)
            _SheetButton(
              colors: colors,
              label: l10n.updateInstall,
              primary: true,
              onPressed: notifier.install,
            )
          else
            // The permission is the next step, not the install: pressing 安装
            // now would re-read the permission, find it missing and land back
            // here with nothing changed.
            _SheetButton(
              colors: colors,
              label: l10n.updateAllowInstall,
              primary: true,
              onPressed: notifier.openInstallPermissionSettings,
            ),
          close,
        ],
      // A FAILED DOWNLOAD can be resumed, because the partial file is still
      // there. A failed CHECK cannot: there is nothing to resume, and the
      // action is a different one wearing the same word.
      UpdateFailed(canRetry: true) => [
          _SheetButton(
            colors: colors,
            label: l10n.actionRetry,
            primary: true,
            onPressed: notifier.download,
          ),
          close,
        ],
      UpdateFailed() => [
          _SheetButton(
            colors: colors,
            label: l10n.actionRetry,
            primary: true,
            onPressed: () => unawaited(notifier.check()),
          ),
          close,
        ],
    };
  }
}

/// The spinner, which is the whole of the "asking" phase.
class _Checking extends StatelessWidget {
  const _Checking({required this.colors});

  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.md),
          child: CupertinoActivityIndicator(color: colors.textDim),
        ),
        TransferLine(
          colors: colors,
          text: AppLocalizations.of(context).updateChecking,
          dim: true,
        ),
      ],
    );
  }
}

/// What the release is, before you commit 46 MB to it.
class _Offer extends StatelessWidget {
  const _Offer({
    required this.colors,
    required this.release,
    required this.asset,
    required this.partialBytes,
    required this.installable,
  });

  final HerdrColors colors;
  final ReleaseInfo release;
  final ReleaseAsset asset;
  final int partialBytes;
  final bool installable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final published = release.publishedAt;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.updateAvailableTitle(release.version.toString()),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.text,
            fontSize: TextSize.title,
            fontWeight: FontWeight.w600,
            fontFamily: HerdrFonts.app,
            fontFamilyFallback: HerdrFonts.monoFallback,
          ),
        ),
        const SizedBox(height: Space.sm),
        // Machine facts in the machine voice, one per line. The size is the
        // one that decides whether this happens on mobile data.
        Text(
          [
            if (asset.size > 0) formatByteCount(asset.size),
            if (published != null) '${published.year}-${_two(published.month)}-${_two(published.day)}',
          ].join(' · '),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.textDim,
            fontSize: TextSize.meta,
            fontFamily: HerdrFonts.mono,
            fontFamilyFallback: HerdrFonts.monoFallback,
          ),
        ),
        if (partialBytes > 0) ...[
          const SizedBox(height: Space.sm),
          TransferLine(
            colors: colors,
            text: l10n.updateResumeHint(formatByteCount(partialBytes)),
            dim: true,
          ),
        ],
        if (!installable) ...[
          const SizedBox(height: Space.md),
          TransferLine(colors: colors, text: l10n.updateNotInstallable, dim: true),
          if (release.htmlUrl.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            // TAP TO COPY, because there is no button here for a good reason:
            // opening a link on a platform that cannot install the update would
            // mean another dependency for one tap, and the string itself is the
            // same information. NOT `SelectableText` — that widget is Material,
            // and this app has a rule (and a test) about that.
            GestureDetector(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: release.htmlUrl));
                if (context.mounted) {
                  showHerdrToast(context, l10n.updateUrlCopied);
                }
              },
              child: Text(
                release.htmlUrl,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.accent,
                  fontSize: TextSize.micro,
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
              ),
            ),
          ],
        ],
        if (release.body.trim().isNotEmpty) ...[
          const SizedBox(height: Space.lg),
          Text(
            l10n.updateNotesTitle,
            style: TextStyle(
              color: colors.textFaint,
              fontSize: TextSize.micro,
              fontFamily: HerdrFonts.app,
              fontFamilyFallback: HerdrFonts.monoFallback,
            ),
          ),
          const SizedBox(height: Space.xs),
          // Plain text, clipped. A markdown renderer would be a dependency and
          // a second typographic system for a body that is generated release
          // notes; the version and the first few lines are what gets read, and
          // the release page is one tap away for the rest.
          Text(
            release.body.trim(),
            maxLines: 12,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textDim,
              fontSize: TextSize.meta,
              height: 1.5,
              fontFamily: HerdrFonts.app,
              fontFamilyFallback: HerdrFonts.monoFallback,
            ),
          ),
        ],
      ],
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Downloaded, checked, one tap from the installer.
class _Ready extends StatelessWidget {
  const _Ready({
    required this.colors,
    required this.release,
    required this.canInstall,
  });

  final HerdrColors colors;
  final ReleaseInfo release;
  final bool canInstall;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TransferOutcome(
          colors: colors,
          icon: CupertinoIcons.arrow_down_circle_fill,
          tint: colors.statusTextDone,
          text: l10n.updateReady(release.version.toString()),
        ),
        const SizedBox(height: Space.md),
        // The check that ran is worth SAYING: it is the difference between
        // "a file arrived" and "a file that can be installed over this app
        // arrived", and the second is the only one worth a button.
        TransferLine(colors: colors, text: l10n.updateVerified, dim: true),
        if (!canInstall) ...[
          const SizedBox(height: Space.md),
          TransferLine(colors: colors, text: l10n.updateNeedsPermission, dim: true),
        ],
        const SizedBox(height: Space.md),
        // Android shows its own confirmation dialog; there is no silent path
        // without device owner or root, and pretending otherwise would make the
        // button a promise this app cannot keep.
        TransferLine(colors: colors, text: l10n.updateInstallFootnote, dim: true),
      ],
    );
  }
}

/// One failure, one sentence, one next step.
class _Failure extends StatelessWidget {
  const _Failure({
    required this.colors,
    required this.reason,
    required this.detail,
    required this.proxy,
  });

  final HerdrColors colors;
  final UpdateFailure reason;
  final String? detail;
  final SystemProxy? proxy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final raw = detail;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TransferOutcome(
          colors: colors,
          icon: CupertinoIcons.exclamationmark_circle_fill,
          tint: colors.statusTextDied,
          text: updateFailureText(l10n, reason, proxy: proxy),
        ),
        if (raw != null && raw.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          // The diagnostic, kept small and last. It is never the sentence the
          // user is meant to act on — it is what makes a screenshot of this
          // panel worth something.
          Text(
            raw,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textFaint,
              fontSize: TextSize.micro,
              fontFamily: HerdrFonts.mono,
              fontFamilyFallback: HerdrFonts.monoFallback,
            ),
          ),
        ],
      ],
    );
  }
}

/// The sentence for one failure class.
///
/// A switch over the ENUM, which is the point of the enum: every case needs a
/// different next step, and the three that a user with a proxy hits in sequence
/// — [UpdateFailure.proxyRefused], [UpdateFailure.tlsRejected] and
/// [UpdateFailure.offline] — are told apart here rather than by the user.
///
/// [proxy] is what the platform reported, so the proxy sentence can name the
/// address and port instead of saying "your proxy".
String updateFailureText(
  AppLocalizations l10n,
  UpdateFailure reason, {
  SystemProxy? proxy,
}) {
  final address = switch (proxy) {
    final SystemProxy p when p.isUsable => '${p.host}:${p.port}',
    _ => null,
  };
  return switch (reason) {
    UpdateFailure.offline => l10n.updateFailedOffline,
    UpdateFailure.proxyRefused => address == null
        ? l10n.updateFailedProxyUnknown
        : l10n.updateFailedProxy(address),
    UpdateFailure.tlsRejected => l10n.updateFailedTls,
    UpdateFailure.timedOut => l10n.updateFailedTimedOut,
    UpdateFailure.rateLimited => l10n.updateFailedRateLimited,
    UpdateFailure.httpStatus => l10n.updateFailedHttp,
    UpdateFailure.badPayload => l10n.updateFailedPayload,
    UpdateFailure.noRelease => l10n.updateFailedNoRelease,
    UpdateFailure.noAssetForDevice => l10n.updateFailedNoAsset,
    UpdateFailure.storage => l10n.updateFailedStorage,
    UpdateFailure.checksum => l10n.updateFailedChecksum,
    UpdateFailure.sizeMismatch => l10n.updateFailedSize,
    UpdateFailure.cancelled => l10n.updateCancelled,
    UpdateFailure.installBlocked => l10n.updateFailedInstallBlocked,
    UpdateFailure.signatureMismatch => l10n.updateFailedSignature,
    UpdateFailure.wrongPackage => l10n.updateFailedWrongPackage,
    UpdateFailure.versionTooOld => l10n.updateFailedVersionOld,
    UpdateFailure.unknown => l10n.updateFailedUnknown,
  };
}

/// A full-width button, primary or not.
class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.colors,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final HerdrColors colors;
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        borderRadius: BorderRadius.circular(Radii.uniform),
        // `accent` for the primary action, never a status colour: the status
        // palette means "what an agent is doing", and a button borrows that
        // vocabulary the moment it uses one.
        color: primary ? colors.accent : colors.surfaceRaised,
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            color: primary ? colors.ground : colors.text,
            fontSize: TextSize.body,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
