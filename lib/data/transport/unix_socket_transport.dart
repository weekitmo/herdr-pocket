import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_pocket/data/protocol/line_framer.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// Talks to a herdr socket that this process can already reach — a local Unix
/// domain socket, or a `direct-streamlocal` channel some other layer opened
/// and handed over.
///
/// This is not a test double. It is a real transport, used for:
///
///   * integration tests against a live daemon on the development machine,
///     which is how the protocol layer gets verified against reality rather
///     than against a fixture someone wrote from memory;
///   * desktop builds, where there is no SSH hop at all.
///
/// Keeping it in `lib/` rather than `test/` is deliberate: a transport that
/// only exists in tests drifts from the one that ships.
class UnixSocketTransport
    implements HerdrTransport, RemoteCommandRunner, RemoteStreamRunner {
  UnixSocketTransport({
    required this.socketPath,
    this.connectTimeout = const Duration(seconds: 5),
    this.replyTimeout = const Duration(seconds: 15),
  });

  final String socketPath;
  final Duration connectTimeout;
  final Duration replyTimeout;

  @override
  Future<String> roundTrip(String requestLine) async {
    final socket = await _connect();
    final framer = LineFramer();
    final completer = Completer<String>();

    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        try {
          final lines = framer.add(chunk);
          if (lines.isNotEmpty && !completer.isCompleted) {
            completer.complete(lines.first);
          }
        } on Object catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(
            HerdrTransportException(
              TransportFailure.streamClosed,
              'socket failed before a reply arrived',
              cause: e,
            ),
          );
        }
      },
      onDone: () {
        final tail = framer.flush();
        if (tail != null && tail.isNotEmpty && !completer.isCompleted) {
          completer.complete(tail);
        } else if (!completer.isCompleted) {
          completer.completeError(
            HerdrTransportException(
              TransportFailure.streamClosed,
              'daemon closed the socket without replying',
            ),
          );
        }
      },
      cancelOnError: true,
    );

    socket.add(utf8.encode('$requestLine\n'));
    await socket.flush();

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
      // Single-shot: the daemon closes after one reply. Destroy rather than
      // close so a half-open socket cannot linger.
      socket.destroy();
    }
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) async {
    final socket = await _connect();
    socket.add(utf8.encode('$openLine\n'));
    await socket.flush();
    return _SocketDuplex(socket);
  }

  Future<Socket> _connect() async {
    try {
      return await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: connectTimeout,
      );
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.connectFailed,
        'no herdr socket at $socketPath',
        cause: e,
      );
    }
  }

  @override
  Future<void> close() async {
    // Stateless: each operation owns its own socket.
  }

  /// Runs a command locally.
  ///
  /// On desktop, "the machine the daemon lives on" IS this machine, so the
  /// equivalent of an SSH exec is a local shell. Sharing one implementation
  /// with the SSH path is what keeps local and remote behaviour identical
  /// instead of approximately similar.
  @override
  Future<String> runCommand(String command) async {
    try {
      final result = await Process.run(
        '/bin/sh',
        ['-c', command],
      ).timeout(replyTimeout);
      final out = '${result.stdout}${result.stderr}';
      return out;
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'local command failed: $command',
        cause: e,
      );
    }
  }

  /// Starts a long-lived local command with a writable stdin.
  ///
  /// This is how the terminal works on desktop: `herdr terminal session
  /// control` is a process, not a socket method.
  @override
  Future<HerdrDuplex> openCommandDuplex(String command) async {
    try {
      final process = await Process.start('/bin/sh', ['-c', command]);
      return _ProcessDuplex(process);
    } on Object catch (e) {
      throw HerdrTransportException(
        TransportFailure.unknown,
        'could not start the local command: $command',
        cause: e,
      );
    }
  }
}

/// Adapts a child process's stdio into newline-delimited lines.
class _ProcessDuplex implements HerdrDuplex {
  _ProcessDuplex(this._process) {
    _sub = _process.stdout.listen(
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
    // Drain stderr rather than letting it fill an unread pipe buffer and wedge
    // the child. It is surfaced as a stream error only because the terminal
    // protocol itself is stdout-only.
    _errSub = _process.stderr.listen((_) {});
  }

  final Process _process;
  final _framer = LineFramer();
  final _controller = StreamController<String>();
  late final StreamSubscription<List<int>> _sub;
  late final StreamSubscription<List<int>> _errSub;

  @override
  Stream<String> get lines => _controller.stream;

  @override
  void send(String line) => _process.stdin.add(utf8.encode('$line\n'));

  @override
  Future<void> get done => _process.exitCode.then((_) {});

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _errSub.cancel();
    if (!_controller.isClosed) await _controller.close();
    _process.kill();
  }
}

class _SocketDuplex implements HerdrDuplex {
  _SocketDuplex(this._socket) {
    _sub = _socket.listen(
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

  final Socket _socket;
  final _framer = LineFramer();
  final _controller = StreamController<String>();
  late final StreamSubscription<Uint8List> _sub;

  @override
  Stream<String> get lines => _controller.stream;

  @override
  void send(String line) => _socket.add(utf8.encode('$line\n'));

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    _socket.destroy();
  }
}
