import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

/// The phone's own SSH identity.
///
/// ## Why the private key has to be born here
///
/// `hdp pair` does hand the phone a private key — but a one-time one, whose
/// `authorized_keys` line carries `restrict,command=…`, so on the host it can
/// run exactly one program and nothing else. The key installed at the end of
/// pairing is a DIFFERENT key, generated on the phone and never transmitted:
/// only its public half crosses the wire.
///
/// That split is what makes it acceptable to put a private key in a QR code at
/// all. If the phone simply kept the key from the QR, every pairing would leave
/// a permanent credential lying in whatever photograph or scrollback captured
/// the code.
///
/// ## Why the key type is fixed
///
/// ed25519 and no choice offered. It is what every current sshd expects, its
/// public half is 32 bytes so the pairing QR stays scannable, and it is the one
/// key type dartssh2 can both parse and render — so a future "let me use RSA"
/// would be a different feature rather than a setting.
class PhoneIdentity {
  const PhoneIdentity._({
    required this.privateKeyPem,
    required this.authorizedKeyLine,
    required this.fingerprint,
  });

  /// Makes a new identity.
  ///
  /// [label] goes into the comment, so a user with three phones can tell them
  /// apart in `hdp list` on the host. It is cosmetic — the marker that gets
  /// detected is [clientKeyMarker], regardless of the label.
  factory PhoneIdentity.generate({String? label}) {
    final signingKey = ed25519.SigningKey.generate();
    final seed = Uint8List.fromList(signingKey.seed.asTypedList);
    final publicKey = Uint8List.fromList(signingKey.verifyKey.asTypedList);

    // OpenSSH stores an ed25519 private key as the 32-byte seed FOLLOWED BY the
    // 32-byte public key — the 64 bytes are a cache, not a secret, and a key
    // written with the seed alone is rejected or mis-read by some tools.
    final privateKey = Uint8List(64)
      ..setRange(0, 32, seed)
      ..setRange(32, 64, publicKey);

    final pair = OpenSSHEd25519KeyPair(publicKey, privateKey, clientKeyMarker);
    final pem = pair.toPem();

    final comment = (label == null || label.trim().isEmpty)
        ? clientKeyMarker
        : '$clientKeyMarker-${_slug(label)}';

    // `encode()` is the SSH wire blob — a length-prefixed "ssh-ed25519" and a
    // length-prefixed key — which is exactly what goes after the key type in an
    // authorized_keys line. Rendering it any other way produces a plausible
    // string that sshd will refuse.
    final blob = base64.encode(pair.toPublicKey().encode());

    return PhoneIdentity._(
      privateKeyPem: pem,
      authorizedKeyLine: 'ssh-ed25519 $blob $comment',
      fingerprint: _fingerprintOf(pair.toPublicKey().encode()),
    );
  }

  /// Rebuilds an identity from a PEM already in the keystore.
  ///
  /// [label] only decides the comment on the authorized_keys line, which is
  /// cosmetic — the host detects the key by the [clientKeyMarker] prefix and
  /// dedupes on the key blob, so a different label does not produce a second
  /// entry.
  factory PhoneIdentity.fromStoredPem(String pem, {String? label}) {
    final pairs = SSHKeyPair.fromPem(pem);
    if (pairs.isEmpty) {
      throw const FormatException('that PEM contains no key');
    }
    final blob = base64.encode(pairs.first.toPublicKey().encode());
    final comment = (label == null || label.trim().isEmpty)
        ? clientKeyMarker
        : '$clientKeyMarker-${_slug(label)}';
    return PhoneIdentity._(
      privateKeyPem: pem,
      authorizedKeyLine: 'ssh-ed25519 $blob $comment',
      fingerprint: _fingerprintOf(pairs.first.toPublicKey().encode()),
    );
  }

  /// Rebuilds an identity from a stored PEM.
  ///
  /// Needed because the machines list wants to show the fingerprint of a key it
  /// already has, and re-deriving it beats storing a second copy that can drift
  /// out of step with the key itself.
  static String fingerprintOfPem(String pem, {String? passphrase}) {
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) {
      throw const FormatException('that PEM contains no key');
    }
    return _fingerprintOf(pairs.first.toPublicKey().encode());
  }

  /// OpenSSH-format private key, unencrypted.
  ///
  /// Unencrypted at rest under `flutter_secure_storage`, not on disk: the
  /// platform keystore is what protects it, and a passphrase would have to be
  /// stored beside it to be usable unattended. Same reasoning as the imported
  /// keys the app already keeps there.
  final String privateKeyPem;

  /// The `authorized_keys` line for this key.
  ///
  /// Carries the `hdp-pocket` marker, because that marker is the protocol: the
  /// waiting `hdp pair` on the host polls `authorized_keys` for exactly this
  /// string to know the phone has arrived. A key sent without it installs
  /// correctly and then times out, which is the hardest version of this bug to
  /// read.
  final String authorizedKeyLine;

  /// `SHA256:…` of the public half, for the machines list.
  final String fingerprint;

}

/// Rebuilds the OpenSSH private key file from a 32-byte ed25519 seed.
///
/// ## Why the pairing string carries a seed and not this file
///
/// The natural thing to put in a pairing string is the PEM `hdp` already
/// produced, and the first version did. Measured, that PEM is about 400 base64
/// characters, which through the payload's own base64 becomes a **93-module** QR
/// code — 93 terminal columns, which does not fit a default 80-column terminal,
/// and which a phone camera has to resolve 93 modules across. It scanned badly
/// because it was too big.
///
/// The seed is 44 characters and loses nothing. `openssh-key-v1` is a container:
/// two check integers, the key type, the public key, the private key, a comment,
/// and padding. The private key is the seed followed by the public key, and the
/// public key is derived from the seed — so the seed is the only part that
/// cannot be recomputed, and it is the only part worth sending.
///
/// [OpenSSHEd25519KeyPair]'s `toPem()` writes the container, including the
/// padding rule (bytes 1, 2, 3… to the next multiple of 8), which is the part
/// easy to get subtly wrong by hand.
String openSshEd25519PrivateKeyFromSeed(Uint8List seed) {
  if (seed.length != 32) {
    throw ArgumentError.value(
      seed.length,
      'seed',
      'an ed25519 seed is 32 bytes',
    );
  }
  final signingKey = ed25519.SigningKey.fromSeed(seed);
  final publicKey = Uint8List.fromList(signingKey.verifyKey.asTypedList);

  // Seed FIRST, public key second — that order is the format, not a preference.
  final privateKey = Uint8List(64)
    ..setRange(0, 32, seed)
    ..setRange(32, 64, publicKey);

  return OpenSSHEd25519KeyPair(publicKey, privateKey, clientKeyMarker).toPem();
}

/// The marker `hdp` looks for in authorized_keys.
///
/// MUST MATCH `clientMarker` in `cli/hdp/main.go`. It is not a comment: it is
/// how the waiting `hdp pair` knows the phone arrived, and how `hdp list` and
/// `hdp unpair` find the lines to show and remove.
const clientKeyMarker = 'hdp-pocket';

/// OpenSSH's own fingerprint form: `SHA256:` plus base64 of the digest of the
/// key BLOB, padding stripped.
///
/// Not the base64url alphabet, and not the text of the key line. Both mistakes
/// produce a string of exactly the right shape that matches nothing, and the
/// failure they cause reads as "this server's host key changed" — which sends
/// the user to look at their server instead of at this function.
String _fingerprintOf(Uint8List blob) {
  final digest = _sha256(blob);
  return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
}

// A local SHA-256 rather than a new dependency: `crypto` would be a package
// added to the lock file for one call, and pointycastle is heavyweight for the
// same reason. This is the standard construction, ~40 lines, and it is only
// ever used on a 51-byte key blob.
Uint8List _sha256(Uint8List data) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final paddedLength = ((data.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength)..setRange(0, data.length, data);
  padded[data.length] = 0x80;
  final bitLength = data.length * 8;
  for (var i = 0; i < 8; i++) {
    padded[paddedLength - 1 - i] = (bitLength >> (8 * i)) & 0xFF;
  }

  final w = Uint32List(64);
  for (var offset = 0; offset < paddedLength; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (hh + s1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;

      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }

    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (h[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (h[i] >> 8) & 0xFF;
    out[i * 4 + 3] = h[i] & 0xFF;
  }
  return out;
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// Turns a label into something safe to put in a comment field.
String _slug(String label) {
  final cleaned = label
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (cleaned.isEmpty) return 'phone';
  return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
}

/// A random hex token, for labelling a pairing attempt in a log or a list.
String randomToken([int bytes = 8]) {
  final rng = Random.secure();
  final buffer = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    buffer[i] = rng.nextInt(256);
  }
  return buffer.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The phone's identity, kept between pairings.
///
/// ## Why it is not generated per pairing
///
/// The obvious implementation mints a key inside `hdp pair`'s phone-side flow,
/// and it works — once. What it does not survive is doing it twice: every
/// pairing attempt installs a DIFFERENT public key, so re-pairing the same
/// machine leaves the previous key behind in that machine's `authorized_keys`
/// as an entry that no longer matches anything on the phone. Pair three times
/// over a month and the host has three lines, `hdp list` shows three phones,
/// and only the newest one can actually authenticate.
///
/// One identity, created once and reused, is also what `ssh` itself does: there
/// is one `~/.ssh/id_ed25519`, not one per host. It makes the host-side install
/// idempotent — `hdp __exchange` already refuses to append a key blob it
/// already has — so a retry is genuinely free.
class PhoneIdentityStore {
  /// Holds the store.
  const PhoneIdentityStore([this._storage = const FlutterSecureStorage()]);

  /// Kept out of the per-host secret namespace on purpose: this key belongs to
  /// the PHONE, not to any one machine, and storing it per host is exactly the
  /// mistake this class exists to avoid.
  static const storageKey = 'pairing.identity.pem';

  final FlutterSecureStorage _storage;

  /// Returns the stored identity, creating one the first time.
  ///
  /// A stored key that cannot be parsed is REPLACED rather than thrown over:
  /// the alternative is an app that can never pair again because of one bad
  /// keystore entry, with no screen that offers a way out. The cost of
  /// replacing it is one stale line in the host's `authorized_keys`, which is
  /// the thing `hdp list` and `hdp unpair` exist to clean up.
  Future<PhoneIdentity> readOrCreate({String? label}) async {
    final stored = await _storage.read(key: storageKey);
    if (stored != null && stored.trim().isNotEmpty) {
      try {
        return PhoneIdentity.fromStoredPem(stored, label: label);
      } on Object {
        // Fall through and mint a new one.
      }
    }
    return await replace(label: label);
  }

  /// Mints a new identity, replacing whatever was there.
  ///
  /// The phone-side equivalent of `hdp pair --force`: the escape hatch for a
  /// key the user believes is compromised.
  Future<PhoneIdentity> replace({String? label}) async {
    final identity = PhoneIdentity.generate(label: label);
    await _storage.write(key: storageKey, value: identity.privateKeyPem);
    return identity;
  }
}
