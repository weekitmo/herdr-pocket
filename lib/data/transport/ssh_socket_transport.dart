import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:herdr_pocket/data/protocol/line_framer.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';

/// Reaches the daemon's Unix socket through an SSH `direct-streamlocal`
/// channel.
///
/// WHY THIS SHAPE: herdr's API socket lives on the user's machine and is not
/// exposed to the network. The obvious bridge — run a helper binary that
/// relays stdio to the socket — requires that helper to exist, and the one the
/// iOS reference uses (`herdr api-bridge`) is FORK-ONLY: upstream herdr 0.9.0
/// answers `unknown command: api-bridge` and exits 2.
///
/// `direct-streamlocal@openssh.com` needs no helper at all. dartssh2 4.1.0
/// implements it (`SSHClient.forwardLocalUnix`), which is precisely the
/// capability the iOS app lacked — its SSH stack (swift-nio-ssh) does not
/// implement this channel type, which is why it was pushed onto the fork.
///
/// Caveat worth surfacing in the UI: the server must permit stream-local
/// forwarding. OpenSSH allows it by default; `AllowStreamLocalForwarding no`
/// turns it off, and we report that as [TransportFailure.forwardingRefused].
class SshSocketTransport
    implements
        HerdrTransport,
        RemoteCommandRunner,
        RemoteStreamRunner,
        RemoteFilePorter,
        RemoteFileFetcher {
  SshSocketTransport({
    required this.credentials,
    required this.socketPath,
    required this.verifyHostKey,
    this.connectTimeout = const Duration(seconds: 15),
    this.replyTimeout = const Duration(seconds: 15),
  });

  final SshCredentials credentials;

  /// Absolute path to the daemon socket ON THE REMOTE HOST, e.g.
  /// `/home/you/.config/herdr/herdr.sock`.
  final String socketPath;

  final HostKeyVerifier verifyHostKey;
  final Duration connectTimeout;
  final Duration replyTimeout;

  SSHClient? _client;
  Future<SSHClient>? _connecting;

  /// Bumped by [close]. A connect that resolves after its starting generation
  /// is stale: close() has already torn down and believes there is no live
  /// session, so the resolved client must be reaped rather than installed.
  /// Without this, a handshake completing exactly as the user disconnects
  /// re-installs a live session behind close()'s back and leaks it.
  int _generation = 0;

  bool get isConnected => _client != null;

  /// Connects, or returns the existing client. Concurrent callers share one
  /// attempt rather than each opening — and leaking — their own session.
  Future<SSHClient> _connected() async {
    final existing = _client;
    if (existing != null) return existing;

    final inFlight = _connecting;
    if (inFlight != null) return await inFlight;

    final generation = _generation;
    final future = _connect();
    _connecting = future;
    try {
      final client = await future;
      if (generation != _generation) {
        // close() happened while we were handshaking. Do not adopt it.
        await client.close();
        throw HerdrTransportException(
          TransportFailure.streamClosed,
          'connection was closed while connecting',
        );
      }
      _client = client;
      return client;
    } finally {
      _connecting = null;
    }
  }

  Future<SSHClient> _connect() => _dialer.dial();

  /// The dial itself lives in `ssh_dial.dart`, because the shell transport
  /// opens the same connection for a completely different purpose. Each
  /// caller gets its OWN client from it: sharing one would tie a terminal's
  /// lifetime to the board's.
  SshDialer get _dialer => SshDialer(
        credentials: credentials,
        verifyHostKey: verifyHostKey,
        connectTimeout: connectTimeout,
      );

  @override
  Future<String> roundTrip(String requestLine) async {
    final channel = await _openChannel();
    final framer = LineFramer();
    final completer = Completer<String>();
    late StreamSubscription<Uint8List> sub;

    void finish(String line) {
      if (completer.isCompleted) return;
      completer.complete(line);
    }

    void fail(Object error) {
      if (completer.isCompleted) return;
      completer.completeError(error);
    }

    sub = channel.stream.listen(
      (chunk) {
        try {
          final lines = framer.add(chunk);
          if (lines.isNotEmpty) {
            // Exactly one reply per connection; anything after it is a bug on
            // the far side and not worth reading.
            finish(lines.first);
          }
        } on Object catch (e) {
          fail(e);
        }
      },
      onError: (Object e) => fail(
        HerdrTransportException(
          TransportFailure.streamClosed,
          'channel failed before a reply arrived',
          cause: e,
        ),
      ),
      onDone: () {
        final tail = framer.flush();
        if (tail != null && tail.isNotEmpty) {
          finish(tail);
        } else {
          fail(
            HerdrTransportException(
              TransportFailure.streamClosed,
              'daemon closed the connection without replying',
            ),
          );
        }
      },
      cancelOnError: true,
    );

    try {
      channel.sink.add(utf8.encode('$requestLine\n'));
    } on Object catch (e) {
      await sub.cancel();
      channel.destroy();
      throw HerdrTransportException(
        TransportFailure.streamClosed,
        'could not write the request',
        cause: e,
      );
    }

    try {
      return await completer.future.timeout(
        replyTimeout,
        onTimeout: () => throw HerdrTransportException(
          TransportFailure.timeout,
          'no reply within ${replyTimeout.inSeconds}s',
        ),
      );
    } finally {
      await sub.cancel();
      // The API socket is single-shot: the daemon closes after one reply, and
      // holding the channel open would leak one channel per request.
      channel.destroy();
    }
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) async {
    final channel = await _openChannel();
    channel.sink.add(utf8.encode('$openLine\n'));
    return _SshDuplex(
      stream: channel.stream,
      write: (data) => channel.sink.add(data),
      whenDone: channel.done,
      dispose: channel.destroy,
    );
  }

  Future<SSHForwardChannel> _openChannel() async {
    final client = await _connected();
    try {
      return await client
          .forwardLocalUnix(socketPath)
          .timeout(connectTimeout);
    } on SSHError catch (e) {
      throw HerdrTransportException(
        TransportFailure.forwardingRefused,
        'the SSH server refused to forward to $socketPath',
        cause: e,
      );
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.forwardingRefused,
        'could not open a channel to $socketPath',
        cause: e,
      );
    }
  }

  /// Starts a long-lived remote command with a writable stdin.
  ///
  /// Used for `herdr terminal session control`, which stays open for as long as
  /// the user is looking at the terminal and reads newline-delimited JSON
  /// commands on stdin.
  @override
  Future<HerdrDuplex> openCommandDuplex(String command) async {
    final client = await _connected();
    try {
      // No PTY: the terminal protocol is newline-delimited JSON on both sides,
      // and allocating a pty would make the remote end line-buffer and echo,
      // corrupting the framing.
      final session = await client.execute(command);
      return _SshDuplex(
        stream: session.stdout,
        write: session.stdin.add,
        whenDone: session.done,
        dispose: session.close,
      );
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'could not start the remote command: $command',
        cause: e,
      );
    }
  }

  /// Runs a shell command on the remote host.
  ///
  /// Used ONLY for connection setup — resolving `$HOME` so we know where the
  /// socket is. Protocol traffic never goes through here: a command channel per
  /// call would be slower than the forwarding channel and would put a shell
  /// between this client and the daemon.
  @override
  Future<String> runCommand(String command) async {
    final client = await _connected();
    try {
      final output = await client.run(command).timeout(replyTimeout);
      // A diagnostic string, not a protocol frame, so malformed bytes are
      // substituted rather than thrown — refusing to report an error message
      // because the error message was not valid UTF-8 would be absurd.
      return utf8.decode(output, allowMalformed: true);
    } on HerdrTransportException {
      rethrow;
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'remote command failed: $command',
        cause: e,
      );
    }
  }

  /// How long to wait for an SFTP channel to go away before abandoning it.
  ///
  /// Measured healthy close: 1 ms. This is a leash, not a budget.
  static const _sftpCloseGrace = Duration(seconds: 2);

  /// Closes [sftp], giving up after [_sftpCloseGrace].
  ///
  /// ## The hang this exists to prevent
  ///
  /// Measured against the throwaway sshd from `tool/test_sshd.sh`, which
  /// generates a config with no `Subsystem` line:
  ///
  /// ```text
  ///   14 ms   client.sftp()   OK                 ← optimistic, see _openSftp
  /// 4011 ms   sftp.handshake  TimeoutException   ← detection works
  /// 4009 ms   sftp.close()    TimeoutException   ← CLEANUP NEVER COMPLETES
  /// ```
  ///
  /// So `await sftp.close()` on the refusal path is itself the hang. The server
  /// answers the subsystem request with a failure and tears the channel down;
  /// `SftpClient.close()` waits for a close confirmation that is never coming.
  ///
  /// Awaiting it unconditionally converts a correct, fast, well-classified
  /// failure into a spinner that never stops — which is exactly the bug this
  /// whole routine was written to remove, reintroduced one line later. The first
  /// version of this code did that, and the test caught it only because it
  /// asserted on ELAPSED TIME rather than on the exception type.
  ///
  /// Every close in this file goes through here for that reason. Leaking one
  /// channel on a host that has no SFTP anyway is strictly better than hanging.
  static Future<void> _closeSftp(SftpClient sftp) async {
    try {
      await sftp.close().timeout(_sftpCloseGrace);
    } on Object {
      // Deliberately swallowed: there is nothing a caller can do about a
      // channel that will not close, and it must not become the error the user
      // sees. The real failure has already been thrown, or is about to be.
    }
  }

  /// Opens an SFTP subsystem channel, and PROVES it opened.
  ///
  /// The second half is the whole point. `SSHClient.sftp()` returns an
  /// `SftpClient` as soon as the channel exists, WITHOUT waiting for the server
  /// to answer the subsystem request — so against a host whose `sshd_config`
  /// has no `Subsystem` line, it hands back an object that looks completely
  /// normal (in 14 ms) and then never completes its handshake. Every subsequent
  /// call on it blocks forever.
  ///
  /// That is not a theoretical failure. `tool/test_sshd.sh` generates exactly
  /// such a config (verified: `sshd -T` reports zero subsystems), and the first
  /// version of `tool/probe_sftp.dart` hung for five minutes with no output
  /// because it trusted `sftp()`.
  ///
  /// Wrapping the whole thing in `try { … } catch` does NOT help: nothing is
  /// thrown, there is just a future that never resolves. Awaiting
  /// [SftpClient.handshake] is the only thing that distinguishes "SFTP works"
  /// from "SFTP was refused", so it is done here, once, for every caller.
  ///
  /// The deadline is [replyTimeout] because a handshake IS a control-plane
  /// round trip. The transfer that follows is not, and must never be given this
  /// deadline — a 48 MB file legitimately takes longer than 15 s on a slow
  /// link, and timing it out halfway is worse than refusing it up front.
  Future<SftpClient> _openSftp(SSHClient client) async {
    final SftpClient sftp;
    try {
      sftp = await client.sftp().timeout(replyTimeout);
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'could not open the SFTP subsystem',
        cause: e,
      );
    }

    try {
      await sftp.handshake.timeout(replyTimeout);
    } on Object catch (e) {
      // NOT awaited. See [_closeSftp]: on the refusal path this close is what
      // hangs, so we ask and move on rather than waiting for an answer.
      unawaited(_closeSftp(sftp));
      throw HerdrTransportException(
        TransportFailure.sftpUnavailable,
        'the server did not answer the SFTP subsystem request — the host '
        'probably has no `Subsystem sftp` line in its sshd_config',
        cause: e is TimeoutException ? null : e,
      );
    }

    return sftp;
  }

  /// Runs [body] with a proved-working SFTP channel and closes it afterwards.
  ///
  /// The `finally` is what makes this worth extracting: an SFTP channel that is
  /// not closed occupies a subsystem process on the far end, and a user who
  /// downloads ten files should not leave ten of them running.
  Future<T> _withSftp<T>(Future<T> Function(SftpClient sftp) body) async {
    final client = await _connected();
    final sftp = await _openSftp(client);
    try {
      return await body(sftp);
    } on HerdrTransportException {
      rethrow;
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'SFTP request failed',
        cause: e,
      );
    } finally {
      await _closeSftp(sftp);
    }
  }

  /// Uploads over SFTP, on the connection that is already open.
  ///
  /// SFTP rather than a base64 shell pipeline: it is one subsystem channel
  /// instead of an argv with a size limit, and `dartssh2` ships the client, so
  /// this costs a dependency we already have rather than a new one.
  @override
  Future<void> uploadBytes({
    required String absolutePath,
    required List<int> bytes,
  }) async {
    _requireAbsolute(absolutePath);

    // The deadline stays on THIS one: an upload is a single bounded write whose
    // size the client already knows, so a stall is a stall. A download has no
    // such guarantee, which is why [download] is shaped differently.
    await _withSftp((sftp) async {
      final file = await sftp
          .open(
            absolutePath,
            mode: SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.truncate,
          )
          .timeout(replyTimeout);
      try {
        await file.writeBytes(Uint8List.fromList(bytes)).timeout(replyTimeout);
      } finally {
        await file.close();
      }
    });
  }

  /// Streams a remote file out, in order, for as long as the caller listens.
  ///
  /// ## Why this is an `async*` generator and not a sink
  ///
  /// Cancellation. A 48 MB APK on a cellular link is a transfer the user may
  /// well abandon, and the only thing in Dart that reliably unwinds on abandon
  /// is a cancelled stream subscription: the `finally` blocks below run, the
  /// file handle closes, and the SFTP channel closes. A `Future`-returning API
  /// would leave a running transfer with nobody listening.
  ///
  /// ## Why there is no overall deadline
  ///
  /// [replyTimeout] governs control-plane round trips and must not be applied
  /// here — the whole point is that a large file takes as long as it takes.
  /// Liveness instead comes from the caller, who is streaming into something and
  /// can stop. The handshake still has a deadline, and `open`/`stat` still do,
  /// because those are round trips.
  @override
  Stream<Uint8List> download(String absolutePath) async* {
    _requireAbsolute(absolutePath);

    final client = await _connected();
    final sftp = await _openSftp(client);
    try {
      // `mode` is omitted on purpose: SFTP's default open mode IS read, and
      // saying it again invites a reader to believe something else is possible
      // here.
      final file = await sftp.open(absolutePath).timeout(replyTimeout);
      try {
        // `read()` with no length stats the file and stops at its reported
        // size, and it pipelines up to 64 outstanding requests — which on a
        // high-latency link is the difference between "one round trip per
        // 16 KiB" and a transfer that keeps the link busy.
        yield* file.read();
      } finally {
        await file.close();
      }
    } on HerdrTransportException {
      rethrow;
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'could not download $absolutePath',
        cause: e,
      );
    } finally {
      // Runs on cancellation too, which is the reason this shape was chosen —
      // and it is BOUNDED, because on a channel the peer has already dropped
      // this close is another thing that never completes.
      await _closeSftp(sftp);
    }
  }

  @override
  Future<RemoteFileInfo> statFile(String absolutePath) async {
    _requireAbsolute(absolutePath);
    final attrs = await _withSftp(
      (sftp) => sftp.stat(absolutePath).timeout(replyTimeout),
    );
    return RemoteFileInfo(
      sizeBytes: attrs.size,
      isDirectory: attrs.isDirectory,
    );
  }

  /// Rejects a relative path rather than guessing a base directory.
  ///
  /// Shared by every SFTP entry point because the failure is identical in all
  /// of them: SFTP does not expand `~`, so a relative path silently resolves
  /// against the subsystem's working directory and the user is left asking
  /// where their file went.
  static void _requireAbsolute(String path) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(
        path,
        'absolutePath',
        'must be absolute — SFTP does not expand ~ and a relative path would '
            'land in the subsystem working directory',
      );
    }
  }

  @override
  Future<void> close() async {
    // Bump first, then snapshot-and-clear. Awaiting the old client's close is a
    // suspension point; clearing afterwards would discard a legitimate
    // reconnect that landed during it.
    _generation++;
    _connecting = null;
    final client = _client;
    _client = null;
    await client?.close();
  }
}

/// Adapts a byte duplex from any source (a forwarded socket, or a process's
/// stdio) into newline-delimited lines.
///
/// Takes the read stream, the write sink and the teardown as separate
/// arguments rather than an `SSHSocket`, because the two things it wraps are
/// not the same type: a forwarded channel is an `SSHSocket` while an exec'd
/// session is an `SSHSession`. They agree on behaviour and not on type, and
/// widening to their shared behaviour is cheaper than an adapter per source.
class _SshDuplex implements HerdrDuplex {
  _SshDuplex({
    required Stream<Uint8List> stream,
    required this.write,
    required this.whenDone,
    required this.dispose,
  }) {
    _sub = stream.listen(
      (chunk) {
        try {
          for (final line in _framer.add(chunk)) {
            if (line.isNotEmpty) _controller.add(line);
          }
        } on Object catch (e, st) {
          _controller.addError(e, st);
        }
      },
      onError: _controller.addError,
      onDone: () {
        final tail = _framer.flush();
        if (tail != null && tail.isNotEmpty) _controller.add(tail);
        unawaited(_controller.close());
      },
    );
  }

  /// Writes raw bytes to the far side. Typed as [Uint8List] rather than
  /// [List] because the two sources disagree: a session's stdin sink takes a
  /// `Uint8List` while a forwarded channel's sink takes any `List<int>`.
  /// Narrowing to the more specific type lets both be passed with at most a
  /// one-line closure.
  final void Function(Uint8List data) write;

  final Future<void> whenDone;
  final void Function() dispose;

  final _framer = LineFramer();
  final _controller = StreamController<String>();
  late final StreamSubscription<Uint8List> _sub;

  @override
  Stream<String> get lines => _controller.stream;

  @override
  void send(String line) => write(utf8.encode('$line\n'));

  @override
  Future<void> get done => whenDone;

  @override
  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    dispose();
  }
}
