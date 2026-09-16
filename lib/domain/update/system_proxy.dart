/// The phone's HTTP proxy, as the system reports it.
///
/// WHY THIS TYPE EXISTS AT ALL. `dart:io` does not read the platform's proxy
/// configuration: `HttpClient` uses a direct connection unless
/// `HttpClient.findProxy` is set, and the environment-variable fallback
/// (`findProxyFromEnvironment`) reads `Platform.environment`, which on Android
/// has no `http_proxy` in it. So a phone with a proxy configured — the normal
/// thing on a network where GitHub is slow — downloads straight past it. This
/// is the value that gets carried across from the platform to that callback.
///
/// NOT A SETTING. There is deliberately no in-app proxy field: the proxy is the
/// system's business, and a second place to configure it is a second place to
/// be wrong. See `docs/research/12-app-update.md` §3 for the three shapes a
/// proxy can take on Android and which of them this can even see.
class SystemProxy {
  /// Holds one reading of the system's proxy settings.
  const SystemProxy({
    required this.host,
    required this.port,
    this.pacUrl,
    this.exclusions = const <String>[],
  });

  /// The proxy host, or `''` when the system has none.
  final String host;

  /// The proxy port, or `0`/negative when the system has none.
  final int port;

  /// The PAC script URL when that is what the system is configured with.
  ///
  /// Carried so the UI can SAY SO. Dart cannot execute a PAC script, so a
  /// PAC-only configuration is a proxy this app cannot use — and reporting
  /// that honestly beats a download that silently goes direct.
  final String? pacUrl;

  /// Hosts the system says not to proxy. See [bypasses] for the matching.
  final List<String> exclusions;

  /// Whether there is a proxy to dial.
  bool get isUsable => host.isNotEmpty && port > 0;

  /// Builds one from the platform channel's payload, or null when absent.
  static SystemProxy? fromChannel(Object? raw) {
    if (raw is! Map) return null;
    final host = switch (raw['host']) {
      final String host => host.trim(),
      _ => '',
    };
    final port = switch (raw['port']) {
      final num port => port.toInt(),
      _ => -1,
    };
    final pac = switch (raw['pacUrl']) {
      final String pac => pac.trim(),
      _ => '',
    };
    final exclusions = <String>[
      for (final entry in switch (raw['exclusions']) {
        final List<Object?> list => list,
        _ => const <Object?>[],
      })
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    ];
    return SystemProxy(
      host: host,
      port: port,
      pacUrl: pac.isEmpty ? null : pac,
      exclusions: exclusions,
    );
  }

  /// Whether [host] should be reached directly.
  ///
  /// THREE MATCHES, because the exclusion list is human-edited text (a Wi-Fi
  /// advanced-settings field) and no two people spell a bypass the same way:
  /// exact host, suffix, or a regular expression for the people who write one.
  ///
  /// Note the direction of the failure: if a rule is not understood, the host
  /// goes THROUGH the proxy. That still works — just slower — while the
  /// opposite mistake would silently take the app off a proxy the user needs.
  bool bypasses(String host) {
    if (_isLoopback(host)) return true;
    for (final rule in exclusions) {
      if (_matches(rule, host)) return true;
    }
    return false;
  }

  static bool _isLoopback(String host) {
    const loopback = {'localhost', '127.0.0.1', '::1', '[::1]'};
    return loopback.contains(host) || host.endsWith('.localhost');
  }

  static bool _matches(String rule, String host) {
    if (rule == host) return true;
    if (host.endsWith('.$rule')) return true;
    try {
      return RegExp(rule).hasMatch(host);
    } on FormatException {
      return false;
    }
  }

  @override
  String toString() => isUsable
      ? 'SystemProxy($host:$port${pacUrl == null ? '' : ', pac: $pacUrl'})'
      : 'SystemProxy(none${pacUrl == null ? '' : ', pac: $pacUrl'})';
}

/// The PAC-format rule `HttpClient.findProxy` wants for one URL.
///
/// The return value is the PAC script dialect (`"PROXY host:port"` / `"DIRECT"`)
/// — that is the documented contract of the callback, not a format invented
/// here.
String proxyRuleFor(Uri url, SystemProxy? proxy) {
  if (proxy == null || !proxy.isUsable) return 'DIRECT';
  final host = url.host;
  if (host.isEmpty || proxy.bypasses(host)) return 'DIRECT';
  return 'PROXY ${proxy.host}:${proxy.port}';
}
