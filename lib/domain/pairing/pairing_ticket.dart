/// The string `hdp pair` prints, as the app understands it.
///
/// ONE PARSER FOR BOTH DOORS. The terminal draws the payload as a QR code and
/// prints the identical base64url text underneath it; the app accepts a scan and
/// a paste through this file and nothing else. Two parsers would mean two sets
/// of edge cases, and "the scan works but the paste does not" is the worst kind
/// of bug to be handed, because the person reporting it has already proved the
/// feature can work.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What a pairing string carries.
class PairingTicket {
  /// Holds one decoded pairing string.
  const PairingTicket({
    required this.host,
    required this.port,
    required this.user,
    required this.bootstrapSeed,
    required this.hostKeyFingerprint,
    this.name,
  });

  /// The address the phone should dial — an IP, a hostname, a tailnet name.
  final String host;

  final int port;
  final String user;

  /// The ONE-TIME key's 32-byte ed25519 seed.
  ///
  /// NOT a PEM, and the difference is the difference between a code a phone can
  /// scan and one it cannot. A PEM is about 400 base64 characters, and measured
  /// through the payload's own encoding it produced a **93-module** code — 93
  /// terminal columns, which does not fit a default 80-column terminal and
  /// which the camera has to resolve 93 modules across. The seed is 44
  /// characters and nothing is lost: an `openssh-key-v1` file is a container
  /// around exactly this seed, so
  /// [openSshEd25519PrivateKeyFromSeed] rebuilds the rest.
  ///
  /// A secret, and deliberately not logged, not shown, and not stored anywhere
  /// except in memory for the length of the pairing. On the host it lives as an
  /// `authorized_keys` line carrying a forced command, which means it can run
  /// exactly one program — and `hdp pair` deletes that line as soon as this
  /// phone's real key arrives, or when the window closes.
  final Uint8List bootstrapSeed;

  /// The host key the server will present, as `SHA256:…`.
  ///
  /// THE VALUE THAT MAKES THE QR AN AUTHENTICATED CHANNEL rather than a
  /// convenient one. It arrived over a channel a network attacker cannot touch
  /// (a camera, or a paste the user chose), so the first connection can PIN the
  /// server instead of asking the user to compare a fingerprint by eye — a step
  /// people skip, and which therefore protects nobody.
  final String hostKeyFingerprint;

  /// A label for the machines list, e.g. `Mac mini`.
  final String? name;

  /// What the host is called in the UI: the given name, or the address.
  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name!.trim() : host;

  @override
  String toString() =>
      'PairingTicket($user@$host:$port, key redacted)';
}

/// The only payload version this build understands.
///
/// It is the FIRST field in the encoding too, so a decoder can rule a string out
/// after one byte rather than after parsing it.
const pairingProtocolVersion = 1;

/// How long an ed25519 seed is.
///
/// Named because the number has to agree in two places that never see each
/// other: the length check here, and the key the app rebuilds from it.
const ed25519SeedBytes = 32;

/// Why a pairing string could not be read.
///
/// A tagged enum rather than a message, for the reason the rest of this codebase
/// keeps giving: each of these lets the UI say something different, and two of
/// them have an action attached.
enum PairingParseFailure {
  /// Nothing was entered.
  empty,

  /// Not base64url at all — a truncated paste, or something that was never a
  /// pairing string.
  malformed,

  /// Base64 decoded, but the contents are not a payload this build knows. The
  /// likely cause is a newer `hdp`, so the message says so.
  unsupported,

  /// Decoded and understood, but missing something the connection needs.
  incomplete,
}

class PairingParseException implements Exception {
  const PairingParseException(this.reason, this.detail);

  final PairingParseFailure reason;

  /// For diagnostics. The UI localises from [reason].
  final String detail;

  @override
  String toString() => 'PairingParseException(${reason.name}): $detail';
}

/// Decodes one pairing string.
///
/// WHITESPACE IS STRIPPED FIRST, and that is not politeness. The string is
/// printed wrapped across terminal lines and is meant to be copied out of one,
/// so the shape a real paste arrives in is "correct base64 with newlines in it".
/// Rejecting that would be rejecting the exact use the paste path exists for.
PairingTicket parsePairingString(String input) {
  final cleaned = input.replaceAll(RegExp(r'[\s\u00a0]'), '');
  if (cleaned.isEmpty) {
    throw const PairingParseException(
      PairingParseFailure.empty,
      'nothing was entered',
    );
  }

  final List<int> raw;
  try {
    raw = _decodeBase64Url(cleaned);
  } on FormatException catch (e) {
    throw PairingParseException(PairingParseFailure.malformed, '$e');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(raw));
  } on Object catch (e) {
    throw PairingParseException(PairingParseFailure.malformed, '$e');
  }

  if (decoded is! Map<String, Object?>) {
    throw PairingParseException(
      PairingParseFailure.malformed,
      'the payload is a ${decoded.runtimeType}, not an object',
    );
  }

  final version = decoded['v'];
  if (version is! int) {
    throw const PairingParseException(
      PairingParseFailure.malformed,
      'no protocol version',
    );
  }
  if (version != pairingProtocolVersion) {
    // Its own failure, because the user is holding a VALID string and needs to
    // be told which end to update. "Invalid pairing string" here is how someone
    // concludes the feature is broken.
    throw PairingParseException(
      PairingParseFailure.unsupported,
      'pairing protocol $version, this build speaks $pairingProtocolVersion',
    );
  }

  final host = _stringField(decoded, 'h');
  final user = _stringField(decoded, 'u');
  final fingerprint = _stringField(decoded, 'f');

  // Decoded HERE rather than carried as a string, so a malformed key is refused
  // at the door instead of at the moment a connection is already being made.
  final Uint8List seed;
  try {
    // PADDED FIRST. `hdp` writes base64 without `=`, because every character
    // spent on padding is a character the QR code has to carry — and
    // `base64.decode` rejects a length that is not a multiple of four rather
    // than filling it in. Measured: a 43-character seed failed here with
    // "Invalid length, must be multiple of four".
    final raw = _stringField(decoded, 'k');
    final padded = raw.length % 4 == 0
        ? raw
        : raw + '=' * (4 - raw.length % 4);
    seed = base64.decode(padded);
  } on FormatException catch (e) {
    throw PairingParseException(
      PairingParseFailure.incomplete,
      'the key is not base64: $e',
    );
  }
  if (seed.length != ed25519SeedBytes) {
    throw PairingParseException(
      PairingParseFailure.incomplete,
      'the key is ${seed.length} bytes and an ed25519 seed is '
          '$ed25519SeedBytes',
    );
  }

  final port = decoded['p'];
  if (port is! int || port <= 0 || port > 65535) {
    throw PairingParseException(
      PairingParseFailure.incomplete,
      'port is ${port ?? 'missing'}',
    );
  }
  if (!fingerprint.startsWith('SHA256:')) {
    // A pin that is not a fingerprint would be compared against a real one and
    // never match, and the user would see "the host key changed" for a host
    // nobody touched — which is the alarm this field exists to make meaningful.
    throw const PairingParseException(
      PairingParseFailure.incomplete,
      'fingerprint is not a SHA256 one',
    );
  }

  final name = decoded['n'];

  return PairingTicket(
    host: host,
    port: port,
    user: user,
    bootstrapSeed: seed,
    hostKeyFingerprint: fingerprint,
    name: name is String ? name : null,
  );
}

/// Decodes base64url, with or without padding.
///
/// Padding is tolerated because it comes back: some chat clients and most
/// libraries that touch base64 re-add the `=`, and trying the padded alphabet
/// costs one decode attempt instead of producing a mystifying parse error on a
/// string that is in fact perfectly good.
List<int> _decodeBase64Url(String cleaned) {
  try {
    return base64Url.decode(base64Url.normalize(cleaned));
  } on FormatException {
    // `normalize` returns the input unchanged when it cannot make sense of the
    // length, so a failure here is a genuine "this is not base64url".
    return base64Url.decode(cleaned);
  }
}

String _stringField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw PairingParseException(
      PairingParseFailure.incomplete,
      'the "$key" field is missing or empty',
    );
  }
  return value.trim();
}
