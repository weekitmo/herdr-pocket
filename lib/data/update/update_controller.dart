import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/update/apk_installer.dart';
import 'package:herdr_pocket/data/update/asset_downloader.dart';
import 'package:herdr_pocket/data/update/release_client.dart';
import 'package:herdr_pocket/data/update/update_exception.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/update/app_version.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';

/// What the update UI is showing.
sealed class UpdateState {
  /// The one constructor.
  const UpdateState();
}

/// Nothing is happening and nothing is known.
class UpdateIdle extends UpdateState {
  /// The one idle state.
  const UpdateIdle();
}

/// Asking GitHub.
class UpdateChecking extends UpdateState {
  /// The one checking state.
  const UpdateChecking();
}

/// Asked, and this build is the newest.
class UpdateUpToDate extends UpdateState {
  /// Holds the answer.
  const UpdateUpToDate({required this.current, this.checkedAt});

  /// The version that is installed.
  final AppVersion current;

  /// When the answer was obtained.
  final DateTime? checkedAt;
}

/// A newer release exists and has an APK this device can install.
class UpdateAvailable extends UpdateState {
  /// Holds the offer.
  const UpdateAvailable({
    required this.release,
    required this.asset,
    this.partialBytes = 0,
  });

  /// The release being offered.
  final ReleaseInfo release;

  /// The one asset chosen for this device.
  final ReleaseAsset asset;

  /// Bytes already on disk from a previous attempt, when there are any.
  ///
  /// Shown as "已下载 12 MB，继续" rather than as a fresh offer: the resume
  /// only works if the user knows the earlier attempt was not wasted.
  final int partialBytes;
}

/// Bytes are moving.
class UpdateDownloading extends UpdateState {
  /// Holds the transfer.
  const UpdateDownloading({
    required this.release,
    required this.asset,
    required this.received,
    this.total,
  });

  /// The release being downloaded.
  final ReleaseInfo release;

  /// The asset being downloaded.
  final ReleaseAsset asset;

  /// Bytes on disk, including anything resumed.
  final int received;

  /// Expected total, or null when nothing knows it.
  final int? total;

  /// 0..1, or null when the total is unknown.
  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (received / total).clamp(0, 1);
  }
}

/// The APK is on the phone, checked, and waiting to be handed to the installer.
class UpdateReady extends UpdateState {
  /// Holds the finished download.
  const UpdateReady({
    required this.release,
    required this.asset,
    required this.file,
    required this.inspection,
    required this.canInstall,
  });

  /// The release that was downloaded.
  final ReleaseInfo release;

  /// The asset that was downloaded.
  final ReleaseAsset asset;

  /// Where it landed.
  final File file;

  /// What the platform said about it.
  final ApkInspection inspection;

  /// Whether the system will let this app install packages right now.
  ///
  /// A snapshot for the hint under the button. [UpdateController.install]
  /// re-asks, because the only way this becomes true is the user leaving the
  /// app for a Settings screen and coming back.
  final bool canInstall;
}

/// It went wrong, with a classification.
class UpdateFailed extends UpdateState {
  /// Holds the failure.
  const UpdateFailed({
    required this.reason,
    this.detail,
    this.release,
    this.asset,
  });

  /// What went wrong.
  final UpdateFailure reason;

  /// Raw diagnostic text.
  final String? detail;

  /// The release it was about, when that is still known — a download that
  /// failed at 80% can be resumed, and the retry needs to know what.
  final ReleaseInfo? release;

  /// The asset it was about, when known.
  final ReleaseAsset? asset;

  /// Whether pressing "retry" would continue something rather than start over.
  ///
  /// TRUE ONLY WHEN THERE IS AN ASSET, which is the same thing as "this was a
  /// download, not a check". A failed check has nothing to resume: the retry
  /// there is a different action, and it must not wear the same word.
  bool get canRetry => asset != null;
}

/// The state plus what is remembered between launches.
class UpdateStatus {
  /// Holds one snapshot.
  const UpdateStatus({
    this.phase = const UpdateIdle(),
    this.latest,
    this.checkedAt,
  });

  /// What the UI is showing.
  final UpdateState phase;

  /// The newest version known, from this run or from storage.
  ///
  /// Kept separate from [phase] so the settings row can say "有新版本 0.2.0"
  /// on the launch AFTER the check that found it, without re-asking GitHub.
  final AppVersion? latest;

  /// When a check last succeeded.
  final DateTime? checkedAt;

  /// A copy with parts replaced.
  UpdateStatus copyWith({
    UpdateState? phase,
    AppVersion? latest,
    DateTime? checkedAt,
  }) =>
      UpdateStatus(
        phase: phase ?? this.phase,
        latest: latest ?? this.latest,
        checkedAt: checkedAt ?? this.checkedAt,
      );
}

/// How a check ended, for the caller that has to decide whether to speak.
///
/// Separate from [UpdateState] because the two callers want different things:
/// the sheet renders the state, and the launch hook only needs to know whether
/// it is worth a toast. A silent check that fails says nothing at all.
enum UpdateCheckOutcome { available, upToDate, failed }

/// The app's own updater.
///
/// ONE STATE MACHINE, TWO ENTRY POINTS. The manual check (from Settings) and
/// the launch check (when the user turned it on) run the same code and land in
/// the same state; the only difference is who reads the result, and the shape
/// of the result is what keeps the difference from leaking.
class UpdateController extends Notifier<UpdateStatus> {
  /// The in-flight check, so a second tap joins it rather than starting a
  /// second request — and so the launch check and a manual tap cannot race into
  /// two offers.
  Future<UpdateCheckOutcome>? _checking;

  /// The transfer's cancel handle.
  CancelToken? _cancelToken;

  /// The key holding the newest version seen.
  static const String _kLatest = 'update.latestVersion';

  /// The key holding when the last successful check happened.
  static const String _kCheckedAt = 'update.checkedAt';

  @override
  UpdateStatus build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stamp = prefs.getInt(_kCheckedAt);
    return UpdateStatus(
      latest: switch (prefs.getString(_kLatest)) {
        final String raw => AppVersion.tryParse(raw),
        _ => null,
      },
      checkedAt:
          stamp == null ? null : DateTime.fromMillisecondsSinceEpoch(stamp),
    );
  }

  /// Asks GitHub whether there is something newer than [AppVersion] installed.
  ///
  /// Returns what happened so the caller can decide whether to speak. Never
  /// throws: a failure is a state, and the state is what the UI renders.
  Future<UpdateCheckOutcome> check() {
    final running = _checking;
    if (running != null) return running;
    final started = _check();
    _checking = started;
    return started.whenComplete(() => _checking = null);
  }

  Future<UpdateCheckOutcome> _check() async {
    final current = ref.read(appVersionProvider);
    if (current == null) {
      // The platform has not answered about its own version yet. Retrying in a
      // moment is right; inventing a version to compare against is not.
      return UpdateCheckOutcome.failed;
    }

    state = state.copyWith(phase: const UpdateChecking());
    final client = ref.read(releaseClientProvider);
    try {
      final release = pickAppRelease(await client.releases());
      final now = DateTime.now();

      if (release == null) {
        // The request SUCCEEDED and found nothing installable. Clearing what
        // was remembered is right here and only here: a version that no longer
        // has a release should stop being offered.
        await _remember(latest: null, at: now);
        state = UpdateStatus(
          phase: const UpdateFailed(reason: UpdateFailure.noRelease),
          checkedAt: now,
        );
        return UpdateCheckOutcome.failed;
      }

      await _remember(latest: release.version, at: now);

      if (!release.version.isNewerThan(current)) {
        state = UpdateStatus(
          phase: UpdateUpToDate(current: current, checkedAt: now),
          latest: release.version,
          checkedAt: now,
        );
        return UpdateCheckOutcome.upToDate;
      }

      final abi = ref.read(deviceAbiProvider);
      final asset = pickApkAsset(release, abi);
      if (asset == null) {
        state = UpdateStatus(
          phase: UpdateFailed(
            reason: UpdateFailure.noAssetForDevice,
            detail: 'no APK for $abi in ${release.tag}',
            release: release,
          ),
          latest: release.version,
          checkedAt: now,
        );
        return UpdateCheckOutcome.failed;
      }

      state = UpdateStatus(
        phase: UpdateAvailable(release: release, asset: asset),
        latest: release.version,
        checkedAt: now,
      );
      return UpdateCheckOutcome.available;
    } on UpdateException catch (error) {
      // A failure does NOT touch what was remembered: "I could not ask" is not
      // "there is nothing".
      state = state.copyWith(
        phase: UpdateFailed(reason: error.failure, detail: error.detail),
      );
      return UpdateCheckOutcome.failed;
    }
  }

  /// Downloads (or resumes) the offered APK and checks it.
  Future<void> download() async {
    final phase = state.phase;
    final release = switch (phase) {
      UpdateAvailable(:final release) => release,
      UpdateDownloading(:final release) => release,
      UpdateFailed(:final release?) => release,
      _ => null,
    };
    final asset = switch (phase) {
      UpdateAvailable(:final asset) => asset,
      UpdateDownloading(:final asset) => asset,
      UpdateFailed(:final asset?) => asset,
      _ => null,
    };
    if (release == null || asset == null) return;

    final target = ref.read(apkInstallTargetProvider);
    final staging = await target?.stagingDirectory();
    if (target == null || staging == null) {
      state = state.copyWith(
        phase: UpdateFailed(
          reason: UpdateFailure.installBlocked,
          detail: 'this platform has no installer',
          release: release,
          asset: asset,
        ),
      );
      return;
    }

    final token = CancelToken();
    _cancelToken = token;
    state = state.copyWith(
      phase: UpdateDownloading(
        release: release,
        asset: asset,
        received: 0,
        total: asset.size > 0 ? asset.size : null,
      ),
    );

    try {
      final downloader = ref.read(assetDownloaderProvider);
      // Anything left over from a DIFFERENT version is 46 MB of nothing.
      await downloader.sweep(staging, keep: asset.name);

      // The expected hash is fetched FIRST, because it is what decides whether
      // the file already on disk is worth keeping.
      final expected =
          (await ref.read(releaseClientProvider).checksums(release))[asset.name];

      final downloaded = await _reuse(staging, asset, expected) ??
          await downloader.download(
            asset: asset,
            staging: staging,
            cancelToken: token,
            onProgress: (progress) {
              if (token.isCancelled) return;
              state = state.copyWith(
                phase: UpdateDownloading(
                  release: release,
                  asset: asset,
                  received: progress.received,
                  total: progress.total,
                ),
              );
            },
          );

      if (expected != null && expected != downloaded.sha256) {
        // A file that failed its checksum is the one partial that is known to
        // be worthless, so it goes — otherwise the resume path would resume
        // from a corrupt prefix forever.
        await _delete(downloaded.file);
        throw UpdateException(
          UpdateFailure.checksum,
          detail:
              'expected $expected, got ${downloaded.sha256} for ${asset.name}',
        );
      }

      final inspection = await target.inspect(downloaded.file);
      final problem = _inspectFailure(
        inspection,
        installedVersionCode: installedVersionCode(),
      );
      if (problem != null) {
        await _delete(downloaded.file);
        state = state.copyWith(
          phase: UpdateFailed(
            reason: problem,
            detail: '${inspection.packageName} v${inspection.versionCode}',
            release: release,
            asset: asset,
          ),
        );
        return;
      }

      state = state.copyWith(
        phase: UpdateReady(
          release: release,
          asset: asset,
          file: downloaded.file,
          inspection: inspection,
          canInstall: await target.canInstallPackages(),
        ),
      );
    } on UpdateException catch (error) {
      if (error.failure == UpdateFailure.cancelled) {
        state = state.copyWith(
          phase: UpdateAvailable(
            release: release,
            asset: asset,
            partialBytes: _partialBytes(staging, asset),
          ),
        );
        return;
      }
      state = state.copyWith(
        phase: UpdateFailed(
          reason: error.failure,
          detail: error.detail,
          release: release,
          asset: asset,
        ),
      );
    } on FileSystemException catch (error) {
      state = state.copyWith(
        phase: UpdateFailed(
          reason: UpdateFailure.storage,
          detail: '$error',
          release: release,
          asset: asset,
        ),
      );
    } finally {
      _cancelToken = null;
    }
  }

  /// Stops the transfer, keeping what has arrived.
  void cancel() {
    _cancelToken?.cancel();
  }

  /// Hands the downloaded APK to the system installer.
  ///
  /// The permission is re-read HERE rather than trusted from the state: the
  /// only way it changes is the user leaving for a Settings screen, and by the
  /// time they come back and press the button the snapshot is the stale one.
  Future<void> install() async {
    final phase = state.phase;
    if (phase is! UpdateReady) return;
    final target = ref.read(apkInstallTargetProvider);
    if (target == null) return;

    if (!await target.canInstallPackages()) {
      state = state.copyWith(
        phase: UpdateReady(
          release: phase.release,
          asset: phase.asset,
          file: phase.file,
          inspection: phase.inspection,
          canInstall: false,
        ),
      );
      return;
    }

    try {
      await target.install(phase.file);
    } on UpdateException catch (error) {
      state = state.copyWith(
        phase: UpdateFailed(
          reason: error.failure,
          detail: error.detail,
          release: phase.release,
          asset: phase.asset,
        ),
      );
    }
  }

  /// Opens the system screen that grants this app permission to install.
  Future<void> openInstallPermissionSettings() async {
    await ref.read(apkInstallTargetProvider)?.openInstallPermissionSettings();
  }

  /// Re-reads the install permission while the app is in the foreground.
  ///
  /// THE HALF THAT WAS MISSING ON THE DEVICE. The permission can only change
  /// while the user is somewhere else — the Settings screen this app just sent
  /// them to — so the state they come back to is always the stale one, and the
  /// sheet kept offering 「去允许安装」 to somebody who had already allowed it.
  /// Tapping it again reopened Settings: a loop with no exit, from the user's
  /// point of view.
  ///
  /// Called when the app is resumed. Cheap and idempotent: it does nothing
  /// unless the answer changed.
  Future<void> refreshInstallPermission() async {
    final phase = state.phase;
    if (phase is! UpdateReady) return;
    final canInstall =
        await ref.read(apkInstallTargetProvider)?.canInstallPackages() ?? false;
    if (canInstall == phase.canInstall) return;
    state = state.copyWith(
      phase: UpdateReady(
        release: phase.release,
        asset: phase.asset,
        file: phase.file,
        inspection: phase.inspection,
        canInstall: canInstall,
      ),
    );
  }

  /// Opens the release page — the answer on platforms that cannot self-install.
  Future<void> openReleasePage() async {
    final release = switch (state.phase) {
      UpdateAvailable(:final release) => release,
      UpdateUpToDate() => null,
      UpdateReady(:final release) => release,
      UpdateDownloading(:final release) => release,
      UpdateFailed(:final release?) => release,
      _ => null,
    };
    final url = release?.htmlUrl ?? '';
    if (url.isEmpty) return;
    await ref.read(apkInstallTargetProvider)?.openUrl(url);
  }

  /// Back to doing nothing, with what was remembered intact.
  void reset() {
    if (_cancelToken != null) return;
    state = state.copyWith(phase: const UpdateIdle());
  }

  Future<void> _remember({required AppVersion? latest, required DateTime at}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (latest == null) {
      await prefs.remove(_kLatest);
    } else {
      await prefs.setString(_kLatest, latest.toString());
    }
    await prefs.setInt(_kCheckedAt, at.millisecondsSinceEpoch);
  }

  /// A complete download from an earlier run, when there is one.
  ///
  /// THE CASE THIS SAVES: the APK arrived, the user never pressed 安装, and the
  /// process was killed — by the system, by a crash, by the user swiping the
  /// app away. Re-downloading 46 MB for that is the phone's data, spent on
  /// bytes that are already on the disk. So a file of exactly the right length
  /// whose hash matches the release's own checksum is adopted instead.
  ///
  /// Only when the checksum IS known. Without one, "the file is the right
  /// length" is not enough to install it, and a wrong file that is the right
  /// length is worse than a fresh download.
  static Future<DownloadedFile?> _reuse(
    Directory staging,
    ReleaseAsset asset,
    String? expected,
  ) async {
    if (expected == null) return null;
    final file = File('${staging.path}/${asset.name}');
    if (!file.existsSync()) return null;
    final bytes = file.lengthSync();
    if (asset.size > 0 && bytes != asset.size) return null;
    final digest = await sha256OfFile(file);
    if (digest != expected) return null;
    return DownloadedFile(file: file, bytes: bytes, sha256: digest);
  }

  static int _partialBytes(Directory staging, ReleaseAsset asset) {
    final part = File('${staging.path}/${asset.name}.part');
    return part.existsSync() ? part.lengthSync() : 0;
  }

  /// The installed app's versionCode, as `PackageInfo` spells it.
  ///
  /// `buildNumber` is a string because it is whatever the platform reported;
  /// a non-numeric one (which this app never builds) is treated as unknown
  /// rather than as zero, because "unknown" skips a check while "zero" makes
  /// every APK look like a downgrade.
  int? installedVersionCode() {
    final info = ref.read(packageInfoProvider).value;
    if (info == null) return null;
    return int.tryParse(info.buildNumber);
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Best effort. The user's next download will overwrite it by name; there
      // is nothing here worth replacing the real error with.
    }
  }
}

/// The three questions the platform answers about a downloaded APK, turned
/// into a refusal or null.
///
/// Ordered by how badly each one fails: an unreadable package, then the wrong
/// app, then a key that cannot upgrade over what is installed, then a version
/// the installer would refuse. The first three are all "this file is not an
/// update of this app".
UpdateFailure? _inspectFailure(
  ApkInspection inspection, {
  required int? installedVersionCode,
}) {
  if (!inspection.readable) return UpdateFailure.badPayload;
  if (inspection.packageName != installedApplicationId) {
    return UpdateFailure.wrongPackage;
  }
  if (!inspection.signatureMatches) return UpdateFailure.signatureMismatch;
  // VersionCode against versionCode, never against a version NAME: the two
  // kinds of number are not comparable, and the installer only refuses on this
  // one. See `docs/research/12-app-update.md` §4.3.
  final code = inspection.versionCode;
  if (installedVersionCode != null && code != null && code < installedVersionCode) {
    return UpdateFailure.versionTooOld;
  }
  return null;
}

/// This app's application id.
///
/// Spelled out rather than read from the platform because it is a constant of
/// the build (`android/app/build.gradle.kts`), and because the comparison above
/// must not depend on a channel call that could itself be the thing that is
/// broken.
const String installedApplicationId = 'dev.maddax.herdrpocket';

final releaseClientProvider = Provider<ReleaseClient>(
  (ref) => ReleaseClient(
    http: ref.watch(updateHttpProvider),
    userAgent: userAgentFor(ref.watch(appVersionProvider)),
  ),
);

final assetDownloaderProvider = Provider<AssetDownloader>(
  (ref) => AssetDownloader(
    http: ref.watch(updateHttpProvider),
    userAgent: userAgentFor(ref.watch(appVersionProvider)),
  ),
);

/// How this app identifies itself to GitHub.
///
/// GitHub rejects a request with no `User-Agent` outright, and the value is
/// also the only way the repository owner finds out who is calling if the API
/// starts behaving oddly.
String userAgentFor(AppVersion? version) =>
    'HerdrPocket/${version ?? 'dev'} (+https://github.com/$updateRepoOwner/$updateRepoName)';

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateStatus>(UpdateController.new);
