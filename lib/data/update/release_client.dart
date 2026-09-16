import 'package:dio/dio.dart';
import 'package:herdr_pocket/data/update/update_exception.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/update/release_info.dart';

/// Talks to the GitHub Releases API for this app's repository.
///
/// TWO THINGS THIS CLASS IS RESPONSIBLE FOR BEYOND FETCHING. The proxy is
/// re-read before every request (the user may have just fixed their proxy and
/// tapped retry), and every dio failure is turned into an [UpdateException] so
/// no caller has to look at a message.
class ReleaseClient {
  /// Holds the client and the identity it reports to GitHub.
  ReleaseClient({required this.http, required this.userAgent});

  /// Sent as `User-Agent`.
  ///
  /// NOT OPTIONAL. GitHub's REST API rejects requests without one — "Requests
  /// with no User-Agent header will be rejected" — and it is also how the
  /// maintainer of the API finds out who is calling if something goes wrong.
  final String userAgent;

  /// The HTTP client, pointed at whatever proxy is configured.
  final UpdateHttp http;

  /// Every release this repository publishes, newest first.
  ///
  /// The list endpoint rather than `/latest`, because `latest` is decided by
  /// GitHub without knowing that half this repository's releases are a CLI with
  /// no APK in them. See `pickAppRelease`.
  Future<List<ReleaseInfo>> releases() async {
    await http.resolver.refresh();
    final response = await _get<Object?>(
      '/repos/$updateRepoOwner/$updateRepoName/releases',
      queryParameters: const {'per_page': 20},
      options: Options(responseType: ResponseType.json),
    );
    if (response.statusCode != 200) {
      throw UpdateException(
        _statusFailure(response.statusCode),
        detail: 'GET /releases → HTTP ${response.statusCode}',
      );
    }
    final parsed = parseReleases(response.data);
    if (parsed.isEmpty && response.data is! List) {
      // A 200 that is not a list is a captive portal or a proxy login page —
      // not an empty repository. Saying so is the difference between "check
      // your network" and "there are no releases".
      throw const UpdateException(
        UpdateFailure.badPayload,
        detail: 'expected a JSON array of releases',
      );
    }
    return parsed;
  }

  /// The release's `checksums.txt`, as `filename -> sha256`.
  ///
  /// An empty map means "no checksum available", which is a state the caller
  /// handles by skipping the check rather than by failing: a release without
  /// the file is still installable, and the signature check is the one that
  /// protects the user.
  Future<Map<String, String>> checksums(ReleaseInfo release) async {
    final asset = release.assets
        .where((a) => a.name.toLowerCase().endsWith('checksums.txt'))
        .firstOrNull;
    if (asset == null) return const {};

    // A FAILURE HERE MUST NOT FAIL THE UPDATE. This is a second opinion on a
    // file that already arrived over TLS from the same release, and a release
    // that ships no `checksums.txt` answers 404 — which, left unhandled, threw
    // out of `download()` and was reported as "this release does not exist".
    // Found by a test that expected a signature failure and got a 404.
    try {
      final response = await _get<Object?>(
        asset.url,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode != 200) return const {};
      final text = response.data;
      return text is String ? parseChecksums(text) : const {};
    } on UpdateException {
      return const {};
    }
  }

  /// Sends one request through the proxy that is configured right now.
  Future<Response<T>> _get<T>(
    String url, {
    required Options options,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    final proxied = http.resolver.current?.isUsable ?? false;
    try {
      return await http.dio.get<T>(
        url,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options.copyWith(
          headers: {...options.headers ?? const {}, 'user-agent': userAgent},
        ),
      );
    } on DioException catch (error) {
      throw classifyDio(error, proxied: proxied);
    }
  }
}

UpdateFailure _statusFailure(int? status) => switch (status) {
      403 || 429 => UpdateFailure.rateLimited,
      404 => UpdateFailure.noRelease,
      _ => UpdateFailure.httpStatus,
    };
