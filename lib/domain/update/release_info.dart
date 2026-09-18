import 'package:herdr_pocket/domain/update/app_version.dart';

/// One file attached to a release.
class ReleaseAsset {
  /// Holds one asset.
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.url,
  });

  /// The file name as published, e.g. `HerdrPocket-0.2.0-arm64-v8a.apk`.
  ///
  /// The name is load-bearing: which APK to install is decided by it, because
  /// the workflow names its output after the device's CPU rather than
  /// publishing a manifest that says so.
  final String name;

  /// Size in bytes, or 0 when the API did not report one.
  final int size;

  /// Where to fetch it. GitHub redirects this to its CDN, which is fine and
  /// expected — see `docs/research/12-app-update.md` §4.4.
  final String url;
}

/// A GitHub release, reduced to the fields this app has a use for.
///
/// PARSED FROM THE LIST ENDPOINT, NOT FROM `/releases/latest`, and that is the
/// point of the whole type. The `hdp` CLI publishes into the SAME repository on
/// `hdp-v*` tags, so "the latest release" can be a version of something that
/// has no APK in it at all. [pickAppRelease] is where that is dealt with.
class ReleaseInfo {
  /// Holds one release.
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.assets,
    this.name = '',
    this.body = '',
    this.publishedAt,
    this.htmlUrl = '',
    this.prerelease = false,
  });

  /// The git tag, e.g. `v0.2.0`.
  final String tag;

  /// [tag] parsed. Never null: an unparseable tag is dropped at parse time.
  final AppVersion version;

  /// Everything attached to it.
  final List<ReleaseAsset> assets;

  /// The release title, which the workflow sets to the tag.
  final String name;

  /// The release notes, as markdown.
  ///
  /// Kept as text and shown as text. A markdown renderer would be a dependency
  /// and a design language of its own for a body that is generated release
  /// notes — the version number and the one line saying what changed are what
  /// a user actually reads.
  final String body;

  /// When it was published, or null when the API omitted it.
  final DateTime? publishedAt;

  /// The page a human would open, for the "there is no Android installer here"
  /// path.
  final String htmlUrl;

  /// Whether GitHub marks it as a prerelease.
  final bool prerelease;

  /// The `.apk` files among [assets], in the order published.
  List<ReleaseAsset> get apkAssets => [
        for (final asset in assets)
          if (asset.name.toLowerCase().endsWith('.apk')) asset,
      ];

  @override
  String toString() => 'ReleaseInfo($tag, ${assets.length} assets)';
}

/// Parses the JSON body of `GET /repos/{owner}/{repo}/releases`.
///
/// FAIL-SOFT BY DROPPING, NEVER BY GUESSING. An entry with no tag, no assets,
/// or a tag that is not a version is skipped. The consequence of skipping is
/// "this release is not offered", which is the safe direction; the consequence
/// of guessing is offering a download that cannot be installed.
///
/// Drafts are skipped as well, even though an unauthenticated request never
/// sees them — the day someone runs this with a token, the behaviour must not
/// change.
List<ReleaseInfo> parseReleases(Object? payload) {
  if (payload is! List) return const [];

  final parsed = <ReleaseInfo>[];
  for (final entry in payload) {
    if (entry is! Map) continue;
    if (entry['draft'] == true) continue;

    final tag = entry['tag_name'];
    if (tag is! String) continue;
    final version = AppVersion.tryParse(tag);
    if (version == null) continue;

    final assets = <ReleaseAsset>[];
    final rawAssets = entry['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map) continue;
        final name = raw['name'];
        final url = raw['browser_download_url'];
        if (name is! String || url is! String) continue;
        assets.add(
          ReleaseAsset(
            name: name,
            size: switch (raw['size']) {
              final num size => size.toInt(),
              _ => 0,
            },
            url: url,
          ),
        );
      }
    }

    parsed.add(
      ReleaseInfo(
        tag: tag,
        version: version,
        assets: assets,
        name: switch (entry['name']) {
          final String name => name,
          _ => '',
        },
        body: switch (entry['body']) {
          final String body => body,
          _ => '',
        },
        publishedAt: switch (entry['published_at']) {
          final String raw => DateTime.tryParse(raw),
          _ => null,
        },
        htmlUrl: switch (entry['html_url']) {
          final String url => url,
          _ => '',
        },
        prerelease: entry['prerelease'] == true,
      ),
    );
  }
  return parsed;
}

/// The newest release that ships a version of THIS app.
///
/// Three filters, and each one is there because of a specific way this
/// repository publishes:
///
///   1. **A parseable `v<semver>` tag.** `hdp-v1.2.3` does not parse, so the
///      CLI's releases fall out here.
///   2. **At least one `.apk`.** A hypothetical `v*` tag that only ships the
///      macOS disk image is a real release of this app and still not something
///      an Android phone can install.
///   3. **Not a prerelease.** `releases/latest` on GitHub has the same rule,
///      and the reason is the same: a version the author marked "not finished"
///      is not one to push at everyone on launch.
///
/// Returns null when nothing qualifies, which the UI reports as "no release
/// found" rather than as "up to date" — those are different sentences and only
/// one of them is true.
ReleaseInfo? pickAppRelease(Iterable<ReleaseInfo> releases) {
  ReleaseInfo? best;
  for (final release in releases) {
    if (release.prerelease) continue;
    if (release.apkAssets.isEmpty) continue;
    if (best == null || release.version.isNewerThan(best.version)) {
      best = release;
    }
  }
  return best;
}

/// Picks the APK to install on a device whose CPU reports [abi].
///
/// [abi] is the token as Android spells it (`arm64-v8a`, `armeabi-v7a`,
/// `x86_64`), which is also how the workflow spells it in the file name —
/// `HerdrPocket-<version>-<abi>.apk`. So the match is a suffix match on the
/// name, and the version in the middle is never reconstructed: a name built
/// from the version would break the day a tag has a suffix the tag parser
/// tolerates and the file namer does not.
///
/// Order: exact ABI, then `universal`, then the only APK if there is exactly
/// one. Null when the choice is not obvious, because installing the wrong ABI
/// fails at install time with a message about the package being invalid.
///
/// The `universal` step is KEPT although the release workflow stopped shipping
/// that file on 2026-09-18: it costs nothing, it still resolves against the
/// releases that do have one (v0.3.3 and older, which an update can come from),
/// and a build that ships a single fat APK remains installable. What changed is
/// only that a device with no matching token is now told there is no build for
/// it rather than handed a 107 MB file — which is what the last step is for.
ReleaseAsset? pickApkAsset(ReleaseInfo release, String abi) {
  final apks = release.apkAssets;
  if (apks.isEmpty) return null;

  final suffix = '-${abi.toLowerCase()}.apk';
  final exact = [
    for (final asset in apks)
      if (asset.name.toLowerCase().endsWith(suffix)) asset,
  ];
  if (exact.length == 1) return exact.first;

  final universal = [
    for (final asset in apks)
      if (asset.name.toLowerCase().endsWith('-universal.apk')) asset,
  ];
  if (universal.length == 1) return universal.first;

  return apks.length == 1 ? apks.first : null;
}

/// Reads a `checksums.txt` in the `<sha256>  <filename>` shape.
///
/// That shape is what `sha256sum` writes and what `sha256sum -c` reads, so it
/// is the format the release workflow produces — parsing anything else would be
/// inventing a second format for the same fact. Lines that do not fit are
/// skipped: a checksum file this app cannot read means "no checksum available",
/// not "the download is bad".
Map<String, String> parseChecksums(String text) {
  final byName = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(trimmed);
    if (match == null) continue;
    byName[match.group(2)!.trim()] = match.group(1)!.toLowerCase();
  }
  return byName;
}
