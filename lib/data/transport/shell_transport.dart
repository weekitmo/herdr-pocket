import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';

/// One live PTY on a remote machine.
///
/// WHY THIS IS NOT [HerdrDuplex]. The terminal stream and the herdr stream look
/// similar and share nothing that matters:
///
///   * `HerdrDuplex.send` appends a newline to whatever it is given. In a
///     terminal that is wrong for every single key: Enter is `\r` and not `\n`,
///     arrow keys are `ESC [ A`, and a control character is one byte with no
///     line around it.
///   * `HerdrDuplex.lines` is fed through a [LineFramer] that drops empty
///     lines — and in a terminal a blank line is CONTENT, not framing.
///   * The herdr side is NDJSON, so line boundaries are meaningful there. A
///     shell's output has no framing at all; a newline is just a byte.
///
/// So bytes go in, bytes come out, and the only policy this interface owns is
/// the decision to hand TEXT upward (see [output]).
abstract interface class RemoteShellSession {
  /// Output, decoded incrementally.
  ///
  /// TEXT RATHER THAN BYTES, deliberately. Every consumer of this is a
  /// terminal emulator that takes a `String`, so the decode has to happen
  /// somewhere; putting it here means it happens ONCE, correctly.
  ///
  /// The trap it exists to close: a multi-byte character can be split across
  /// two network chunks, and decoding each chunk on its own turns one `汉`
  /// into two replacement characters. `utf8.decode` per chunk is the wrong
  /// shape and looks right. See [PtySession] for the streaming decoder.
  ///
  /// The stream's `onDone` is the "all output has been delivered" signal —
  /// stronger than the channel closing, which can happen while data is still
  /// queued.
  Stream<String> get output;

  /// Writes [bytes] to the remote process's stdin, exactly as given.
  ///
  /// No newline is appended and nothing is encoded on the way: the caller owns
  /// the byte layout, because in a terminal the caller IS the keyboard.
  void sendBytes(List<int> bytes);

  /// Tells the remote side the window is now [cols] × [rows].
  ///
  /// This is a real `window-change` request, i.e. the far end gets SIGWINCH.
  /// It is what makes a full-screen program (tmux, vim, htop) re-lay itself
  /// out instead of drawing 80 columns into a 40-column window.
  void resize(int cols, int rows);

  /// The remote process's exit code.
  ///
  /// Null means "there was none": the process was killed by a signal, or the
  /// sshd never sent an exit-status. A session that ends must be able to say
  /// WHY — the herdr pane mirror has no such notion, because a pane outlives
  /// every viewer, and a PTY does not.
  Future<int?> get exitStatus;

  /// Ends the session and releases the connection under it.
  Future<void> close();
}

/// Starts a shell on a machine.
abstract interface class RemoteShellRunner {
  /// Opens a PTY of exactly [cols] × [rows] and starts the login shell on it.
  ///
  /// The size is given up front rather than resized afterwards because a shell
  /// that starts at 80×24 and is then resized draws its first screen twice,
  /// and tmux draws its status line in the wrong place while it happens.
  Future<RemoteShellSession> open({required int cols, required int rows});
}

/// Opens PTYs over SSH, on a connection of its OWN.
///
/// WHY A SEPARATE CONNECTION from the one the board rides on. The two have
/// unrelated lifetimes: the board's session lives as long as the app is
/// pointed at a machine, and a terminal lives as long as the user is looking
/// at it. Sharing one client would mean a shell dying every time the board
/// reconnects, and the board holding a channel open for a terminal that was
/// closed twenty minutes ago.
///
/// The extra connection costs one handshake and no extra trust: the host key
/// is already pinned by the time anyone opens a terminal, so the user is never
/// asked about a machine they have already approved.
///
/// It also means the terminal works on a machine that does not run herdr at
/// all — which is the entire point of the feature. Nothing in this file knows
/// that herdr exists.
class SshShellTransport implements RemoteShellRunner {
  SshShellTransport({
    required this.credentials,
    required this.verifyHostKey,
    this.termType = 'xterm-256color',
    this.connectTimeout = const Duration(seconds: 15),
  });

  final SshCredentials credentials;
  final HostKeyVerifier verifyHostKey;

  /// What we tell the remote side we are.
  ///
  /// NOT `dumb`, and not a made-up name: this string decides whether the far
  /// end sends colour, whether it sends `ESC [ ? 25 l` to hide a cursor, and
  /// which terminfo entry full-screen programs read. `xterm-256color` is what
  /// ssh itself sends on a modern machine, and it is the one entry every
  /// distribution ships.
  final String termType;

  final Duration connectTimeout;

  SshDialer get _dialer => SshDialer(
        credentials: credentials,
        verifyHostKey: verifyHostKey,
        connectTimeout: connectTimeout,
      );

  @override
  Future<RemoteShellSession> open({required int cols, required int rows}) async {
    if (cols < 1 || rows < 1) {
      throw ArgumentError('a PTY needs a positive size, got $cols x $rows');
    }

    final client = await _dialer.dial();
    try {
      final session = await client.shell(
        pty: SSHPtyConfig(type: termType, width: cols, height: rows),
      );
      return PtySession(
        stream: session.stdout,
        write: session.stdin.add,
        // NOTE THE ARGUMENT ORDER: dartssh2's `resizeTerminal` takes
        // (width, height) — i.e. columns first — while every other API in this
        // app says (cols, rows) and means the same thing. Passing them the
        // other way round is silent: the far end just lays out for a 24-column
        // 80-row window.
        resizePty: session.resizeTerminal,
        exitStatus: session.waitForExit,
        dispose: () {
          // Closing the session closes the channel; closing the client closes
          // the connection this transport owns. Both, in that order, or the
          // connection leaks for every terminal the user opens.
          session.close();
          unawaited(client.close());
        },
      );
    } on Object catch (e) {
      await client.close();
      throw HerdrTransportException(
        TransportFailure.unknown,
        'could not open a shell on ${credentials.host}',
        cause: e,
      );
    }
  }
}

/// The byte-level adapter, kept separate from the SSH types so its rules can be
/// tested without a live host.
///
/// PUBLIC FOR THAT REASON, not for callers: [SshShellTransport] is the only
/// thing that should ever build one, and everything else should go through
/// [RemoteShellSession].
///
/// Takes the read stream, the write sink, the resize call and the teardown as
/// separate arguments rather than an `SSHSession`, mirroring `_SshDuplex` — the
/// point is that a test can hand it a plain `StreamController` and drive the
/// whole surface with no SSH in the room.
class PtySession implements RemoteShellSession {
  PtySession({
    required Stream<List<int>> stream,
    required this.write,
    required this.resizePty,
    required Future<int?> Function() exitStatus,
    required this.dispose,
  }) : _waitForExit = exitStatus {
    _sub = stream
        // A STREAMING decode, and the whole reason [output] is text.
        //
        // `utf8.decoder` is a `StreamTransformer`: it holds the tail of an
        // incomplete character between chunks, so a `汉` split across two
        // network reads still arrives as one `汉`. Decoding each chunk with
        // `utf8.decode` produces two replacement characters instead, and it
        // does it only on the boundary — i.e. rarely enough to look like a
        // font problem.
        //
        // `allowMalformed` because terminal output is not guaranteed to be
        // text at all: `cat` on a binary file sends bytes that are not UTF-8,
        // and taking down the session over it would be the tail wagging the
        // dog. A replacement character is the honest rendering of a byte that
        // is not a character.
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          _controller.add,
          onError: _controller.addError,
          onDone: () {
            _closed = true;
            _endOutput();
          },
        );
  }

  /// Writes raw bytes. See [RemoteShellSession.sendBytes].
  final void Function(Uint8List data) write;

  /// Forwarded to `SSHSession.resizeTerminal`, which takes (width, height).
  ///
  /// Named `resizePty` rather than `resize` because the interface below
  /// already owns that name, and a field that shadows the method it feeds is
  /// a name that cannot be called.
  final void Function(int cols, int rows) resizePty;

  /// Answers [exitStatus]. Named differently from the parameter that
  /// feeds it because a private named parameter is not a thing in Dart.
  final Future<int?> Function() _waitForExit;
  final void Function() dispose;

  final _controller = StreamController<String>();
  late final StreamSubscription<String> _sub;
  var _closed = false;
  var _disposed = false;

  @override
  Stream<String> get output => _controller.stream;

  @override
  void sendBytes(List<int> bytes) {
    // Silent when the session is over, on purpose: the last keypress of a
    // session very often lands after `exit`, and an exception thrown into a
    // key handler would surface as a crash for a keystroke the user saw do
    // nothing.
    if (_closed || bytes.isEmpty) return;
    write(Uint8List.fromList(bytes));
  }

  @override
  void resize(int cols, int rows) {
    if (_closed) return;
    if (cols < 1 || rows < 1) return;
    resizePty(cols, rows);
  }

  @override
  Future<int?> get exitStatus => _waitForExit();

  @override
  Future<void> close() async {
    // TWO FLAGS, because they mean different things and only one of them is
    // about the caller. `_closed` says "no more traffic" and is also set when
    // the remote end hangs up on its own; `_disposed` says "the connection has
    // been handed back". With one flag, a session that ended by itself and was
    // then closed would tear down its SSH connection twice — and closing twice
    // is the harmless-looking case, while the interesting one is the page
    // closing a session it already saw die.
    if (_closed) {
      _dispose();
      return;
    }
    _closed = true;
    await _sub.cancel();
    _endOutput();
    _dispose();
  }

  /// Ends [output] for anyone listening, and for anyone who listens later.
  ///
  /// NOT AWAITED, and that is the whole point. `StreamController.close()`
  /// returns a future that completes only once a LISTENER has seen the done
  /// event — so on a controller that was never listened to, awaiting it hangs
  /// FOREVER. A terminal page that is closed before it ever paints (the user
  /// backs out during the handshake) would then never reach [dispose], and the
  /// SSH connection this session owns would leak for the life of the app.
  ///
  /// Closing it unawaited is still correct for a live listener: the done event
  /// is delivered either way.
  void _endOutput() {
    if (_controller.isClosed) return;
    unawaited(_controller.close());
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    dispose();
  }
}
