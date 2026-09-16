import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/update/update_exception.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';

/// What the platform can say about a downloaded APK before it is installed.
///
/// WHY THIS EXISTS AT ALL. Installing an APK whose signing key differs from the
/// installed app's fails with one flat sentence — "应用未安装" — and the only
/// remedy is to uninstall first, WHICH DELETES THE USER'S SAVED MACHINES AND
/// SSH CREDENTIALS. A user who builds this app locally (debug key) and also
/// installs the released APK (release key) walks into exactly that, and it is
/// not discoverable from inside the installer. Asking the platform three
/// questions beforehand is what turns that into a sentence that explains it.
class ApkInspection {
  /// Holds one reading.
  const ApkInspection({
    required this.packageName,
    required this.versionCode,
    required this.signatureMatches,
    this.readable = true,
  });

  /// A file the platform could not parse as a package at all.
  static const ApkInspection unreadable = ApkInspection(
    packageName: null,
    versionCode: null,
    signatureMatches: false,
    readable: false,
  );

  /// The application id inside the APK, or null when it could not be read.
  final String? packageName;

  /// The APK's own versionCode, or null.
  ///
  /// NOT comparable with the release *version*: CI stamps the run number here
  /// and a local build stamps `+1`. It is only ever compared with the installed
  /// app's versionCode, which is the same kind of number.
  final int? versionCode;

  /// Whether the APK is signed by every signer of the installed app.
  final bool signatureMatches;

  /// Whether the file was a package at all.
  final bool readable;

  /// Reads the platform channel's payload.
  static ApkInspection fromChannel(Object? raw) {
    if (raw is! Map) return unreadable;
    return ApkInspection(
      packageName: switch (raw['packageName']) {
        final String name => name,
        _ => null,
      },
      versionCode: switch (raw['versionCode']) {
        final num code => code.toInt(),
        _ => null,
      },
      signatureMatches: raw['signatureMatches'] == true,
      readable: raw['readable'] == true,
    );
  }
}

/// The Android half of installing an update.
///
/// An interface so the download-and-verify logic above it can be tested with no
/// device — a platform channel cannot run under `flutter test`, and the
/// interesting part of this feature is the decisions, not the intents.
abstract interface class ApkInstallTarget {
  /// Where downloaded APKs are staged, or null when the platform has no such
  /// place (everything that is not Android, today).
  Future<Directory?> stagingDirectory();

  /// Whether the system will let this app hand an APK to the installer.
  ///
  /// Android 8+ per-app "install unknown apps": the switch the user has to
  /// find once, in a screen that has nothing to do with this app.
  Future<bool> canInstallPackages();

  /// Opens that screen, on this app's row.
  Future<void> openInstallPermissionSettings();

  /// Reads [apk] without installing it.
  Future<ApkInspection> inspect(File apk);

  /// Hands [apk] to the system installer, which asks the user to confirm.
  ///
  /// There is no silent path on Android without device-owner or root, so the
  /// wording everywhere around this call is "安装"，never "更新完成".
  Future<void> install(File apk);

  /// Opens a URL in the browser — the escape hatch for platforms that cannot
  /// install an update themselves.
  Future<void> openUrl(String url);
}

/// The Android implementation, over a hand-written method channel.
///
/// The three things it does — FileProvider, `canRequestPackageInstalls`, and
/// reading an APK's signature — have no maintained package between them, and
/// the signature check needs Kotlin regardless, so the rest is written beside
/// it rather than pulling in a wrapper. See `docs/research/12-app-update.md` §2.
class PlatformApkInstallTarget implements ApkInstallTarget {
  /// Holds the channel.
  const PlatformApkInstallTarget({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `UPDATE_CHANNEL` in MainActivity.kt.
  static const String channelName = 'dev.maddax.herdrpocket/app_update';

  final MethodChannel? _channel;

  MethodChannel get _channelOrThrow =>
      _channel ?? const MethodChannel(channelName);

  @override
  Future<Directory?> stagingDirectory() async {
    final path = await _invoke<String>('stagingDirectory', const {});
    if (path == null || path.isEmpty) return null;
    return Directory(path);
  }

  @override
  Future<bool> canInstallPackages() async =>
      await _invoke<bool>('canInstall', const {}) ?? false;

  @override
  Future<void> openInstallPermissionSettings() async {
    await _invoke<void>('openInstallSettings', const {});
  }

  @override
  Future<ApkInspection> inspect(File apk) async {
    final raw = await _invoke<Object?>('inspect', {'path': apk.path});
    return ApkInspection.fromChannel(raw);
  }

  @override
  Future<void> install(File apk) async {
    await _invoke<void>('install', {'path': apk.path});
  }

  @override
  Future<void> openUrl(String url) async {
    await _invoke<void>('openUrl', {'url': url});
  }

  /// Calls the platform, turning its failures into [UpdateException].
  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channelOrThrow.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw UpdateException(
        switch (e.code) {
          'install_blocked' => UpdateFailure.installBlocked,
          'file_missing' => UpdateFailure.storage,
          _ => UpdateFailure.unknown,
        },
        detail: '${e.code}: ${e.message}',
      );
    } on MissingPluginException catch (e) {
      throw UpdateException(UpdateFailure.unknown, detail: '$e');
    }
  }
}

/// The install target for this platform, or null when there is none.
///
/// Null is a real answer rather than a loading state, matching
/// `downloadTargetProvider`: on a platform with no installer to hand a file to,
/// the honest update path is "here is the release page".
final apkInstallTargetProvider = Provider<ApkInstallTarget?>((ref) {
  if (!Platform.isAndroid) return null;
  return const PlatformApkInstallTarget();
});
