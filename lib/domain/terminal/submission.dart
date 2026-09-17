/// Composing a whole message on the phone, then sending it in one go.
///
/// ## What this is for
///
/// The direct input bridge turns each keystroke into its own `terminal.input`
/// message. That is the right shape for a key you press and expect the pane to
/// react to, and the wrong shape for a paragraph typed on a train: every
/// character is a round trip, and a link that drops one leaves the remote
/// shell holding half a sentence with no way to tell which half.
///
/// A composer inverts it. The text is held HERE, the network sees ONE write
/// when the user presses send, and the whole thing either arrives or does not.
/// The pane's own echo is the receipt.
///
/// ## The two writes, and why they are two
///
/// A submission goes out as a [paste][pastePayload] followed by a separate
/// Enter, [kSubmitSettle] later:
///
///  1. **The paste.** With the pane in bracketed paste mode the text arrives
///     wrapped in `ESC[200~ … ESC[201~`, so a message containing newlines is
///     inserted rather than submitted line by line — which is what a TUI needs
///     and what a shell is indifferent to.
///  2. **The Enter, on its own.** Several TUIs decide whether a carriage
///     return is "the user pressed send" or "the last byte of a paste" by
///     timing: a CR that lands in the same read as the paste tail is treated
///     as paste. Sending it as a second write puts a real gap on the wire.
///
/// The gap is safe to take because SSH is an ordered stream: a later write can
/// never overtake an earlier one, so the Enter cannot arrive before its own
/// text however bad the link is. It costs one small message, and it buys the
/// difference between "message sent" and "message sitting in the box".
///
/// A message that is still waiting for its Enter is **flushed before the next
/// message is written**, so two taps in quick succession cannot interleave into
/// `text1 text2 \r \r`.
///
/// PURE DART. The scheduling is injected rather than imported so the sequence
/// can be asserted without waiting on a wall clock; see [Submitter].
library;

import 'dart:async';

import 'package:herdr_pocket/domain/terminal/key_bar.dart';

/// How long the pane is given to finish reading a paste before the Enter lands.
///
/// Long enough to cover a TUI's paste de-bounce, short enough that the user who
/// taps send and then looks at the pane sees it submit rather than wonder. Not a
/// network timeout: the Enter is queued behind its own paste on the same
/// ordered channel, so this is a delay in the RECEIVER's processing, and a
/// 400 ms round trip does not need a longer one.
const Duration kSubmitSettle = Duration(milliseconds: 120);

/// One message, before it is turned into bytes.
///
/// The attachments are **paths, already uploaded**, and they are part of the
/// sentence rather than a hidden property of it: what the composer shows is
/// exactly what goes out. See [body].
class Submission {
  const Submission({required this.text, this.attachmentPaths = const []});

  /// What the user typed. Trailing whitespace is dropped — a message ending in
  /// the space that followed a picked file would otherwise submit a line with a
  /// trailing blank in it.
  final String text;

  /// Absolute paths on the remote machine, in the order they were attached.
  final List<String> attachmentPaths;

  /// The parts that make up the message, in order: the text, then each path.
  ///
  /// Empty parts are dropped rather than joined: attaching a file with nothing
  /// typed is a perfectly ordinary message ("read this"), and so is typing with
  /// nothing attached.
  List<String> get parts => [
    if (text.trim().isNotEmpty) text.trim(),
    ...attachmentPaths.where((p) => p.trim().isNotEmpty),
  ];

  bool get isEmpty => parts.isEmpty;

  /// The message as one line, which is what the pane receives.
  ///
  /// ONE LINE even when the user typed several, and the newlines survive inside
  /// it — they are what bracketed paste is for. Joining the parts with a space
  /// is the whole of the "how do attachments read" decision: an agent handed
  /// `look at this /home/me/.cache/herdr-pocket/uploads/x.png` needs nothing
  /// else, and the alternative (a sentence per file) is noise on every message.
  String get body => parts.join(' ');
}

/// The bytes of one message, in the order they are written.
///
/// [bracketed] comes from the live terminal (`Terminal.bracketedPasteMode`) and
/// is read at send time rather than captured earlier: a TUI turning the mode on
/// is exactly the event that decides how its input box wants multi-line text.
List<String> submissionWrites(
  Submission submission, {
  required bool bracketed,
}) => [pastePayload(submission.body, bracketed: bracketed), '\r'];

/// A pending delayed action that can be called off.
///
/// `Timer` satisfies it as it stands. The interface is here because the tests
/// that matter are about ORDER — flush before the next write, no Enter after
/// dispose — and they should not have to spend 120 ms of real time asserting
/// it.
abstract interface class PendingDelay {
  void cancel();
}

/// Schedules [action] to run after [delay]. The production value is [timedDelay].
typedef ScheduleDelay =
    PendingDelay Function(Duration delay, void Function() action);

/// The real clock.
PendingDelay timedDelay(Duration delay, void Function() action) =>
    _TimerDelay(Timer(delay, action));

/// `Timer`, wearing the interface.
class _TimerDelay implements PendingDelay {
  const _TimerDelay(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// Writes a composed message to a live pane.
///
/// The caller passes the writer with each send rather than handing one to the
/// constructor, and that is deliberate: the delayed Enter must go to **the
/// session the paste went to**. A page that switched panes 100 ms after send
/// has a different session by the time the timer fires, and a writer captured
/// at construction would deliver the Enter into someone else's terminal.
class Submitter {
  Submitter({this.settle = kSubmitSettle, ScheduleDelay? schedule})
    : _schedule = schedule ?? timedDelay;

  /// The gap between the paste and its Enter.
  final Duration settle;

  final ScheduleDelay _schedule;
  PendingDelay? _pending;
  void Function()? _fire;

  /// True while an Enter is waiting for its moment.
  bool get hasPendingEnter => _pending != null;

  /// Sends one message: the paste now, the Enter [settle] later.
  void send(Submission submission, {required bool bracketed, required void Function(String) write}) {
    if (submission.isEmpty) return;
    final writes = submissionWrites(submission, bracketed: bracketed);

    // The previous message's Enter first. Writing the new paste first would put
    // two messages on one line and then submit them with two returns — the
    // second one landing on whatever the pane drew in between.
    flush();

    write(writes.first);
    _fire = () => write(writes.last);
    _pending = _schedule(settle, _run);
  }

  /// Writes a pending Enter immediately, if there is one.
  void flush() {
    if (_pending == null) return;
    final fire = _fire;
    _pending!.cancel();
    _pending = null;
    _fire = null;
    fire?.call();
  }

  /// Drops a pending Enter without writing it.
  ///
  /// What leave-the-page does: the session is being closed, and an Enter sent
  /// into a pane nobody is watching is at best pointless and at worst submits
  /// whatever the user's own shell had typed on the desktop.
  void dispose() {
    _pending?.cancel();
    _pending = null;
    _fire = null;
  }

  void _run() {
    final fire = _fire;
    _pending = null;
    _fire = null;
    fire?.call();
  }
}
