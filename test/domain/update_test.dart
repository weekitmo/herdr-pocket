import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/update/app_version.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';
import 'package:herdr_pocket/domain/update/system_proxy.dart';

/// The pure half of the updater: what counts as a newer version, which release
/// counts as this app's, which file to install, and where the traffic goes.
///
/// Every case here is a decision that is invisible when it is wrong. A version
/// comparison that is off by one asks the user to "update" to what they already
/// have; a release picker that trusts `latest` offers a CLI release with no APK
/// in it; a proxy rule that forgets an exclusion sends loopback traffic through
/// a proxy that is not listening.
void main() {
  group('AppVersion', () {
    test('reads the shapes this project publishes', () {
      final parsed = AppVersion.tryParse('v0.2.0');
      expect(parsed, const AppVersion(major: 0, minor: 2, patch: 0));
      expect(parsed.toString(), '0.2.0');
      expect(AppVersion.tryParse('1.10.3')!.minor, 10);
      expect(
        AppVersion.tryParse('0.2.0-rc.1')!.prerelease,
        'rc.1',
      );
    });

    test('refuses anything it cannot rank', () {
      // `hdp-v1.2.3` IS A REAL TAG IN THIS REPOSITORY, and the reason this
      // returns null rather than something clever: a tag this app cannot rank
      // is a tag it must not offer.
      for (final raw in ['hdp-v1.2.3', 'v1.0', '1.0.0.0', 'v', '', 'nightly', 'v1.x.0']) {
        expect(AppVersion.tryParse(raw), isNull, reason: raw);
      }
    });

    test('ignores build metadata, because the two sides are stamped differently', () {
      // pubspec says `0.1.0+1`; CI stamps `--build-number=$GITHUB_RUN_NUMBER`.
      // Comparing those numbers would invent updates that do not exist.
      expect(AppVersion.tryParse('0.1.0+1'), AppVersion.tryParse('0.1.0+42'));
      expect(
        AppVersion.tryParse('0.1.0+9')!.compareTo(AppVersion.tryParse('0.1.0')!),
        0,
      );
    });

    test('orders a release above its own prerelease', () {
      final candidate = AppVersion.tryParse('0.2.0-rc.1')!;
      final release = AppVersion.tryParse('0.2.0')!;
      expect(release.isNewerThan(candidate), isTrue);
      expect(candidate.isNewerThan(release), isFalse);
      expect(
        AppVersion.tryParse('0.2.0-beta')!.isNewerThan(
          AppVersion.tryParse('0.2.0-rc.1')!,
        ),
        isFalse,
      );
    });

    test('compares field by field, not as a string', () {
      expect(
        AppVersion.tryParse('0.10.0')!.isNewerThan(AppVersion.tryParse('0.9.9')!),
        isTrue,
      );
      expect(
        AppVersion.tryParse('1.0.0')!.isNewerThan(AppVersion.tryParse('0.99.99')!),
        isTrue,
      );
    });
  });

  group('parseReleases', () {
    test('keeps what it can rank and drops what it cannot', () {
      final releases = parseReleases([
        _release('v0.2.0'),
        // The CLI's releases share this repository's release list.
        _release('hdp-v1.2.3'),
        _release('v0.3.0', draft: true),
        {'no': 'tag'},
        'not an object',
      ]);
      expect(releases.map((r) => r.tag), ['v0.2.0']);
    });

    test('reads the fields the sheet shows', () {
      final release = parseReleases([
        _release(
          'v0.2.0',
          body: 'What changed',
          publishedAt: '2026-09-16T05:49:17Z',
          htmlUrl: 'https://github.com/weekitmo/herdr-pocket/releases/tag/v0.2.0',
        ),
      ]).single;

      expect(release.version, AppVersion.tryParse('0.2.0'));
      expect(release.body, 'What changed');
      expect(release.publishedAt, DateTime.utc(2026, 9, 16, 5, 49, 17));
      expect(release.htmlUrl, endsWith('/v0.2.0'));
      expect(release.apkAssets.map((a) => a.name), [
        'HerdrPocket-0.2.0-arm64-v8a.apk',
        'HerdrPocket-0.2.0-armeabi-v7a.apk',
        'HerdrPocket-0.2.0-universal.apk',
      ]);
    });

    test('survives a payload that is not a list at all', () {
      expect(parseReleases(null), isEmpty);
      expect(parseReleases('a captive portal login page'), isEmpty);
    });
  });

  group('pickAppRelease', () {
    test('never offers a CLI release, even when it is the newest thing there', () {
      // THE TRAP THIS FUNCTION EXISTS FOR. `/releases/latest` would return the
      // hdp release, and the user would be told to update to a version of
      // something that has no APK in it.
      final picked = pickAppRelease(
        parseReleases([
          _release('hdp-v9.9.9', assets: const ['hdp-linux-amd64']),
          _release('v0.2.0'),
        ]),
      );
      expect(picked!.tag, 'v0.2.0');
    });

    test('skips a v* release that ships no APK', () {
      final picked = pickAppRelease(
        parseReleases([
          _release('v0.3.0', assets: const ['HerdrPocket-0.3.0-macos.dmg']),
          _release('v0.2.0'),
        ]),
      );
      expect(picked!.tag, 'v0.2.0');
    });

    test('skips a prerelease even when it is the newest', () {
      final picked = pickAppRelease(
        parseReleases([
          _release('v0.3.0-rc.1', prerelease: true),
          _release('v0.2.0'),
        ]),
      );
      expect(picked!.tag, 'v0.2.0');
    });

    test('answers null rather than "up to date" when nothing qualifies', () {
      expect(pickAppRelease(parseReleases([_release('hdp-v1.0.0')])), isNull);
      expect(pickAppRelease(const []), isNull);
    });
  });

  group('pickApkAsset', () {
    final release = parseReleases([_release('v0.2.0')]).single;

    test('takes the build for this CPU when there is one', () {
      expect(pickApkAsset(release, 'arm64-v8a')!.name, 'HerdrPocket-0.2.0-arm64-v8a.apk');
      expect(pickApkAsset(release, 'armeabi-v7a')!.name, 'HerdrPocket-0.2.0-armeabi-v7a.apk');
    });

    test('falls back to the universal build for a CPU it does not have', () {
      expect(pickApkAsset(release, 'x86_64')!.name, 'HerdrPocket-0.2.0-universal.apk');
    });

    test('takes the only APK when that is all the release has', () {
      final single = parseReleases([
        _release('v0.2.0', assets: const ['HerdrPocket-0.2.0-arm64-v8a.apk']),
      ]).single;
      expect(pickApkAsset(single, 'x86_64')!.name, endsWith('arm64-v8a.apk'));
    });

    test('refuses to guess when there is no universal build and no match', () {
      final mixed = parseReleases([
        _release(
          'v0.2.0',
          assets: const [
            'HerdrPocket-0.2.0-arm64-v8a.apk',
            'HerdrPocket-0.2.0-armeabi-v7a.apk',
          ],
        ),
      ]).single;
      // Installing the wrong ABI fails at install time with a message about the
      // package being invalid; no answer is better than the wrong one.
      expect(pickApkAsset(mixed, 'x86_64'), isNull);
    });
  });

  group('parseChecksums', () {
    test('reads the sha256sum shape, with or without the binary marker', () {
      final text = [
        '${'a' * 64}  *HerdrPocket-0.2.0-macos.dmg',
        '${'b' * 64}  HerdrPocket-0.2.0-arm64-v8a.apk',
      ].join('\n');
      final parsed = parseChecksums(text);
      expect(parsed['HerdrPocket-0.2.0-macos.dmg'], 'a' * 64);
      expect(parsed['HerdrPocket-0.2.0-arm64-v8a.apk'], 'b' * 64);
    });

    test('an unreadable line means "no checksum", not "bad download"', () {
      expect(parseChecksums('# a comment\nnot a checksum\n'), isEmpty);
    });
  });

  group('SystemProxy', () {
    test('reads the platform payload', () {
      final proxy = SystemProxy.fromChannel({
        'host': '127.0.0.1',
        'port': 7890,
        'pacUrl': '',
        'exclusions': ['example.com', ''],
      })!;
      expect(proxy.isUsable, isTrue);
      expect(proxy.pacUrl, isNull);
      expect(proxy.exclusions, ['example.com']);
    });

    test('a PAC-only configuration is reported, not silently ignored', () {
      final proxy = SystemProxy.fromChannel({
        'host': '',
        'port': -1,
        'pacUrl': 'http://wpad/wpad.dat',
      })!;
      // Dart cannot execute a PAC script, so this is a proxy the app cannot
      // use — and the honest thing is to know that and say so.
      expect(proxy.isUsable, isFalse);
      expect(proxy.pacUrl, 'http://wpad/wpad.dat');
    });

    test('never sends loopback through a proxy', () {
      const proxy = SystemProxy(host: '10.0.0.1', port: 7890);
      expect(proxy.bypasses('localhost'), isTrue);
      expect(proxy.bypasses('127.0.0.1'), isTrue);
      expect(proxy.bypasses('api.github.com'), isFalse);
    });

    test('honours an exclusion as an exact host, a suffix, or a pattern', () {
      const proxy = SystemProxy(
        host: '10.0.0.1',
        port: 7890,
        // The last one is a regular expression, which is one of the three
        // shapes a bypass rule can take.
        exclusions: ['internal.example', '.corp.example', r'.*\.lan'],
      );
      expect(proxy.bypasses('internal.example'), isTrue);
      expect(proxy.bypasses('wiki.corp.example'), isTrue);
      expect(proxy.bypasses('printer.lan'), isTrue);
      expect(proxy.bypasses('api.github.com'), isFalse);
    });

    test('the rule dart:io is handed is a proxy rule or DIRECT', () {
      const proxy = SystemProxy(host: '10.0.0.1', port: 7890);
      expect(
        proxyRuleFor(Uri.parse('https://api.github.com/repos'), proxy),
        'PROXY 10.0.0.1:7890',
      );
      expect(
        proxyRuleFor(Uri.parse('http://localhost:2223/'), proxy),
        'DIRECT',
      );
      expect(proxyRuleFor(Uri.parse('https://api.github.com/'), null), 'DIRECT');
      // A PAC-only reading cannot be honoured — Dart has no PAC interpreter —
      // so the request goes direct and the UI is the thing that explains it.
      const pacOnly = SystemProxy(host: '', port: -1, pacUrl: 'http://wpad/x');
      expect(proxyRuleFor(Uri.parse('https://api.github.com/'), pacOnly), 'DIRECT');
    });
  });
}

/// One release document in the shape the GitHub API returns.
Map<String, Object?> _release(
  String tag, {
  List<String>? assets,
  bool draft = false,
  bool prerelease = false,
  String body = '',
  String? publishedAt,
  String? htmlUrl,
}) => {
      'tag_name': tag,
      'name': tag,
      'body': body,
      'draft': draft,
      'prerelease': prerelease,
      'published_at': publishedAt ?? '2026-09-16T00:00:00Z',
      'html_url': htmlUrl ?? 'https://github.com/weekitmo/herdr-pocket/releases/tag/$tag',
      'assets': [
        for (final name in assets ??
            const [
              'HerdrPocket-0.2.0-arm64-v8a.apk',
              'HerdrPocket-0.2.0-armeabi-v7a.apk',
              'HerdrPocket-0.2.0-universal.apk',
            ])
          {
            'name': name,
            'size': 46,
            'browser_download_url': 'https://example.test/$name',
          },
      ],
    };
