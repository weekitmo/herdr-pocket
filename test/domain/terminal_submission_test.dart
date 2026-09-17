import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/terminal/submission.dart';

/// A clock the test drives by hand.
///
/// The behaviour worth pinning here is about ORDER — the Enter that must wait,
/// the Enter that must be flushed before the next message — and asserting it
/// should not mean sleeping 120 ms per case.
class _FakeSchedule {
  final List<({Duration delay, void Function() action, _Handle handle})> pending =
      [];

  PendingDelay call(Duration delay, void Function() action) {
    final handle = _Handle(this);
    pending.add((delay: delay, action: action, handle: handle));
    return handle;
  }

  /// Runs the oldest scheduled action, as a timer would.
  void fireOldest() {
    final next = pending.first;
    pending.removeAt(0);
    next.action();
  }

  void remove(_Handle handle) => pending.removeWhere((p) => p.handle == handle);
}

class _Handle implements PendingDelay {
  _Handle(this._clock);

  final _FakeSchedule _clock;

  @override
  void cancel() => _clock.remove(this);
}

void main() {
  group('what a message is', () {
    test('text and attachment paths become one line', () {
      const submission = Submission(
        text: 'have a look at this',
        attachmentPaths: ['/home/u/.cache/herdr-pocket/uploads/x.png'],
      );
      expect(
        submission.body,
        'have a look at this /home/u/.cache/herdr-pocket/uploads/x.png',
      );
    });

    test('a message can be nothing but an attachment', () {
      const submission = Submission(
        text: '',
        attachmentPaths: ['/tmp/a.log'],
      );
      expect(submission.body, '/tmp/a.log');
      expect(submission.isEmpty, isFalse);
    });

    test('the space a pick leaves behind is not part of the sentence', () {
      const submission = Submission(text: '/code-review ');
      expect(submission.body, '/code-review');
    });

    test('nothing typed and nothing attached is empty', () {
      expect(const Submission(text: '   ').isEmpty, isTrue);
      expect(const Submission(text: '').isEmpty, isTrue);
      expect(
        const Submission(text: '', attachmentPaths: ['']).isEmpty,
        isTrue,
      );
    });
  });

  group('what the pane receives', () {
    test('a bracketed paste, then an Enter', () {
      final writes = submissionWrites(
        const Submission(text: 'hi'),
        bracketed: true,
      );
      expect(writes, ['\x1b[200~hi\x1b[201~', '\r']);
    });

    test('with bracketed paste off, newlines become returns', () {
      // What a shell prompt expects: three lines of a paste are three commands.
      // With the mode ON the newlines survive, which is what stops a TUI from
      // submitting a paragraph one line at a time.
      final writes = submissionWrites(
        const Submission(text: 'one\ntwo'),
        bracketed: false,
      );
      expect(writes.first, 'one\rtwo');
    });

    test('with bracketed paste on, the newlines are kept', () {
      final writes = submissionWrites(
        const Submission(text: 'one\ntwo'),
        bracketed: true,
      );
      expect(writes.first, '\x1b[200~one\ntwo\x1b[201~');
    });
  });

  group('the Enter is a second write', () {
    test('the paste goes out now and the Enter waits', () {
      final clock = _FakeSchedule();
      final written = <String>[];
      final submitter = Submitter(settle: const Duration(milliseconds: 120), schedule: clock.call);

      submitter.send(
        const Submission(text: 'go'),
        bracketed: true,
        write: written.add,
      );

      expect(written, ['\x1b[200~go\x1b[201~']);
      expect(submitter.hasPendingEnter, isTrue);
      expect(clock.pending.single.delay, const Duration(milliseconds: 120));

      clock.fireOldest();
      expect(written, ['\x1b[200~go\x1b[201~', '\r']);
      expect(submitter.hasPendingEnter, isFalse);
    });

    test('a second message flushes the first one first', () {
      // The bug this prevents: two taps in quick succession producing
      // `one two \r \r`, which submits one run-on line and then presses return
      // again on whatever the pane drew in between.
      final clock = _FakeSchedule();
      final written = <String>[];
      final submitter = Submitter(schedule: clock.call);

      submitter.send(const Submission(text: 'one'), bracketed: true, write: written.add);
      submitter.send(const Submission(text: 'two'), bracketed: true, write: written.add);

      expect(written, [
        '\x1b[200~one\x1b[201~',
        '\r',
        '\x1b[200~two\x1b[201~',
      ]);
      expect(clock.pending, hasLength(1));
    });

    test('an empty message writes nothing at all', () {
      final clock = _FakeSchedule();
      final written = <String>[];
      Submitter(schedule: clock.call).send(
        const Submission(text: ''),
        bracketed: true,
        write: written.add,
      );
      expect(written, isEmpty);
      expect(clock.pending, isEmpty);
    });

    test('leaving the page drops a pending Enter instead of sending it', () {
      // The user has gone, the session is closing, and an Enter arriving after
      // that lands in whatever the desktop has since typed.
      final clock = _FakeSchedule();
      final written = <String>[];
      final submitter = Submitter(schedule: clock.call);

      submitter.send(const Submission(text: 'x'), bracketed: true, write: written.add);
      submitter.dispose();

      expect(clock.pending, isEmpty);
      expect(written, ['\x1b[200~x\x1b[201~']);
    });
  });
}
