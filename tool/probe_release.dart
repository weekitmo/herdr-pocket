// What the updater makes of the REAL GitHub payload.
//
// RUN IT WITH:
//
//     env -u http_proxy -u https_proxy -u all_proxy dart run tool/probe_release.dart [abi] [--download]
//
// `--download` also FETCHES the asset it picked, streamed, and checks it against
// the release's own checksums.txt. That is the one part the phone cannot be
// asked to prove on demand: it only downloads when there is something newer to
// download, so the CDN path — a 302 to `objects.githubusercontent.com` and a
// streamed body behind it — can be years away from its next real exercise.
//
// WHY IT EXISTS. Every unit test of the release picker feeds it a payload this
// repository made up, and a made-up payload agrees with whatever the parser
// believes. This asks the live API and prints what the decision WOULD be — the
// release it picked, the asset it would install, and every release it rejected —
// against the real list, which by now contains an `hdp-v*` release as well.
//
// The `env -u` is not decoration: `dart` picks up the shell's proxy variables
// through `HttpClient.findProxyFromEnvironment`, and a probe whose question is
// "is this payload parsed correctly" should not fail because a proxy happens to
// be down. The phone's own proxy path is a different question, verified on a
// device.
//
// WHY THE FETCH IS HAND-WRITTEN HERE. `ReleaseClient` reaches the network
// through dio, and reads the proxy through a Flutter method channel; neither is
// importable from a plain `dart run`. So this script does the two GETs itself
// and hands the bytes to the REAL parsers — `parseReleases`, `pickAppRelease`,
// `pickApkAsset`, `parseChecksums` — which is where the decisions live and the
// part a fixture cannot stand in for.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';

const String _api =
    'https://api.github.com/repos/weekitmo/herdr-pocket/releases?per_page=20';

Future<void> main(List<String> args) async {
  final download = args.contains('--download');
  final abi = args.where((a) => !a.startsWith('--')).firstOrNull ?? 'arm64-v8a';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  final releases = parseReleases(await _getJson(client, _api));
  stdout.writeln('abi=$abi - ${releases.length} release(s) parsed');

  for (final release in releases) {
    final apks = release.apkAssets.map((a) => a.name).join(', ');
    stdout.writeln(
      '  ${release.tag.padRight(14)} v=${release.version.toString().padRight(8)}'
      ' prerelease=${release.prerelease.toString().padRight(5)}'
      ' apks=[${apks.isEmpty ? 'none' : apks}]',
    );
  }

  final picked = pickAppRelease(releases);
  if (picked == null) {
    stdout.writeln('\nPICK: none - nothing published is a release of this app');
    exit(1);
  }

  final asset = pickApkAsset(picked, abi);
  stdout.writeln('\nPICK: ${picked.tag} (${picked.version})');
  stdout.writeln('  published  ${picked.publishedAt}');
  stdout.writeln('  page       ${picked.htmlUrl}');
  stdout.writeln('  asset      ${asset?.name ?? 'NONE for $abi'}');
  stdout.writeln('  size       ${asset?.size ?? 0} bytes');

  final checksumAsset = picked.assets
      .where((a) => a.name.endsWith('checksums.txt'))
      .firstOrNull;
  if (checksumAsset == null) {
    stdout.writeln('  checksums  the release ships none');
  } else {
    final sums = parseChecksums(await _getText(client, checksumAsset.url));
    final mine = asset == null ? null : sums[asset.name];
    stdout.writeln(
      '  checksums  ${sums.length} line(s); ours = ${mine ?? 'MISSING'}',
    );

    if (download && asset != null) {
      final hash = await _download(client, asset.url);
      final expected = mine;
      final ok = expected == null || expected == hash;
      stdout.writeln('  downloaded $hash');
      stdout.writeln('  ${ok ? 'MATCHES' : 'MISMATCH: expected $expected'}');
      exit(ok ? 0 : 1);
    }
  }
  exit(asset == null ? 1 : 0);
}

/// Streams the asset and returns its SHA-256, without keeping it.
///
/// THE POINT IS THE REDIRECT: the release asset URL answers 302 to
/// `objects.githubusercontent.com`, and a client that does not follow it
/// downloads an HTML page that is the right shape to be mistaken for a file.
Future<String> _download(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set('user-agent', 'HerdrPocket-probe/1.0');
  final response = await request.close();
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode} from $url');
  }
  stdout.writeln(
    '  fetching   ${response.headers.contentLength} bytes, '
    'final host = ${response.redirects.isEmpty ? 'no redirect' : response.redirects.last.location.host}',
  );
  final digest = await sha256.bind(response).first;
  return digest.toString();
}

Future<Object?> _getJson(HttpClient client, String url) async =>
    jsonDecode(await _getText(client, url));

Future<String> _getText(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  // GitHub rejects a request with no User-Agent outright, which is the one
  // header this cannot omit.
  request.headers.set('accept', 'application/vnd.github+json');
  request.headers.set('user-agent', 'HerdrPocket-probe/1.0');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException(
      'HTTP ${response.statusCode} from $url\n$body',
      uri: Uri.parse(url),
    );
  }
  return body;
}
