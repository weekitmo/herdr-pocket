import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/reply_guard.dart';

/// The re-read that stands between a stale screen and a live keystroke.
///
/// Every case below is a way "press the button the user saw" could press
/// something else instead.
void main() {
  AgentInfo info({
    String paneId = 'w1:p1',
    String? status = 'blocked',
    String? lastKnown,
    bool inputPending = false,
    int? seq,
  }) {
    return AgentInfo.fromJson({
      'pane_id': paneId,
      'agent': 'claude',
      'agent_status': status,
      if (lastKnown != null) 'last_known_status': lastKnown,
      if (inputPending) 'input_pending': true,
      if (seq != null) 'state_change_seq': seq,
    });
  }

  test('still waiting and unmoved is safe', () {
    expect(
      judgeReplySafety(before: info(seq: 10), paneIsLive: true, after: info(seq: 10)),
      ReplySafety.safe,
    );
  });

  test('a different state_change_seq stops the send', () {
    // The server's own counter moved between the read and the send, so the
    // question on screen may not be the one we are about to answer.
    expect(
      judgeReplySafety(before: info(seq: 10), paneIsLive: true, after: info(seq: 11)),
      ReplySafety.changed,
    );
  });

  test('an absent counter does NOT block the send', () {
    // `state_change_seq` is optional on older daemons. Treating "we cannot see
    // a change" as "nothing changed" is the inference this codebase refuses
    // elsewhere; treating it as "changed" would break every send on a server
    // that never sends the field. The status is still checked independently.
    expect(
      judgeReplySafety(before: info(), paneIsLive: true, after: info()),
      ReplySafety.safe,
    );
  });

  test('an agent that is no longer waiting is not answered', () {
    // Someone (or something) already answered, or it resumed by itself.
    // Typing now lands in whatever it is doing instead.
    expect(
      judgeReplySafety(
        before: info(seq: 10),
        paneIsLive: true,
        after: info(status: 'working', seq: 11),
      ),
      ReplySafety.noLongerWaiting,
    );
  });

  test('a finished agent is not answered', () {
    expect(
      judgeReplySafety(
        before: info(seq: 10),
        paneIsLive: true,
        after: info(status: 'idle', seq: 12),
      ),
      ReplySafety.noLongerWaiting,
    );
  });

  test('a vanished pane is gone, not changed', () {
    expect(
      judgeReplySafety(before: info(seq: 10), paneIsLive: false, after: info(seq: 10)),
      ReplySafety.gone,
    );
  });

  test('a missing row is gone even if the census still lists the pane', () {
    expect(
      judgeReplySafety(before: info(seq: 10), paneIsLive: true, after: null),
      ReplySafety.gone,
    );
  });

  test('a different pane id is a change, not a match', () {
    // `pane.move` assigns a NEW public id and keeps the old one as an alias, so
    // the identity is re-checked rather than assumed from the id we asked with.
    expect(
      judgeReplySafety(
        before: info(seq: 10),
        paneIsLive: true,
        after: info(paneId: 'w1:p9', seq: 10),
      ),
      ReplySafety.changed,
    );
  });

  test('a menu still counts as waiting even without the blocked status', () {
    // The escalation the board already relies on: `input_pending` puts a row in
    // needsYou while its status says something else. The guard has to agree
    // with the board, or a send would be refused for a question we are showing.
    expect(
      judgeReplySafety(
        before: info(status: 'working', inputPending: true, seq: 10),
        paneIsLive: true,
        after: info(status: 'working', inputPending: true, seq: 10),
      ),
      ReplySafety.safe,
    );
  });

  test('a stale blocked survives only while the server says indefinite', () {
    // The federated-peer case: the live status is overwritten with "unknown"
    // and the real one moves to last_known_status. That still counts as waiting.
    expect(
      judgeReplySafety(
        before: info(status: 'unknown', lastKnown: 'blocked', seq: 10),
        paneIsLive: true,
        after: info(status: 'unknown', lastKnown: 'blocked', seq: 10),
      ),
      ReplySafety.safe,
    );
  });
}
