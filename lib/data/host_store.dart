import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where host profiles live.
///
/// Profiles are NOT secret — they are a label, a host, a port, a username and a
/// socket path. They go in ordinary preferences so they survive a keystore
/// reset, can be exported, and can be read synchronously at startup. The
/// secrets they reference go somewhere else entirely; see [HostSecretsStore].
class HostStore {
  HostStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kProfiles = 'hosts.profiles';
  static const _kSelected = 'hosts.selected';

  /// A profile for the machine the app is running on, offered on desktop.
  ///
  /// Created lazily rather than stored, so it can never be deleted into a state
  /// where a desktop user has no host at all.
  static const localProfile = HostProfile(
    id: 'local',
    label: 'This machine',
    username: '',
    isLocal: true,
  );

  /// Every saved profile.
  List<HostProfile> load() {
    final raw = _prefs.getString(_kProfiles);
    if (raw == null || raw.isEmpty) return const [];

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Corrupt storage should cost the user their host list, not their app.
      // Returning empty lets them re-add; throwing at startup would brick it.
      return const [];
    }
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map<Object?, Object?>>()
        .map((m) => HostProfile.fromJson(m.cast<String, Object?>()))
        .where((p) => p.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> save(List<HostProfile> profiles) async {
    await _prefs.setString(
      _kProfiles,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  /// The id of the profile the user last used.
  String? selectedId() => _prefs.getString(_kSelected);

  Future<void> select(String? id) async {
    if (id == null) {
      await _prefs.remove(_kSelected);
    } else {
      await _prefs.setString(_kSelected, id);
    }
  }
}

/// Secrets, held in the platform keystore.
///
/// keyed by profile id, one JSON blob per host so a write is atomic.
class HostSecretsStore {
  const HostSecretsStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static String _key(String hostId) => 'host.secret.$hostId';

  Future<SshSecrets?> read(String hostId) async {
    final raw = await _storage.read(key: _key(hostId));
    if (raw == null || raw.isEmpty) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final map = decoded.cast<String, Object?>();
    return SshSecrets(
      privateKeyPem:
          map['privateKeyPem'] is String ? map['privateKeyPem']! as String : null,
      privateKeyPassphrase: map['privateKeyPassphrase'] is String
          ? map['privateKeyPassphrase']! as String
          : null,
      password: map['password'] is String ? map['password']! as String : null,
    );
  }

  Future<void> write(String hostId, SshSecrets secrets) async {
    await _storage.write(
      key: _key(hostId),
      value: jsonEncode({
        if (secrets.privateKeyPem != null)
          'privateKeyPem': secrets.privateKeyPem,
        if (secrets.privateKeyPassphrase != null)
          'privateKeyPassphrase': secrets.privateKeyPassphrase,
        if (secrets.password != null) 'password': secrets.password,
      }),
    );
  }

  Future<void> delete(String hostId) =>
      _storage.delete(key: _key(hostId));
}

/// A host key the user has approved.
class HostKeyRecord {
  const HostKeyRecord({
    required this.keyType,
    required this.fingerprint,
    required this.approvedAt,
  });

  /// e.g. `ssh-ed25519`.
  final String keyType;

  /// `SHA256:…`, the form every other SSH tool shows.
  final String fingerprint;

  final DateTime approvedAt;

  Map<String, Object?> toJson() => {
        'keyType': keyType,
        'fingerprint': fingerprint,
        'approvedAt': approvedAt.toIso8601String(),
      };

  static HostKeyRecord? fromJson(Map<String, Object?> json) {
    final type = json['keyType'];
    final fp = json['fingerprint'];
    if (type is! String || fp is! String) return null;
    return HostKeyRecord(
      keyType: type,
      fingerprint: fp,
      approvedAt:
          DateTime.tryParse(json['approvedAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Pinned host keys — trust on first use, and never quietly re-trust.
///
/// WHY THIS IS IN THE KEYSTORE AND NOT IN PREFERENCES: a pin is only worth
/// something if an attacker cannot rewrite it. A fingerprint in plain
/// preferences can be edited by anything with file access, which would turn
/// "the key changed" into "no, this is the key I always approved" — the exact
/// attack pinning exists to catch. So pins live behind the same protection as
/// the credentials.
class HostKeyStore {
  const HostKeyStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static String _key(String pinKey) => 'hostkey.$pinKey';

  Future<HostKeyRecord?> read(String pinKey) async {
    final raw = await _storage.read(key: _key(pinKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return HostKeyRecord.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  Future<void> save(String pinKey, HostKeyRecord record) =>
      _storage.write(key: _key(pinKey), value: jsonEncode(record.toJson()));

  /// Forgets a pin, so the next connection asks again.
  ///
  /// Used when the user has independently confirmed a machine was rebuilt —
  /// never automatically, because auto-forgetting on mismatch is the same as
  /// having no pin at all.
  Future<void> forget(String pinKey) => _storage.delete(key: _key(pinKey));
}

/// What to do about a host key we were just shown.
enum HostKeyDecision {
  /// Approve and remember it.
  approveOnce,

  /// Approve and pin it for this host.
  approveAndRemember,

  /// Refuse this connection.
  reject,
}

/// The outcome of comparing a presented key against the stored pin.
///
/// Named distinctly from the transport's `HostKeyVerdict`, which answers a
/// different question: that one is "should this connection proceed", this one
/// is "what is the relationship between the key I was shown and the key I
/// remember". Conflating them is how a first-contact prompt and a possible
/// interception end up rendered the same way.
enum HostKeyPinVerdict {
  /// The presented key matches the pin.
  trusted,

  /// Never seen this host before — the user must decide.
  unknown,

  /// The key DIFFERS from the pin. This is the loud one.
  changed,
}

/// Compares a presented host key against the stored pin.
///
/// Pure, so the policy can be tested without a keystore, a socket or a UI. The
/// three outcomes are deliberately distinct: collapsing "unknown" into
/// "changed" would cry wolf on every first connection, and collapsing
/// "changed" into "unknown" would turn a possible interception into a routine
/// prompt the user learns to tap through.
Future<({HostKeyPinVerdict verdict, HostKeyRecord? pinned})> checkHostKey(
  HostKeyStore store, {
  required String pinKey,
  required String presentedType,
  required String presentedFingerprint,
}) async {
  final pinned = await store.read(pinKey);

  if (pinned == null) {
    return (verdict: HostKeyPinVerdict.unknown, pinned: null);
  }
  final matches = pinned.fingerprint == presentedFingerprint &&
      pinned.keyType == presentedType;
  return (
    verdict: matches ? HostKeyPinVerdict.trusted : HostKeyPinVerdict.changed,
    pinned: pinned,
  );
}
