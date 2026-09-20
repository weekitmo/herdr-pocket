import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What the app lock remembers, and how little of it is the PIN.
///
/// ## What the hash is worth, honestly
///
/// FOUR DIGITS IS TEN THOUSAND POSSIBILITIES, so no amount of hashing makes this
/// a defense against somebody who can read this record. What the salt and the
/// digest buy is that the PIN is not sitting in the keystore — or in a backup, a
/// log, or a crash report that quotes one — as the four characters the user
/// types. The protection that matters is the one underneath: the record lives in
/// the platform keystore (see [AppLockStore]), and an attacker who can read that
/// has the device already.
///
/// Iterating the hash a hundred thousand times would look more serious and add
/// nothing: ten thousand candidates fall in a second either way. It is written
/// down because "salted SHA-256 for a 4-digit PIN" is exactly the kind of thing
/// a later reader is right to be suspicious of, and the answer is not "it is
/// stronger than it looks" — it is "this is what it is for, and encryption is
/// not what a lock screen is".
class AppLockRecord {
  const AppLockRecord({
    required this.salt,
    required this.pinHash,
    required this.biometricsEnabled,
  });

  /// Per-install random bytes, base64. Stops one rainbow table from covering
  /// every install of this app.
  final String salt;

  /// `SHA-256(salt:pin)`, base64.
  final String pinHash;

  /// Whether the device's own biometric prompt may open the app.
  ///
  /// Stored beside the PIN rather than in settings, because it is meaningless
  /// without one: the lock has no other way in, and a phone whose fingerprint
  /// sensor stops answering must still be openable.
  final bool biometricsEnabled;

  Map<String, Object?> toJson() => {
        'salt': salt,
        'pinHash': pinHash,
        'biometricsEnabled': biometricsEnabled,
      };

  static AppLockRecord? fromJson(Map<String, Object?> json) {
    final salt = json['salt'];
    final hash = json['pinHash'];
    if (salt is! String || hash is! String || salt.isEmpty || hash.isEmpty) {
      return null;
    }
    return AppLockRecord(
      salt: salt,
      pinHash: hash,
      biometricsEnabled: json['biometricsEnabled'] == true,
    );
  }
}

/// The PIN, as the four digits the lock accepts.
bool isWellFormedPin(String pin) => RegExp(r'^\d{4}$').hasMatch(pin);

/// The stored form of a PIN.
String hashPin(String pin, String salt) =>
    base64.encode(sha256.convert(utf8.encode('$salt:$pin')).bytes);

/// A fresh per-install salt.
String newSalt([Random? random]) {
  final rng = random ?? Random.secure();
  return base64.encode([for (var i = 0; i < 16; i++) rng.nextInt(256)]);
}

/// Where the lock lives.
///
/// THE KEYSTORE, NOT PREFERENCES, and the reason is the same as the host keys':
/// a lock whose record anything with file access can rewrite or delete is a lock
/// that can be removed by an attacker who has already reached the filesystem.
/// `flutter_secure_storage` puts it behind the platform keystore, and deleting
/// the record is the ONLY way to open the app without the PIN.
class AppLockStore {
  const AppLockStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const String _key = 'applock.record';

  Future<AppLockRecord?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return AppLockRecord.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      // A corrupt record must not make the app unopenable: no record means no
      // lock, which is the state this app shipped in.
      return null;
    }
  }

  Future<void> write(AppLockRecord record) =>
      _storage.write(key: _key, value: jsonEncode(record.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
