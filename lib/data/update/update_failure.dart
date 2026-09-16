/// Why an update could not be checked, fetched, or installed.
///
/// A TAGGED ENUM, for the reason this codebase keeps giving: classifying by
/// matching on error text is how guidance erodes, and every one of these needs
/// a different sentence and a different next step. The three that look alike
/// from a distance — [offline], [proxyRefused] and [tlsRejected] — are exactly
/// the three a user with a proxy hits in sequence while getting their setup
/// right, and telling them apart is the difference between "check your network"
/// (useless) and "你的代理在 7890 上没有响应".
enum UpdateFailure {
  /// No route to the internet at all.
  offline,

  /// A proxy is configured but nothing answered at it.
  ///
  /// Split from [offline] because the fix is in a completely different place:
  /// the proxy app, not the phone's connectivity.
  proxyRefused,

  /// The TLS handshake was rejected.
  ///
  /// On a phone behind an intercepting proxy this is almost always a
  /// certificate this app does not trust — see
  /// `docs/research/12-app-update.md` §3.3.
  tlsRejected,

  /// Connected, then went quiet.
  ///
  /// The one that a phone on a train produces. dio's `receiveTimeout` is the
  /// interval between byte events, so this fires exactly when the transfer
  /// stalls, not when it is merely slow.
  timedOut,

  /// GitHub's anonymous rate limit (60/hour) is exhausted.
  rateLimited,

  /// The server answered with something that was not a success.
  httpStatus,

  /// A success, but not the document expected. A captive portal is the classic
  /// source: it answers 200 with a login page.
  badPayload,

  /// Nothing published qualifies as a release of this app.
  noRelease,

  /// A release exists but ships no APK this device can install.
  noAssetForDevice,

  /// The bytes could not be written to the phone.
  storage,

  /// The download finished but its SHA-256 does not match the release's.
  checksum,

  /// The download finished with the wrong number of bytes.
  sizeMismatch,

  /// The user stopped it. Kept distinguishable from a failure because the UI
  /// must not report a decision as an error.
  cancelled,

  /// The system will not let this app install packages yet.
  installBlocked,

  /// The APK is signed with a different key than the installed app.
  signatureMismatch,

  /// The APK is a different app entirely.
  wrongPackage,

  /// The APK is older than what is already installed, so the installer would
  /// refuse it.
  versionTooOld,

  /// Anything else, with the detail preserved for diagnostics.
  unknown,
}
