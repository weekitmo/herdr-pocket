import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transport/shell_transport.dart';

/// The rules [PtySession] owns, tested without a live host.
///
/// WHY THESE AND NOT MORE. The interesting failures in a raw terminal are all
/// SILENT — a transposed window size, a dropped carriage return, a character
/// decoded per chunk — and none of them throws, logs, or looks wrong in a
/// screenshot until you happen to look at the one line where it matters. Each
/// test here pins one of those, because each one is a mistake that is easy to
/// make and impossible to notice.
void main() {
  group('PtySession', () {
    test('a character split across two chunks arrives whole', () async {
      final h = _Harness();
      final seen = <String>[];
      h.session.output.listen(seen.add);

      // The first two bytes of 汉. A per-chunk `utf8.decode` turns these into
      // one replacement character, and the next byte into another — so the
      // failure mode is TWO wrong characters rather than an exception.
      h.bytes.add([0xE6, 0xB1]);
      await pumpEventQueue();
      expect(
        seen,
        isEmpty,
        reason: 'a streaming decoder holds an incomplete character instead of '
            'guessing at it; emitting anything here means it guessed',
      );

      h.bytes.add([0x89]);
      await pumpEventQueue();
      expect(seen.join(), '汉');
      expect(seen.join(), isNot(contains('\uFFFD')));
    });

    test('a Uint8List stream is decoded, not rejected', () async {
      // THE SHAPE dartssh2 ACTUALLY HANDS US, and the one that shipped a broken
      // app: the transport passes `SSHSession.stdout`, which is a
      // `Stream<Uint8List>`. A fake that widens it to `Stream<List<int>>` hides
      // the failure, because `Stream.transform` checks its transformer against
      // the reified type argument — so `Utf8Decoder`, a
      // `StreamTransformer<List<int>, String>`, is rejected at runtime with
      // "not a subtype of StreamTransformer<Uint8List, String>" while the
      // analyser and every other test stay green.
      final bytes = StreamController<Uint8List>();
      final seen = <String>[];
      final session = PtySession(
        stream: bytes.stream,
        write: (_) {},
        resizePty: (_, _) {},
        exitStatus: () async => null,
        dispose: () {},
      );
      session.output.listen(seen.add);

      bytes.add(Uint8List.fromList(utf8.encode('hello 汉')));
      await pumpEventQueue();

      expect(seen.join(), 'hello 汉');
      await bytes.close();
      await session.close();
    });

    test('an emoji split across chunks survives too', () async {
      final h = _Harness();
      final seen = <String>[];
      h.session.output.listen(seen.add);

      final bytes = utf8.encode('🐋'); // four bytes, the longest UTF-8 form
      h.bytes.add(bytes.sublist(0, 3));
      h.bytes.add(bytes.sublist(3));
      await pumpEventQueue();

      expect(seen.join(), '🐋');
    });

    test('bytes that are not UTF-8 do not take the session down', () async {
      final h = _Harness();
      final seen = <String>[];
      Object? error;
      h.session.output.listen(seen.add, onError: (Object e) => error = e);

      // What `cat` on a binary file sends. Refusing to render it would be the
      // tail wagging the dog: a terminal has to draw SOMETHING.
      h.bytes.add([0xFF, 0xFE, 0x41]);
      await pumpEventQueue();

      expect(error, isNull);
      expect(seen.join(), endsWith('A'));
      expect(seen.join(), contains('\uFFFD'));
    });

    test('sendBytes writes exactly what it was given', () {
      final h = _Harness();

      // Enter is \r, not \n. An implementation that helpfully appended a
      // newline would break every single prompt.
      h.session.sendBytes([13]);
      // Up arrow, which is three bytes of escape sequence.
      h.session.sendBytes(const [0x1B, 0x5B, 0x41]);
      // Ctrl-C, which is ONE byte and has no letter in it.
      h.session.sendBytes([3]);

      expect(h.written, [
        [13],
        [0x1B, 0x5B, 0x41],
        [3],
      ]);
    });

    test('sendBytes sends nothing for an empty list', () {
      final h = _Harness();
      h.session.sendBytes(const []);
      expect(h.written, isEmpty);
    });

    test('resize forwards columns before rows', () {
      final h = _Harness();
      h.session.resize(120, 30);

      expect(h.resizes, hasLength(1));
      expect(h.resizes.single.cols, 120);
      expect(h.resizes.single.rows, 30);
      expect(
        h.resizes.single,
        (cols: 120, rows: 30),
        reason: 'dartssh2 takes (width, height); every other API in this app '
            'says (cols, rows). Swapping them is silent — the far end simply '
            'lays out for a 30-column, 120-row window.',
      );
    });

    test('resize refuses a size that is not positive', () {
      final h = _Harness();
      h.session.resize(0, 24);
      h.session.resize(80, 0);
      h.session.resize(-1, -1);

      expect(
        h.resizes,
        isEmpty,
        reason: 'a zero size would reach dartssh2 as an ArgumentError thrown '
            'from a layout callback, which is a crash in the frame pipeline',
      );
    });

    test('the output stream ends when the remote does', () async {
      final h = _Harness();
      var ended = false;
      h.session.output.listen((_) {}, onDone: () => ended = true);

      await h.bytes.close();
      await pumpEventQueue();

      expect(ended, isTrue);
    });

    test('input and resize after the session ends are silently dropped', () async {
      final h = _Harness();
      await h.session.close();

      // The last keypress of a session routinely lands after `exit`. Throwing
      // here would surface as a crash for a keystroke that visibly did nothing.
      expect(() => h.session.sendBytes([13]), returnsNormally);
      expect(() => h.session.resize(80, 24), returnsNormally);

      expect(h.written, isEmpty);
      expect(h.resizes, isEmpty);
    });

    test('input after the REMOTE ended is dropped, without a close()', () async {
      final h = _Harness();
      await h.bytes.close();
      await pumpEventQueue();

      expect(() => h.session.sendBytes([13]), returnsNormally);
      expect(h.written, isEmpty);
    });

    test('exitStatus is forwarded', () async {
      final h = _Harness()..exitCode = 130;

      expect(await h.session.exitStatus, 130);
      expect(h.exitAsked, isTrue);
    });

    test('exitStatus reports null when there was never a code', () async {
      final h = _Harness();
      expect(await h.session.exitStatus, isNull);
    });

    test('close hands the connection back exactly once', () async {
      final h = _Harness();

      await h.session.close();
      await h.session.close();

      expect(h.disposals, 1);
    });

    test('a session that ended by itself is still disposed by close', () async {
      final h = _Harness();
      await h.bytes.close();
      await pumpEventQueue();

      await h.session.close();

      expect(
        h.disposals,
        1,
        reason: 'the remote hanging up is not the same event as us letting go '
            'of the connection, and only the second one disposes',
      );
    });
  });
}

/// A [PtySession] wired to an in-memory stream, recording every outward call.
class _Harness {
  /// Builds the session EAGERLY.
  ///
  /// Not decoration: `StreamController.close()` returns a future that only
  /// completes once something is listening, so a harness that attached to the
  /// byte pipe lazily would hang the moment a test closed the pipe before
  /// touching `session` — a deadlock in the test, not in the code under test.
  _Harness() {
    session = PtySession(
      stream: bytes.stream,
      write: (data) => written.add(data.toList()),
      resizePty: (cols, rows) => resizes.add((cols: cols, rows: rows)),
      exitStatus: () async {
        exitAsked = true;
        return exitCode;
      },
      dispose: () => disposals++,
    );
  }

  final bytes = StreamController<List<int>>();
  final written = <List<int>>[];
  final resizes = <({int cols, int rows})>[];
  int disposals = 0;
  int? exitCode;
  bool exitAsked = false;

  late final PtySession session;
}
