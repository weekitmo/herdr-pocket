import 'dart:io';

import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';
import 'package:herdr_pocket/data/transport/unix_socket_transport.dart';

/// One machine herdr runs on, as the user configured it.
///
/// Secrets (`privateKeyPem`, `privateKeyPassphrase`, `password`) are never
/// persisted with the profile — the profile stores a credential REFERENCE and
/// the secret lives in the platform keystore. Keeping them off the same record
/// is what makes it safe to log or export a profile.
class HostProfile {
  const HostProfile({
    required this.id,
    required this.label,
    required this.username,
    this.host = '127.0.0.1',
    this.port = 22,
    this.socketPath,
    this.isLocal = false,
  });

  /// Reads a profile, tolerating missing and mistyped fields.
  ///
  /// A stored profile outlives the code that wrote it, so a field added later
  /// is absent on old records and a field retyped is present with the wrong
  /// type. Returning a usable profile beats refusing to start.
  factory HostProfile.fromJson(Map<String, Object?> json) {
    return HostProfile(
      id: json['id'] is String ? json['id']! as String : '',
      label: json['label'] is String ? json['label']! as String : '',
      username: json['username'] is String ? json['username']! as String : '',
      host: json['host'] is String ? json['host']! as String : '127.0.0.1',
      port: json['port'] is int ? json['port']! as int : 22,
      socketPath:
          json['socketPath'] is String ? json['socketPath']! as String : null,
      isLocal: json['isLocal'] == true,
    );
  }

  final String id;
  final String label;
  final String username;
  final String host;
  final int port;

  /// Absolute path to the daemon socket ON THAT MACHINE. Null means "discover
  /// it", which is the normal case.
  final String? socketPath;

  /// True when the daemon is reachable without SSH — this process is already
  /// on the same machine. On desktop that is the common case and saves a whole
  /// SSH hop; on a phone it is never true.
  final bool isLocal;

  /// Serialises the PROFILE only — never a secret.
  ///
  /// The password, key and passphrase live in the platform keystore and are
  /// referenced by [id]. Keeping them out of this map is what makes a profile
  /// safe to log, export, back up or put in a bug report.
  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'username': username,
        'host': host,
        'port': port,
        if (socketPath != null) 'socketPath': socketPath,
        'isLocal': isLocal,
      };


  /// The key a host key is pinned against.
  String get pinKey => '$host:$port';

  String get displayTarget =>
      isLocal ? 'This machine' : '$username@$host:$port';

  HostProfile copyWith({
    String? label,
    String? username,
    String? host,
    int? port,
    String? socketPath,
    bool? isLocal,
  }) {
    return HostProfile(
      id: id,
      label: label ?? this.label,
      username: username ?? this.username,
      host: host ?? this.host,
      port: port ?? this.port,
      socketPath: socketPath ?? this.socketPath,
      isLocal: isLocal ?? this.isLocal,
    );
  }
}

/// Figures out where the daemon socket lives on a machine.
///
/// The socket path is the one piece of connection setup we cannot ask the API
/// for, because we need it to speak to the API at all. The rules:
///
///   * an explicit path from the profile wins;
///   * otherwise `$HOME/.config/herdr/herdr.sock`.
///
/// `$HOME` must be resolved by the REMOTE shell rather than guessed: a
/// non-interactive SSH exec runs a non-login shell whose PATH and HOME are not
/// the user's interactive ones, and assuming `/home/<user>` is wrong on macOS
/// (where it is `/Users/<user>`) and on any Linux box with a non-standard home.
class SocketPathResolver {
  SocketPathResolver(this.runner);

  final RemoteCommandRunner runner;

  static const defaultRelativePath = '.config/herdr/herdr.sock';

  String? _cachedHome;

  Future<String> resolve(HostProfile profile) async {
    final explicit = profile.socketPath;
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final home = await _home();
    if (home.isEmpty) {
      throw HerdrTransportException(
        TransportFailure.connectFailed,
        'could not determine the home directory on ${profile.host}',
      );
    }
    return '$home/$defaultRelativePath';
  }

  Future<String> _home() async {
    final cached = _cachedHome;
    if (cached != null) return cached;

    // `printf` rather than `echo $HOME`: no trailing newline to trim, and no
    // shell-echo weirdness. The trailing command fences the value between
    // markers so any login banner or profile output cannot be mistaken for it.
    const command = r'printf "%%HPHOME%%%s%%HPEND%%" "$HOME"';
    final raw = await runner.runCommand(command);

    final start = raw.indexOf('%HPHOME%');
    final end = raw.indexOf('%HPEND%', start + 1);
    if (start == -1 || end == -1) {
      throw HerdrTransportException(
        TransportFailure.connectFailed,
        'the remote shell did not report HOME: ${raw.trim()}',
      );
    }
    final home = raw.substring(start + 8, end).trim();
    _cachedHome = home;
    return home;
  }
}

/// Builds the right transport for a profile.
///
/// This is the only place that decides between "talk to a socket directly" and
/// "go through SSH", which keeps that decision out of the UI and makes it
/// testable.
class HostConnector {
  HostConnector({
    required this.credentialsFor,
    required this.verifyHostKey,
    this.connectTimeout = const Duration(seconds: 15),
  });

  /// Resolves the secrets for a profile from the keystore. Async because the
  /// keystore is, and because a missing credential is a normal outcome that
  /// deserves a typed error rather than a null.
  final Future<SshSecrets?> Function(HostProfile profile) credentialsFor;

  final HostKeyVerifier verifyHostKey;
  final Duration connectTimeout;

  Future<({HerdrClientBundle bundle, String socketPath})> connect(
    HostProfile profile,
  ) async {
    if (profile.isLocal) {
      final path = profile.socketPath ?? _defaultLocalSocketPath();
      return (
        bundle: HerdrClientBundle(
          transport: UnixSocketTransport(socketPath: path),
          socketPath: path,
        ),
        socketPath: path,
      );
    }

    final secrets = await credentialsFor(profile);
    if (secrets == null) {
      throw HerdrTransportException(
        TransportFailure.authenticationFailed,
        'no stored credential for ${profile.label}',
      );
    }

    final ssh = SshSocketTransport(
      credentials: SshCredentials(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: secrets.privateKeyPem,
        privateKeyPassphrase: secrets.privateKeyPassphrase,
        password: secrets.password,
      ),
      // Resolved below, before any protocol traffic.
      socketPath: profile.socketPath ?? '',
      verifyHostKey: verifyHostKey,
      connectTimeout: connectTimeout,
    );

    var path = profile.socketPath;
    if (path == null || path.isEmpty) {
      final resolver = SocketPathResolver(ssh);
      path = await resolver.resolve(profile);
      await ssh.close();
      // Re-open with the resolved path. The SSH connection is cheap to redo
      // once, and this keeps the path immutable for the transport's lifetime
      // rather than mutable state two layers deep.
      final resolved = SshSocketTransport(
        credentials: ssh.credentials,
        socketPath: path,
        verifyHostKey: verifyHostKey,
        connectTimeout: connectTimeout,
      );
      return (
        bundle: HerdrClientBundle(transport: resolved, socketPath: path),
        socketPath: path,
      );
    }

    return (
      bundle: HerdrClientBundle(transport: ssh, socketPath: path),
      socketPath: path,
    );
  }

  static String _defaultLocalSocketPath() {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/${SocketPathResolver.defaultRelativePath}';
  }
}

/// A transport plus the path it is bound to, so a reconnect can reuse the
/// already-resolved path instead of paying discovery again.
class HerdrClientBundle {
  HerdrClientBundle({required this.transport, required this.socketPath});

  final HerdrTransport transport;
  final String socketPath;
}

/// Secrets, held only in memory long enough to open a connection.
class SshSecrets {
  const SshSecrets({this.privateKeyPem, this.privateKeyPassphrase, this.password});

  final String? privateKeyPem;
  final String? privateKeyPassphrase;
  final String? password;
}
