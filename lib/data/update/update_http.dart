import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/domain/update/system_proxy.dart';

/// Reads the phone's HTTP proxy settings.
///
/// An interface rather than a bare channel so the resolution logic above it can
/// be tested without a device — same reasoning as `DownloadTarget`.
abstract interface class SystemProxySource {
  /// The current settings, or null when the platform has none to report (which
  /// includes every platform that is not Android).
  Future<SystemProxy?> read();
}

/// The Android implementation, over a hand-written method channel.
///
/// The platform reports its proxy through `ConnectivityManager`, which needs
/// `ACCESS_NETWORK_STATE` — a normal permission, so no prompt. See
/// `MainActivity.kt` and `docs/research/12-app-update.md` §3.2.
class PlatformSystemProxySource implements SystemProxySource {
  /// Holds the channel.
  const PlatformSystemProxySource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `PROXY_CHANNEL` in MainActivity.kt.
  static const String channelName = 'dev.maddax.herdrpocket/system_proxy';

  final MethodChannel? _channel;

  @override
  Future<SystemProxy?> read() async {
    try {
      final raw = await (_channel ?? const MethodChannel(channelName))
          .invokeMethod<Object?>('getProxy');
      return SystemProxy.fromChannel(raw);
    } on MissingPluginException {
      // Desktop and iOS: no channel, so no platform proxy. `dart:io` would read
      // `http_proxy` here if it were set, which is the desktop answer and is
      // handled by [ProxyResolver] falling back to the environment.
      return _fromEnvironment();
    } on PlatformException {
      return _fromEnvironment();
    }
  }

  static SystemProxy? _fromEnvironment() {
    final env = Platform.environment;
    final raw = env['https_proxy'] ?? env['HTTPS_PROXY'] ?? env['http_proxy'] ?? env['HTTP_PROXY'];
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    if (uri == null || uri.host.isEmpty || uri.port == 0) return null;
    return SystemProxy(host: uri.host, port: uri.port);
  }
}

/// Holds the last reading of the system proxy.
///
/// `HttpClient.findProxy` is SYNCHRONOUS — it is called from the socket layer
/// with a URL and must answer immediately — while reading the platform's proxy
/// is asynchronous. This is the adapter: [refresh] is awaited once per operation
/// (a check, a download), and [ruleFor] is the sync callback that reads the
/// cached value.
///
/// Deliberately not a stream or a watcher: a proxy that changes between two
/// taps is picked up by the next tap, and a long download that outlives a
/// network change is going to fail anyway.
class ProxyResolver {
  /// Holds the source and the cache.
  ProxyResolver({required this.source});

  /// Where readings come from.
  final SystemProxySource source;
  SystemProxy? _current;

  /// The last reading, for the UI's "your proxy is …" line.
  SystemProxy? get current => _current;

  /// Re-reads the platform's settings and returns them.
  Future<SystemProxy?> refresh() async {
    final read = await source.read();
    _current = read;
    return read;
  }

  /// The PAC-format rule dart:io wants for one URL.
  String ruleFor(Uri url) => proxyRuleFor(url, _current);
}

/// Where the update check reaches the internet from.
///
/// One object holding the [Dio] and the [ProxyResolver] that feeds it, because
/// they are two halves of one thing: a client that can be pointed at a proxy is
/// useless without the reading that points it.
class UpdateHttp {
  /// Builds the client. Tests pass their own [dio] and [proxy].
  UpdateHttp({required this.resolver, Dio? dio})
      : dio = dio ?? _buildDio(resolver);

  /// The configured client.
  final Dio dio;

  /// The proxy the client is pointed at.
  final ProxyResolver resolver;

  static Dio _buildDio(ProxyResolver resolver) {
    final dio = Dio(
      BaseOptions(
        baseUrl: updateApiBase,
        // The clock starts before the TCP connection and stops at the first
        // byte — a proxy that accepts a connection and then says nothing is
        // caught here, which is the single most common way a wrong proxy port
        // behaves.
        connectTimeout: const Duration(seconds: 20),
        // dio measures this BETWEEN byte events, so it is a stall detector
        // rather than a cap on a file that is legitimately slow: 60 seconds
        // with no progress at all. A total-duration cap on a 46 MB download
        // would fail the users this feature exists for.
        receiveTimeout: const Duration(seconds: 60),
        // 3xx is followed by dart:io itself; 4xx/5xx are NOT thrown here so the
        // caller can classify them (403 means something specific on GitHub).
        validateStatus: (_) => true,
        headers: const {'accept': 'application/vnd.github+json'},
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // THE LINE THIS WHOLE FILE EXISTS FOR. Left unset, dart:io opens a
        // direct connection and every proxy the user configured is bypassed —
        // silently, with a download that is merely slow.
        client.findProxy = resolver.ruleFor;
        client.connectionTimeout = const Duration(seconds: 20);
        return client;
      },
    );
    return dio;
  }
}

/// Which GitHub API to ask.
///
/// `https://api.github.com` in every build the user sees. The override exists
/// for tests — the download and install paths are verified against a local
/// server that serves a real APK, and a hard-coded host is the one thing that
/// would make that impossible.
const String updateApiBase = String.fromEnvironment(
  'HERDR_UPDATE_API_BASE',
  defaultValue: 'https://api.github.com',
);

/// Which repository publishes this app.
const String updateRepoOwner = 'weekitmo';
const String updateRepoName = 'herdr-pocket';

final systemProxySourceProvider = Provider<SystemProxySource>(
  (ref) => const PlatformSystemProxySource(),
);

final updateHttpProvider = Provider<UpdateHttp>(
  (ref) =>
      UpdateHttp(resolver: ProxyResolver(source: ref.watch(systemProxySourceProvider))),
);
