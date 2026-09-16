import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// One screen update from the daemon.
///
/// The daemon RENDERS the terminal for us at the size we asked for; we do not
/// receive a raw PTY stream. Measured frame shape (herdr 0.9.0, protocol 22):
///
/// ```json
/// {"type":"terminal.frame","seq":1,"encoding":"ansi","full":true,
///  "width":100,"height":30,"bytes":"<base64 ANSI>"}
/// ```
///
/// [isFull] means the frame repaints the whole screen. Frames with
/// `full: false` exist, so the consumer needs a real VT state machine rather
/// than "replace the screen with whatever arrived last".
class TerminalFrame {
  const TerminalFrame({
    required this.seq,
    required this.isFull,
    required this.width,
    required this.height,
    required this.data,
  });

  final int seq;
  final bool isFull;
  final int width;
  final int height;

  /// The ANSI text, already base64-decoded and UTF-8-decoded.
  final String data;

  @override
  String toString() =>
      'TerminalFrame(seq=$seq, full=$isFull, ${width}x$height, ${data.length} chars)';
}

/// An open, live view of one pane.
abstract interface class TerminalSession {
  /// Screen updates, in order.
  Stream<TerminalFrame> get frames;

  /// Completes when the daemon ends the stream (the process exited, or another
  /// client took the terminal over).
  Future<void> get done;

  /// Why the stream ended, if the daemon said.
  String? get closeReason;

  /// Sends typed text to the pane.
  void sendText(String text);

  /// Sends raw bytes — control characters, pastes, and anything that is not
  /// valid text.
  void sendBytes(List<int> bytes);

  /// Tells the daemon our viewport changed, so it re-renders at the new size.
  void resize(int cols, int rows);

  /// Scrolls the attached viewport. POSITIVE means back into history.
  ///
  /// The far end takes a positive count plus a direction — it rejects zero
  /// ("terminal.scroll lines must be greater than 0") and has no signed form,
  /// so the sign lives here rather than at every call site.
  void scroll(int lines);

  /// True when this view cannot send input.
  ///
  /// A read-only session still streams frames; it just has no controller
  /// rights. Sending to it is a no-op rather than an error, so a caller that
  /// does not know which kind it holds cannot accidentally take over a pane.
  bool get isReadOnly;

  /// Gives up control and closes the stream.
  Future<void> close();
}

/// Single-quotes a value for the remote shell.
///
/// Pane ids are compact (`w9:p1`) and would survive unquoted today. Quoting
/// them costs nothing and removes any question about what a future id format
/// might contain — and doing it in one place means the `'\''` dance, which is
/// the standard POSIX way to embed a quote, is written once instead of being
/// re-derived at every call site.
String requireSafePaneId(String paneId) {
  // Allow-list rather than quote. Pane ids are `w<ws>:p<pane>` and never hold
  // shell metacharacters, so a value that fails this check is not a pane id at
  // all — and a value that cannot be expressed cannot be mis-quoted. This is
  // both shorter and harder to get wrong than threading a single-quote escape
  // through two command builders.
  if (!_paneIdPattern.hasMatch(paneId)) {
    throw ArgumentError.value(paneId, 'paneId', 'not a valid herdr pane id');
  }
  return paneId;
}

final _paneIdPattern = RegExp(r'^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$');

/// Opens live terminals.
///
/// Static-only and stateless: a session owns its own channel, so there is
/// nothing for a controller object to hold.
abstract final class TerminalControl {
  /// Opens a written terminal on [paneId].
  ///
  /// `--takeover` is used because that is what opening a terminal MEANS: herdr
  /// allows exactly one controller per pane, and a phone client that could not
  /// take over would be read-only in practice. The daemon reports the takeover
  /// to whoever loses it, so the other client is not silently dropped.
  ///
  /// [cols] and [rows] matter more than they look: the daemon renders at
  /// exactly this size, so they should be the real cell grid of the widget
  /// showing the terminal, not a guess.
  /// Opens a READ-ONLY view of [paneId].
  ///
  /// `observe` accepts several watchers at once and never takes input, resize,
  /// scroll or ownership away from anyone. Two consequences worth naming:
  /// a glance at what an agent is doing costs nobody their terminal, and this
  /// is the only variant that is safe to exercise in a test against a live
  /// machine.
  static Future<TerminalSession> observe(
    RemoteStreamRunner runner, {
    required String paneId,
    required int cols,
    required int rows,
  }) async {
    final duplex = await runner.openCommandDuplex(
      '${herdrCommandPrefix}terminal session observe '
      '${requireSafePaneId(paneId)} --cols $cols --rows $rows',
    );
    return _LiveTerminalSession(
      duplex,
      cols: cols,
      rows: rows,
      isReadOnly: true,
    );
  }

  static Future<TerminalSession> open(
    RemoteStreamRunner runner, {
    required String paneId,
    required int cols,
    required int rows,
    bool takeover = true,
  }) async {
    final command = StringBuffer(herdrCommandPrefix)
      ..write('terminal session control ')
      ..write(requireSafePaneId(paneId));
    if (takeover) command.write(' --takeover');
    command
      ..write(' --cols $cols')
      ..write(' --rows $rows');

    final duplex = await runner.openCommandDuplex(command.toString());
    return _LiveTerminalSession(duplex, cols: cols, rows: rows);
  }
}

class _LiveTerminalSession implements TerminalSession {
  _LiveTerminalSession(
    this._duplex, {
    required this.cols,
    required this.rows,
    this.isReadOnly = false,
  }) {
    _sub = _duplex.lines.listen(
      _onLine,
      onError: (Object e, StackTrace st) {
        _frames.addError(e, st);
        unawaited(_frames.close());
      },
      onDone: () {
        unawaited(_frames.close());
      },
    );
  }

  final HerdrDuplex _duplex;
  final _frames = StreamController<TerminalFrame>.broadcast();
  late final StreamSubscription<String> _sub;

  int cols;
  int rows;
  String? _closeReason;

  @override
  bool isReadOnly;

  /// Bytes of a multi-byte UTF-8 scalar that arrived split across frames.
  ///
  /// The daemon renders text and sends it base64'd, so a split is unlikely —
  /// but "unlikely" is how you get silent mojibake in exactly the CJK case this
  /// app exists to get right. Holding the incomplete tail and prepending it to
  /// the next frame costs three lines and removes the class of bug entirely.
  final _pendingBytes = BytesBuilder(copy: false);

  @override
  Stream<TerminalFrame> get frames => _frames.stream;

  @override
  String? get closeReason => _closeReason;

  @override
  Future<void> get done => _duplex.done;

  void _onLine(String line) {
    if (line.isEmpty) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Not protocol we understand; the terminal is stateful, so feeding it
      // unknown bytes would corrupt the screen permanently.
      return;
    }
    if (decoded is! Map) return;

    switch (decoded['type']) {
      case 'terminal.frame':
        final frame = _decodeFrame(decoded);
        if (frame != null && !_frames.isClosed) _frames.add(frame);
      case 'terminal.closed':
        _closeReason =
            decoded['reason'] is String ? decoded['reason']! as String : '';
        unawaited(_frames.close());
    }
  }

  TerminalFrame? _decodeFrame(Map<Object?, Object?> json) {
    final b64 = json['bytes'];
    if (b64 is! String) return null;

    final Uint8List raw;
    try {
      raw = base64.decode(b64);
    } on FormatException {
      return null;
    }

    final text = _decodeUtf8(raw);
    if (text == null) return null;

    return TerminalFrame(
      seq: _asInt(json['seq']) ?? 0,
      isFull: json['full'] == true,
      width: _asInt(json['width']) ?? cols,
      height: _asInt(json['height']) ?? rows,
      data: text,
    );
  }

  /// Decodes UTF-8, carrying an incomplete trailing scalar into the next frame.
  String? _decodeUtf8(Uint8List chunk) {
    _pendingBytes.add(chunk);
    final bytes = _pendingBytes.takeBytes();

    // Find the longest prefix that decodes cleanly. `Utf8Decoder` with
    // allowMalformed:false throws on an incomplete tail, so walk back at most
    // three bytes — a UTF-8 scalar is at most four bytes, so an incomplete
    // tail is at most three.
    for (var trim = 0; trim <= 3 && trim < bytes.length; trim++) {
      final end = bytes.length - trim;
      try {
        final text = utf8.decode(Uint8List.sublistView(bytes, 0, end));
        if (trim > 0) {
          _pendingBytes.add(Uint8List.sublistView(bytes, end));
        }
        return text;
      } on FormatException {
        continue;
      }
    }

    // Nothing decoded: the bytes are genuinely malformed, not merely split.
    // Substitute rather than kill a live terminal over a bad byte.
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  void sendText(String text) {
    if (isReadOnly) return;
    _send({'type': 'terminal.input', 'text': text});
  }

  @override
  void sendBytes(List<int> bytes) {
    if (isReadOnly) return;
    _send({'type': 'terminal.input', 'bytes': base64.encode(bytes)});
  }

  @override
  void resize(int cols, int rows) {
    // The daemon rejects non-positive dimensions outright, so drop them here
    // rather than sending something it will refuse.
    if (cols <= 0 || rows <= 0) return;
    // A read-only observer does not own geometry; the daemon would refuse it.
    if (isReadOnly) return;
    if (cols == this.cols && rows == this.rows) return;
    this.cols = cols;
    this.rows = rows;
    _send({'type': 'terminal.resize', 'cols': cols, 'rows': rows});
  }

  @override
  void scroll(int lines) {
    if (lines == 0 || isReadOnly) return;
    _send({
      'type': 'terminal.scroll',
      'lines': lines.abs(),
      'direction': lines > 0 ? 'up' : 'down',
    });
  }

  void _send(Map<String, Object?> command) {
    if (_frames.isClosed) return;
    _duplex.send(jsonEncode(command));
  }

  @override
  Future<void> close() async {
    // Tell the daemon first, so it releases the pane and re-renders for
    // whoever is next rather than waiting for the socket to time out.
    try {
      if (!isReadOnly) _send({'type': 'terminal.release'});
    } on Object {
      // Best effort: the connection may already be gone.
    }
    await _sub.cancel();
    if (!_frames.isClosed) await _frames.close();
    await _duplex.close();
  }

  static int? _asInt(Object? v) => switch (v) {
        int() => v,
        String() => int.tryParse(v),
        _ => null,
      };
}
