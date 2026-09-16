/// A version number, in the shape this project publishes.
///
/// SEMVER ENOUGH, AND NOT A SEMVER LIBRARY. `0.2.0`, `0.2.0-rc.1` and
/// `0.2.0+7` are the only shapes that can appear here: the app's version comes
/// from `pubspec.yaml` through `flutter build --build-name`, and the far side's
/// comes from a git tag written by hand or by the release workflow. A full
/// semver implementation would carry rules about build metadata that this
/// comparison has no use for.
///
/// TWO DELIBERATE SIMPLIFICATIONS, both of which have to be visible at the call
/// site rather than buried:
///
///   * **`+build` is dropped.** `0.1.0+1` and `0.1.0+42` compare EQUAL. They
///     have to: CI stamps `--build-number=$GITHUB_RUN_NUMBER` while a local
///     build stamps `+1`, so the two numbers are not on the same axis and
///     comparing them would invent updates that do not exist. See
///     `docs/research/12-app-update.md` §4.3.
///   * **Only `x.y.z` parses.** Two components, four components, or a date all
///     return null, and a null version is dropped by the release picker. A tag
///     this app cannot rank is a tag this app must not offer.
class AppVersion implements Comparable<AppVersion> {
  /// Holds one parsed version.
  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.prerelease,
  });

  /// The first number.
  final int major;

  /// The second.
  final int minor;

  /// The third.
  final int patch;

  /// The `rc.1` in `0.2.0-rc.1`, or null for a finished release.
  ///
  /// Kept as the raw text rather than parsed into identifiers: comparing two
  /// prereleases is not a thing this app ever asks, and the ONE decision that
  /// matters — "is `0.2.0-rc.1` older than `0.2.0`" — is answered by the
  /// presence of this field, not by its contents.
  final String? prerelease;

  /// Parses a tag or a version name. Null when it is neither.
  ///
  /// Accepts a leading `v` because that is how the release workflow tags
  /// (`v0.1.0`) while `PackageInfo` reports `0.1.0` — the two sides of the
  /// comparison come from different conventions and this is the one place that
  /// knows it.
  static AppVersion? tryParse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);

    // Build metadata is stripped, not compared — see the class doc.
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);

    final dash = text.indexOf('-');
    final core = dash >= 0 ? text.substring(0, dash) : text;
    final pre = dash >= 0 ? text.substring(dash + 1) : null;
    if (pre != null && pre.isEmpty) return null;

    final parts = core.split('.');
    if (parts.length != 3) return null;

    final numbers = <int>[];
    for (final part in parts) {
      // `int.tryParse` accepts a leading `+`/`-` and whitespace, and `1e3` is
      // not a version component. Digits only, spelled out.
      if (part.isEmpty || !_digits.hasMatch(part)) return null;
      numbers.add(int.parse(part));
    }

    return AppVersion(
      major: numbers[0],
      minor: numbers[1],
      patch: numbers[2],
      prerelease: pre,
    );
  }

  static final RegExp _digits = RegExp(r'^\d+$');

  /// Whether this version is strictly newer than [other].
  ///
  /// Spelled as a method rather than an operator on purpose: this is the one
  /// comparison the whole feature turns on, and `release.version > current`
  /// reads like a numeric comparison while being a three-field one.
  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    final major = this.major.compareTo(other.major);
    if (major != 0) return major;
    final minor = this.minor.compareTo(other.minor);
    if (minor != 0) return minor;
    final patch = this.patch.compareTo(other.patch);
    if (patch != 0) return patch;
    // A release outranks its own prereleases: `0.2.0-rc.1 < 0.2.0`.
    if (prerelease == null && other.prerelease == null) return 0;
    if (prerelease == null) return 1;
    if (other.prerelease == null) return -1;
    return prerelease!.compareTo(other.prerelease!);
  }

  @override
  String toString() =>
      '$major.$minor.$patch${prerelease == null ? '' : '-$prerelease'}';

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.prerelease == prerelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);
}
