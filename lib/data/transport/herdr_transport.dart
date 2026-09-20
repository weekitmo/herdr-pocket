/// The seam between "how we reach the daemon" and "what we say to it".
///
/// Everything above this interface speaks NDJSON strings and knows nothing
/// about SSH, sockets, channels or host keys. That is deliberate: it is what
/// lets the protocol layer be tested against recorded frames, and it is what
/// would let a future transport (a fork's `api-bridge`, a local direct socket
/// for desktop) drop in without touching the client.
///
/// The one import is `dart:typed_data`, for [RemoteFileFetcher]'s byte chunks.
/// This file still knows nothing about SSH — `Uint8List` is what any byte
/// channel in Dart produces, including a local file.
library;

import 'dart:typed_data';

/// Why a transport operation failed.
///
/// A tagged enum rather than a string, because the UI needs to show different
/// guidance for "herdr is not installed" than for "your key changed" — and
/// classifying by matching on error text is how that erodes.
enum TransportFailure {
  /// Could not open the TCP connection / complete the SSH handshake.
  connectFailed,

  /// Credentials were rejected.
  authenticationFailed,

  /// The server presented an unknown host key and it was not approved.
  hostKeyUnknown,

  /// The server presented a DIFFERENT host key than the one approved before.
  /// Worth its own case: it is either a rebuilt machine or an interception.
  hostKeyChanged,

  /// Connected, but the SSH server refuses stream-local (Unix socket)
  /// forwarding. See [HerdrTransportException.isForwardingRefused].
  forwardingRefused,

  /// Connected, but the server has no SFTP subsystem enabled.
  ///
  /// Its own case because the fix is not "try again" — it is a line in the
  /// host's `sshd_config`, and a user who is told "transfer failed" will
  /// retry forever. See [HerdrTransportException.isSftpUnavailable].
  sftpUnavailable,

  /// The operation exceeded its deadline.
  timeout,

  /// The channel closed before a complete reply arrived.
  streamClosed,

  /// Anything else, with the message preserved for diagnostics.
  unknown,
}

/// How far one dial has got, as reported BY THE LAYER DOING THE WORK.
///
/// WHY A DIAL NEEDS MORE THAN TWO WORDS. The connection's own state machine
/// narrated progress with a single phrase — "connecting" — until the transport
/// was up, and then "verifying". That is the right granularity for a badge and
/// the wrong one for a screen the user is staring at, because the interesting
/// part is the one that takes ten seconds on a bad link: the SSH handshake.
/// A phone on an overlay network spent that time reading "connecting" and could
/// not tell "it is working on it" from "it is stuck", which is exactly the
/// complaint this enum exists to answer.
///
/// REPORTED, NEVER INFERRED. Only the dialler knows when the socket is up, when
/// the far side is being asked to prove its key, and when a human has to
/// answer — and a stage guessed at from a timer would eventually describe
/// something that is not happening.
enum DialStage {
  /// Resolving the address and opening the TCP connection.
  resolving,

  /// The SSH handshake and authentication. The long one.
  dialling,

  /// Blocked on a person: the host-key sheet is up and the handshake is waiting
  /// for the answer.
  hostKey,

  /// Asking the machine where its home directory is, so the daemon's socket
  /// path can be resolved.
  locating,

  /// The transport is up; proving that the daemon answers on it.
  verifying,
}

class HerdrTransportException implements Exception {
  HerdrTransportException(
    this.failure,
    this.message, {
    this.cause,
  });

  final TransportFailure failure;
  final String message;
  final Object? cause;

  /// The server connected fine but will not forward to a Unix socket.
  ///
  /// This is the one failure that is worth pre-empting in the UI, because the
  /// fix is a one-line sshd setting (`AllowStreamLocalForwarding`) rather than
  /// anything the user did wrong.
  bool get isForwardingRefused => failure == TransportFailure.forwardingRefused;

  /// The connection works but this host cannot move files.
  ///
  /// Worth pre-empting in the UI for the same reason as [isForwardingRefused]:
  /// the fix is one line in the host's `sshd_config`
  /// (`Subsystem sftp /usr/libexec/sftp-server` on macOS,
  /// `/usr/lib/openssh/sftp-server` on most Linux), not anything the user did.
  bool get isSftpUnavailable => failure == TransportFailure.sftpUnavailable;

  /// The connection works but should not be trusted.
  bool get isSecurityRelevant =>
      failure == TransportFailure.hostKeyChanged ||
      failure == TransportFailure.hostKeyUnknown;

  @override
  String toString() => 'HerdrTransportException(${failure.name}): $message';
}

/// A persistent, bidirectional NDJSON channel.
///
/// Used for anything that stays open: `events.subscribe`, and the terminal
/// control stream. One-shot requests use [HerdrTransport.roundTrip] instead,
/// because the API socket closes after a single reply.
abstract interface class HerdrDuplex {
  /// Complete lines from the remote side, decoded at newline boundaries.
  Stream<String> get lines;

  /// Sends one line. The newline is added by the implementation.
  void send(String line);

  /// Completes when the remote side ends the stream.
  Future<void> get done;

  Future<void> close();
}

/// How herdr-pocket reaches the daemon.
abstract interface class HerdrTransport {
  /// One request, one reply.
  ///
  /// Implementations MUST use a fresh channel per call: the API socket accepts
  /// exactly one request and then closes, so a shared connection would appear
  /// to work once and then fail.
  Future<String> roundTrip(String requestLine);

  /// Opens a channel that stays open.
  ///
  /// [openLine] is the JSON request that opens the stream; on the fork's
  /// `--duplex` bridge it is written first, and on a plain socket it is simply
  /// the first request on the connection.
  Future<HerdrDuplex> openDuplex(String openLine);

  Future<void> close();
}

/// Shell prelude that resolves the herdr binary, for both local and remote use.
///
/// A non-interactive shell is a NON-LOGIN shell, whose `PATH` does not include
/// `~/.local/bin` — which is where herdr installs by default. A bare `herdr`
/// therefore fails with "command not found". This mirrors what herdr's own
/// remote wrapper does (`command -v herdr`, else `$HOME/.local/bin/herdr`),
/// and the executable guard separates "not installed at all" from every other
/// failure before exec, so the client can say which one it is.
const herdrCommandPrefix =
    r'HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr"); '
    r'[ -x "$HERDR" ] || { echo __HERDR_NOT_INSTALLED__ >&2; exit 127; }; '
    r'exec "$HERDR" ';

/// The sentinel the prelude prints when herdr is absent.
const herdrNotInstalledSentinel = '__HERDR_NOT_INSTALLED__';

/// Whether [message] really is the shell saying "no herdr here".
///
/// THE SENTINEL IS A LINE, NOT A WORD, and that distinction is a bug fix rather
/// than a style choice. It is safe to match on because the far side prints it
/// alone on a line:
///
/// ```text
/// HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr"); \
///   [ -x "$HERDR" ] || { echo __HERDR_NOT_INSTALLED__ >&2; exit 127; }; …
/// ```
///
/// …and unsafe to match as a SUBSTRING, because that command is itself built
/// from the constant and an error message may quote it back. It did: a dead SSH
/// connection made the command fail to start, the failure message carried the
/// whole command, and three screens — the terminal, the machines list and the
/// dial's own classifier — confidently told the user "herdr is not installed on
/// this machine" about a machine that had it installed and a link that was
/// simply gone. Matching a line makes the two shapes distinguishable, because a
/// marker that can arrive inside a sentence about something else is not a
/// marker.
bool reportsHerdrMissing(String message) => message
    .split('\n')
    .any((line) => line.trim() == herdrNotInstalledSentinel);

/// A command, shortened to something a person can read.
///
/// For error messages, which end up on a phone screen: the generated capability
/// probe is 8 KB of shell and the terminal command opens with a PATH prelude,
/// so quoting either one whole produced a wall of text where a sentence belongs
/// — and, worse, made [reportsHerdrMissing]'s sentinel appear in messages that
/// had nothing to do with a missing herdr.
String shortCommand(String command, {int maxLength = 60}) {
  final singleLine = command.replaceAll('\n', ' ').trim();
  if (singleLine.length <= maxLength) return singleLine;
  return '${singleLine.substring(0, maxLength)}…';
}

/// A transport whose connection OUTLIVES a single request, and that can say
/// when it is gone.
///
/// Kept separate from [HerdrTransport] for the same reason [RemoteCommandRunner]
/// is: not every transport can answer the question. `SshSocketTransport` holds
/// one session for as long as the app is connected, so it can; the local socket
/// transport opens a socket per request and has nothing to watch — its failures
/// land in front of the caller, which is where it finds out.
///
/// THIS IS WHAT MAKES A DROPPED LINK NOTICEABLE AT ALL. A phone loses its SSH
/// connection constantly — a sleeping radio, a handover between Wi-Fi and
/// cellular, and above all an app that went to the background, where the OS
/// freezes the process and the keepalive stops. Without this seam the app kept
/// saying "connected" for as long as the user cared to look, and every request
/// on the corpse failed one at a time.
abstract interface class ConnectionLiveness {
  /// False as soon as the connection behind this transport has ended.
  bool get isAlive;

  /// Completes when the connection ends ON ITS OWN.
  ///
  /// A deliberate [HerdrTransport.close] never completes this: "the user
  /// disconnected" and "the link died" have opposite responses — one is left
  /// alone and one is re-dialled — so the two must not arrive on the same
  /// signal.
  Future<void> get lost;
}

/// Moves bytes ONTO the machine the daemon lives on.
///
/// herdr's socket API has no filesystem surface at all — verified by
/// enumerating the method list on a live 0.9.0, where `file`/`fs`/`content`
/// appear zero times. So a file can only travel over the SSH connection that is
/// already open, and this is that seam.
///
/// Kept separate from [RemoteCommandRunner] for the same reason that one is
/// separate from [HerdrTransport]: a shell command is the wrong tool for bytes.
/// Base64-ing an image through `sh -c` would work and be terrible — three
/// round trips of argv, and a size limit that has nothing to do with the file.
abstract interface class RemoteFilePorter {
  /// Writes [bytes] to [absolutePath], creating or truncating it.
  ///
  /// Implementations must reject a path that is not absolute rather than
  /// guessing a base directory: "where did my screenshot go" is unanswerable
  /// when the answer is the SFTP user's implicit cwd.
  Future<void> uploadBytes({
    required String absolutePath,
    required List<int> bytes,
  });
}

/// What SFTP reports about a path before anything is transferred.
///
/// Carried so the UI can say "48 MB, about 3 seconds" BEFORE the transfer
/// starts. That is not decoration: the alternative is a spinner that turns out
/// to be a five-minute wait on a cellular link, and by then the user has
/// already left the screen.
class RemoteFileInfo {
  /// Holds one path's attributes.
  const RemoteFileInfo({required this.sizeBytes, required this.isDirectory});

  /// Exact size in bytes.
  ///
  /// Null when the far end does not report one — a character device, or a
  /// filesystem that answered `SSH_FXP_STAT` without a size. Never guessed at:
  /// a made-up size becomes a made-up percentage.
  final int? sizeBytes;

  final bool isDirectory;

  @override
  String toString() => 'RemoteFileInfo($sizeBytes bytes, dir: $isDirectory)';
}

/// Moves bytes OFF the machine the daemon lives on.
///
/// The mirror of [RemoteFilePorter], and separate from it for the same reason
/// the two are separate from [RemoteCommandRunner]: a file transfer and a shell
/// command are different jobs, and the surface that is honest about one is a lie
/// about the other.
abstract interface class RemoteFileFetcher {
  /// Streams [absolutePath] out, in order, as fast as the caller consumes it.
  ///
  /// A **Stream** rather than a `Future<Uint8List>` or a sink, because both of
  /// the things that matter here are properties of a stream: a 48 MB APK must
  /// never be resident, and a transfer the user cancels must actually stop.
  /// Cancelling the subscription tears down the file handle and the SFTP
  /// channel; a `Future` would leave the caller with no way to say "stop".
  ///
  /// The chunks carry no framing and no length prefix — concatenating them in
  /// order is the file.
  ///
  /// Throws [HerdrTransportException] with
  /// [TransportFailure.sftpUnavailable] when the host has no SFTP subsystem,
  /// which is a different answer from "the transfer failed".
  Stream<Uint8List> download(String absolutePath);

  /// Reads [absolutePath]'s size and kind without transferring it.
  Future<RemoteFileInfo> statFile(String absolutePath);
}

/// Runs a plain shell command on the machine the daemon lives on.
///
/// Kept separate from [HerdrTransport] deliberately. The transport's job is to
/// carry herdr protocol frames; this exists for the handful of setup questions
/// the API cannot answer about itself — chiefly "where is your socket", which
/// has to be resolved before any protocol traffic is possible.
///
/// Folding it into [HerdrTransport] would put a shell in the path of every
/// protocol call and force every transport (including the pure-socket one) to
/// pretend it can run commands.
abstract interface class RemoteCommandRunner {
  /// Runs [command] and returns its combined stdout.
  ///
  /// Implementations must apply a timeout; a remote shell that never returns
  /// would otherwise hang connection setup indefinitely.
  Future<String> runCommand(String command);
}

/// Starts a command that stays open, with a writable stdin.
///
/// This is how the terminal reaches the daemon. herdr exposes live terminal
/// access as a CLI subcommand (`herdr terminal session control <pane>`), not as
/// a socket method — verified against a live 0.9.0, where `pane.stream` does
/// not exist and the daemon's own method list has no terminal-streaming entry.
/// So the channel is a process, and it needs real duplex stdio.
abstract interface class RemoteStreamRunner {
  /// Starts [command] and returns a duplex channel to it.
  Future<HerdrDuplex> openCommandDuplex(String command);
}
