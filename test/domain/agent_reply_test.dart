import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_question.dart';
import 'package:herdr_pocket/domain/agent/agent_reply.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// How a reply reaches the pane.
///
/// The rule under test comes from herdrup's `InputIntent`: send INTENT, not
/// keystrokes — but only where an intent exists. A menu has no composer to
/// submit to, and `agent.prompt` is refused outright while an agent is blocked,
/// so the mode is chosen explicitly instead of one path with a fallback.
void main() {
  group('planTextReply', () {
    test('a working agent gets a real prompt', () {
      final plan = planTextReply(
        paneId: 'w1:p1',
        agentKind: 'claude',
        isAwaitingMenu: false,
        text: 'run the tests',
      );
      expect((plan as TextReplyReady).intent, isA<ReplySubmit>());
    });

    test('a menu gets text typed, never submitted', () {
      // `agent.prompt` answers `agent_blocked` here and sends NOTHING, so the
      // only way in is the menu's own free-text field — and that field must not
      // be submitted by us, because Enter in a menu picks whatever is
      // highlighted.
      final plan = planTextReply(
        paneId: 'w1:p1',
        agentKind: 'claude',
        isAwaitingMenu: true,
        text: 'use the second option',
      );
      expect((plan as TextReplyReady).intent, isA<ReplyTypeOnly>());
    });

    test('a plain shell gets text typed, never submitted', () {
      final plan = planTextReply(
        paneId: 'w1:p1',
        agentKind: '',
        isAwaitingMenu: false,
        text: 'git status',
      );
      // Typing must never execute anything anywhere.
      expect((plan as TextReplyReady).intent, isA<ReplyTypeOnly>());
    });

    test('a newline is refused where it would submit itself', () {
      final plan = planTextReply(
        paneId: 'w1:p1',
        agentKind: '',
        isAwaitingMenu: false,
        text: 'rm -rf build\n',
      );
      expect((plan as TextReplyRefused).reason, ReplyRefusal.multiline);
    });

    test('a newline is fine when the daemon owns the submission', () {
      // `agent.prompt` honours bracketed paste, so a multi-line prompt is a
      // normal thing to send to an agent — the refusal above is about typing,
      // not about prompting.
      final plan = planTextReply(
        paneId: 'w1:p1',
        agentKind: 'claude',
        isAwaitingMenu: false,
        text: 'first\nsecond',
      );
      expect((plan as TextReplyReady).intent, isA<ReplySubmit>());
    });

    test('empty text is refused, not sent', () {
      // An empty submission is a bare Enter to several agents — i.e. a
      // confirmation of whatever the menu happens to be highlighting.
      final plan = planTextReply(
        paneId: 'w1:p1',
        agentKind: 'claude',
        isAwaitingMenu: false,
        text: '   ',
      );
      expect((plan as TextReplyRefused).reason, ReplyRefusal.empty);
    });

    test('no pane is a refusal, not a crash', () {
      final plan = planTextReply(
        paneId: '',
        agentKind: 'claude',
        isAwaitingMenu: false,
        text: 'hello',
      );
      expect((plan as TextReplyRefused).reason, ReplyRefusal.noTarget);
    });
  });

  group('containsSubmitChar', () {
    test('finds a bare CR and a bare LF', () {
      expect(containsSubmitChar('a\rb'), isTrue);
      expect(containsSubmitChar('a\nb'), isTrue);
    });

    test('finds CRLF, which is ONE grapheme cluster', () {
      // Scanning characters would see a single unit here; the scan has to run
      // over unicode scalars or a smuggled Windows newline gets through.
      expect(containsSubmitChar('a\r\nb'), isTrue);
    });

    test('plain text is not a submission', () {
      expect(containsSubmitChar('git commit -m "x"'), isFalse);
    });
  });

  group('isPromptBlocked', () {
    test('a blocked status blocks the prompt even with no menu flag', () {
      // Stock herdr 0.9.0 never sends `input_pending`. Without this half, a
      // blocked agent would be routed to `agent.prompt`, the daemon would
      // refuse it with `agent_blocked`, and nothing would be sent — on the one
      // case the feature exists for.
      expect(
        isPromptBlocked(inputPending: false, status: const AgentBlocked()),
        isTrue,
      );
    });

    test('a menu flag blocks it while the status still reads working', () {
      expect(
        isPromptBlocked(inputPending: true, status: const AgentWorking()),
        isTrue,
      );
    });

    test('a live agent with nothing in the way does not block it', () {
      expect(
        isPromptBlocked(inputPending: false, status: const AgentWorking()),
        isFalse,
      );
    });

    test('an unreadable status does not block it', () {
      // "I cannot tell" must not silently downgrade every reply to keystrokes;
      // the daemon still gets to refuse, and that refusal is reported.
      expect(
        isPromptBlocked(inputPending: false, status: const AgentIndefinite()),
        isFalse,
      );
    });
  });

  group('keysForOption', () {
    test('a menu digit is the whole answer', () {
      // Adding Enter here would confirm a second time, against whatever the
      // agent shows next.
      const option = AgentOption(key: '1', label: 'Yes');
      expect(keysForOption(option), ['1']);
    });

    test('an inline y/n needs the return too', () {
      const option = AgentOption(key: 'y', label: 'y', needsEnter: true);
      expect(keysForOption(option), ['y', 'enter']);
    });
  });
}
