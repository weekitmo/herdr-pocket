import 'dart:convert';
import 'dart:typed_data';

/// Raised when a stream cannot be interpreted as UTF-8 NDJSON.
class LineFramingException implements Exception {
  LineFramingException(this.message);
  final String message;
  @override
  String toString() => 'LineFramingException: $message';
}

/// Assembles newline-delimited text from arbitrarily-chunked bytes.
///
/// WHY THIS IS NOT A ONE-LINER: TCP and SSH channel data arrive in chunks that
/// have nothing to do with message boundaries. Decoding each chunk
/// independently (`utf8.decode(chunk)`) corrupts any multi-byte scalar that
/// straddles a boundary — the incomplete tail becomes U+FFFD **and its bytes
/// are consumed**, so no amount of concatenating later can reconstitute the
/// character. Agent output is full of non-ASCII (paths, CJK, box drawing), so
/// this is not a theoretical concern; it is silent, permanent data corruption.
///
/// Both reference implementations do byte-accurate line assembly for exactly
/// this reason. So does this.
///
/// The rule: **accumulate bytes, decode only at `\n`**.
class LineFramer {
  LineFramer({this.maxLineBytes = 1 << 20});

  /// Refuse to buffer a single line larger than this.
  ///
  /// herdr drops event lines over 1 MiB rather than truncating them, so a line
  /// that large means something is wrong. Bounding it turns a slow OOM into a
  /// clear error.
  final int maxLineBytes;

  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Number of bytes held for the current, still-incomplete line.
  int get bufferedBytes => _pending.length;

  /// Feeds a chunk of bytes and returns every COMPLETE line it completed.
  ///
  /// The terminator is stripped. A `\r\n` pair has the `\r` removed too, so
  /// callers never see a stray carriage return.
  List<String> add(List<int> chunk) {
    if (chunk.isEmpty) return const [];

    final lines = <String>[];
    var start = 0;

    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0A) continue; // not '\n'

      if (start < i) _pending.add(chunk.sublist(start, i));
      lines.add(_takeLine());
      start = i + 1;
    }

    final remainder = chunk.length - start;
    if (remainder > 0) {
      if (_pending.length + remainder > maxLineBytes) {
        _pending.clear();
        throw LineFramingException(
          'line exceeded $maxLineBytes bytes without a newline; '
          'the stream is not NDJSON',
        );
      }
      _pending.add(chunk.sublist(start));
    }

    return lines;
  }

  /// Decodes and clears the buffered line. An empty buffer yields an empty
  /// string, which callers drop as a keep-alive blank line.
  String _takeLine() {
    final bytes = _pending.takeBytes();
    if (bytes.isEmpty) return '';

    // Trim a single trailing '\r' so CRLF transports read the same as LF.
    final end = bytes[bytes.length - 1] == 0x0D ? bytes.length - 1 : bytes.length;
    final slice = Uint8List.sublistView(bytes, 0, end);
    if (slice.isEmpty) return '';

    try {
      return utf8.decode(slice);
    } on FormatException catch (e) {
      // The line is complete, so this is real corruption rather than a split
      // scalar. Surfacing it beats substituting replacement characters into a
      // JSON document that will then fail to parse in a more confusing way.
      throw LineFramingException('invalid UTF-8 in a complete line: ${e.message}');
    }
  }

  /// Any bytes left after the stream ends, treated as a final line.
  ///
  /// Some servers close without a trailing newline on the last record. Dropping
  /// those bytes would silently lose the final frame — for a terminal stream
  /// that is the frame that says the process exited.
  String? flush() {
    if (_pending.isEmpty) return null;
    return _takeLine();
  }
}
