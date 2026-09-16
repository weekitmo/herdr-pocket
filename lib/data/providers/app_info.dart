import 'dart:ffi' show Abi;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/domain/update/app_version.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The built package's own identity.
///
/// Read from the platform rather than written into the source. A hard-coded
/// version string is a lie the moment anyone forgets to update it, and it is
/// the one number a bug report actually needs — and now also the left-hand side
/// of every update comparison, where being wrong means either nagging forever
/// or never offering an update at all.
///
/// It lives here rather than beside the settings page that first needed it:
/// the update checker needs the same value, and `lib/data` may not import
/// `lib/ui`. The page imports this.
final packageInfoProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);

/// The version the update check compares against, or null until it is known.
///
/// A null here is "not yet", never "nothing": the comparison simply does not
/// happen until the platform answers, which is milliseconds after launch.
final appVersionProvider = Provider<AppVersion?>((ref) {
  final info = ref.watch(packageInfoProvider).value;
  if (info == null) return null;
  return AppVersion.tryParse(info.version);
});

/// The CPU token Android would spell for this build (`arm64-v8a`, …).
///
/// `dart:ffi`'s [Abi] rather than a platform channel: the running process IS
/// the answer, and asking the platform to describe the process it is currently
/// executing would be a round trip to learn something the process already is.
/// The release workflow names its APKs after exactly these tokens, which is why
/// the two spellings have to be mapped by hand — a table of six strings is
/// cheaper than a device with the wrong APK on it.
final deviceAbiProvider = Provider<String>((ref) => abiToken(Abi.current()));

/// Maps a runtime [Abi] to the token used in the release asset names.
///
/// Unknown platforms fall back to `universal`, which is not a guess: the
/// selection in `pickApkAsset` treats it as the second choice, so a build that
/// only ships `-universal.apk` still resolves, and a release that ships only
/// per-ABI files resolves to nothing rather than to the wrong one.
String abiToken(Abi abi) => switch (abi) {
      Abi.androidArm64 => 'arm64-v8a',
      Abi.androidArm => 'armeabi-v7a',
      Abi.androidX64 => 'x86_64',
      Abi.androidIA32 => 'x86',
      Abi.macosArm64 || Abi.macosX64 => 'universal',
      Abi.linuxArm64 || Abi.linuxX64 || Abi.linuxIA32 || Abi.linuxArm => 'universal',
      Abi.windowsArm64 || Abi.windowsX64 || Abi.windowsIA32 => 'universal',
      _ => 'universal',
    };
