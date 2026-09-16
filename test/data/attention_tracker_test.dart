import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/notifications/attention_tracker.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';

/// Tests for the rule that decides WHEN to notify.
///
/// Notification behaviour is judged by how annoying it is, not by whether it
/// works, and the failure mode is silent: a tracker that fires on state instead
/// of on transition produces one alert per refresh and looks fine in a demo
/// where the board refreshes twice. These tests are about quietness.
void main() {
  AgentInfo agent(String paneId, String status) => AgentInfo.fromJson({
        'pane_id': paneId,
        'agent': 'claude',
        'agent_status': status,
      });

  AgentList board(List<(String, String)> agents) => AgentList(
        agents: [for (final (id, status) in agents) agent(id, status)],
      );

  group('the first sighting is silent', () {
    test('a board that is already blocked notifies nothing', () {
      final tracker = AttentionTracker();
      // Launching the app while an agent waits must not produce an alert: the
      // user is looking at the board and can see it.
      final fired = tracker.observe(board([('w1:p1', 'blocked')]));
      expect(fired, isEmpty);
    });

    test('an empty first board does not prime anything either', () {
      final tracker = AttentionTracker();
      tracker.observe(board(const []));
      expect(tracker.isPrimed, isTrue);
    });
  });

  group('a transition into needs-you fires exactly once', () {
    test('working -> blocked notifies', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      final fired = tracker.observe(board([('w1:p1', 'blocked')]));

      expect(fired, hasLength(1));
      expect(fired.single.paneId, 'w1:p1');
    });

    test('staying blocked does NOT notify again', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      expect(tracker.observe(board([('w1:p1', 'blocked')])), hasLength(1));

      // The board refreshes on events. One agent needing one answer is one
      // notification, not one per refresh — this is the assertion that keeps
      // the feature from being switched off.
      for (var i = 0; i < 5; i++) {
        expect(tracker.observe(board([('w1:p1', 'blocked')])), isEmpty);
      }
    });

    test('idle -> blocked notifies, and blocked -> blocked does not', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'idle')]));
      expect(tracker.observe(board([('w1:p1', 'blocked')])), hasLength(1));
      expect(tracker.observe(board([('w1:p1', 'blocked')])), isEmpty);
    });

    test('a second trip notifies again', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      expect(tracker.observe(board([('w1:p1', 'blocked')])), hasLength(1));
      tracker.observe(board([('w1:p1', 'working')]));
      // The agent finished its turn and came back for another answer. That is a
      // new event and deserves a new alert.
      expect(tracker.observe(board([('w1:p1', 'blocked')])), hasLength(1));
    });
  });

  group('things that must NOT notify', () {
    test('an unreadable status is not treated as needing you', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      // The board surfaces unrecognised states prominently, but "I cannot read
      // this" is not "a human must answer". Notifying on it would make every
      // daemon upgrade a burst of alerts.
      final fired = tracker.observe(board([('w1:p1', 'brand_new_status')]));
      expect(fired, isEmpty);
    });

    test('an agent disappearing is silence', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'blocked')]));
      expect(tracker.observe(board(const [])), isEmpty);
    });

    test('an agent going quiet from blocked is not a new alert', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      tracker.observe(board([('w1:p1', 'blocked')]));
      expect(tracker.observe(board([('w1:p1', 'done')])), isEmpty);
    });
  });

  group('pane identity is remembered per pane', () {
    test('two agents blocked at once produce two alerts', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working'), ('w1:p2', 'working')]));
      final fired = tracker.observe(
        board([('w1:p1', 'blocked'), ('w1:p2', 'blocked')]),
      );
      expect(fired, hasLength(2));
      expect(fired.map((a) => a.paneId).toSet(), {'w1:p1', 'w1:p2'});
    });

    test('a pane id reused after it vanished counts as a fresh arrival', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      tracker.observe(board([('w1:p1', 'blocked')]));

      // The pane closed...
      tracker.observe(board(const []));
      // ...and something new took its id while already blocked. Since we
      // forgot the old state, this is a first sighting and stays silent —
      // which is right: we cannot know it is the same agent.
      expect(tracker.observe(board([('w1:p1', 'blocked')])), isEmpty);
    });
  });

  group('reset', () {
    test('makes the next board silent again', () {
      final tracker = AttentionTracker();
      tracker.observe(board([('w1:p1', 'working')]));
      expect(tracker.observe(board([('w1:p1', 'blocked')])), hasLength(1));

      // A host switch or a reconnect must not replay stale transitions as
      // though they had just happened.
      tracker.reset();
      expect(tracker.isPrimed, isFalse);
      expect(tracker.observe(board([('w1:p1', 'blocked')])), isEmpty);
    });
  });
}
