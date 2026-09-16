import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/protocol/line_framer.dart';

/// The framer exists because TCP/SSH chunks do not respect message boundaries.
/// These tests are mostly about the failure it prevents, not the happy path.
void main() {
  group('line boundaries', () {
    test('a whole line in one chunk', () {
      final f = LineFramer();
      expect(f.add(utf8.encode('{"a":1}\n')), ['{"a":1}']);
    });

    test('two lines in one chunk arrive as two', () {
      final f = LineFramer();
      expect(f.add(utf8.encode('one\ntwo\n')), ['one', 'two']);
    });

    test('an unterminated tail is buffered, not emitted', () {
      final f = LineFramer();
      expect(f.add(utf8.encode('{"a":')), isEmpty);
      expect(f.bufferedBytes, 5);
      expect(f.add(utf8.encode('1}\n')), ['{"a":1}']);
      expect(f.bufferedBytes, 0);
    });

    test('a line split across three chunks reassembles', () {
      final f = LineFramer();
      expect(f.add(utf8.encode('{"hel')), isEmpty);
      expect(f.add(utf8.encode('lo":')), isEmpty);
      expect(f.add(utf8.encode('"world"}\n')), ['{"hello":"world"}']);
    });

    test('CRLF is accepted and the carriage return stripped', () {
      final f = LineFramer();
      expect(f.add(utf8.encode('one\r\ntwo\r\n')), ['one', 'two']);
    });

    test('blank lines are preserved as empty strings so callers can skip them',
        () {
      final f = LineFramer();
      expect(f.add(utf8.encode('\n\n')), ['', '']);
    });
  });

  group('UTF-8 correctness — the reason this class exists', () {
    test('a multi-byte scalar split across chunks is NOT corrupted', () {
      final f = LineFramer();
      // "中文" is 6 bytes. Split it 1 byte into the second character and again
      // in the middle of the third.
      final bytes = utf8.encode('{"t":"中文"}\n');

      // Feed byte-by-byte: the most hostile possible chunking.
      final out = <String>[];
      for (final b in bytes) {
        out.addAll(f.add([b]));
      }

      expect(out, ['{"t":"中文"}']);
    });

    test('an emoji (4-byte scalar) split across chunks survives', () {
      final f = LineFramer();
      final bytes = utf8.encode('hi 👋\n');
      final out = <String>[];
      for (final b in bytes) {
        out.addAll(f.add([b]));
      }
      expect(out, ['hi 👋']);
    });

    test('the naive per-chunk decode would have corrupted this', () {
      // Documents the bug being prevented: decoding the first chunk alone
      // yields a replacement character, and those bytes are gone.
      final whole = utf8.encode('中');
      final firstHalf = whole.sublist(0, 1);
      final naive = utf8.decode(firstHalf, allowMalformed: true);
      expect(naive, '\u{FFFD}');
      expect(naive.contains('中'), isFalse);

      // The framer, given the same split, gets it right.
      final f = LineFramer();
      expect(f.add(firstHalf), isEmpty);
      expect(f.add([...whole.sublist(1), 0x0A]), ['中']);
    });

    test('a complete line with malformed UTF-8 raises rather than substituting',
        () {
      final f = LineFramer();
      // 0xFF is never valid UTF-8; the line is complete, so this is corruption,
      // not a split scalar.
      expect(
        () => f.add(<int>[0x22, 0xFF, 0x22, 0x0A]),
        throwsA(isA<LineFramingException>()),
      );
    });
  });

  group('guards', () {
    test('a runaway line is refused instead of buffered forever', () {
      final f = LineFramer(maxLineBytes: 16);
      expect(
        () => f.add(List<int>.filled(32, 0x41)),
        throwsA(isA<LineFramingException>()),
      );
    });

    test('flush emits a final line that lacked a trailing newline', () {
      final f = LineFramer();
      expect(f.add(utf8.encode('{"last":true}')), isEmpty);
      expect(f.flush(), '{"last":true}');
      expect(f.flush(), isNull, reason: 'flushing twice must not repeat');
    });

    test('empty chunks are ignored', () {
      final f = LineFramer();
      expect(f.add(Uint8List(0)), isEmpty);
      expect(f.bufferedBytes, 0);
    });
  });
}
