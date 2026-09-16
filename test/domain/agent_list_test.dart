import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// These tests pin the fail-closed semantics ported from
/// `herdrup/Sources/HerdrKit/AgentList.swift`. They are the reason the domain
/// layer is pure Dart: the most consequential logic in the app is verifiable
/// without a Flutter binding.
///
/// The single idea under test: a client that cannot interpret a status must
/// surface it, never bury it. Every test below is a specific way that could go
/// wrong.
void main() {
  AgentInfo info({
    String paneId = 'w1:p1',
    String? status,
    String? lastKnown,
    bool inputPending = false,
    int? completedMs,
    int? seq,
    bool archived = false,
  }) {
    return AgentInfo.fromJson({
      'pane_id': paneId,
      'agent': 'claude',
      'agent_status': status,
      if (lastKnown != null) 'last_known_status': lastKnown,
      if (inputPending) 'input_pending': true,
      if (completedMs != null)
        'last_completed_turn': {'completed_unix_ms': completedMs},
      if (seq != null) 'state_change_seq': seq,
      if (archived) 'archived': {'at': '2026-01-01T00:00:00Z'},
    });
  }

  group('AgentStatus.fromWire', () {
    test('maps the five known wire values', () {
      expect(AgentStatus.fromWire('idle'), isA<AgentIdle>());
      expect(AgentStatus.fromWire('working'), isA<AgentWorking>());
      expect(AgentStatus.fromWire('blocked'), isA<AgentBlocked>());
      expect(AgentStatus.fromWire('done'), isA<AgentDone>());
      expect(AgentStatus.fromWire('unknown'), isA<AgentIndefinite>());
    });

    test('a null wire value is absent, not idle', () {
      expect(AgentStatus.fromWire(null), isA<AgentAbsent>());
    });

    test('an unknown wire value keeps its raw payload', () {
      final s = AgentStatus.fromWire('waiting_approval');
      expect(s, isA<AgentUnrecognised>());
      expect((s as AgentUnrecognised).raw, 'waiting_approval');
    });

    test('only blocked is blocked', () {
      expect(const AgentBlocked().isBlocked, isTrue);
      for (final s in <AgentStatus>[
        const AgentIdle(),
        const AgentWorking(),
        const AgentDone(),
        const AgentIndefinite(),
        const AgentAbsent(),
        const AgentUnrecognised('x'),
      ]) {
        expect(s.isBlocked, isFalse, reason: '$s must not claim it needs you');
      }
    });
  });

  group('fail-closed grouping', () {
    test('a status this build cannot read surfaces above working and idle', () {
      expect(AgentGroup.unrecognised.rank, lessThan(AgentGroup.working.rank));
      expect(AgentGroup.unrecognised.rank, lessThan(AgentGroup.idle.rank));
    });

    test('needsYou outranks everything, stopped outranks the quiet tail', () {
      expect(AgentGroup.needsYou.rank, lessThan(AgentGroup.stopped.rank));
      expect(AgentGroup.stopped.rank, lessThan(AgentGroup.unrecognised.rank));
    });

    test('idle and stopped have nothing to say by default', () {
      for (final g in AgentGroup.values) {
        expect(
          g.startsCollapsed,
          g == AgentGroup.idle || g == AgentGroup.stopped,
          reason: '$g',
        );
      }
    });

    group('which section the board opens', () {
      // THE RULE, IN THE USER'S WORDS: working first, else approvals, else
      // idle. Exactly one section — a board that opens everything lets a fleet
      // of idle agents bury the one that is stuck, and a board that opens
      // nothing is a list of headings.
      test('working wins when it is there, even beside approvals', () {
        expect(
          defaultExpandedGroup([
            AgentGroup.needsYou,
            AgentGroup.unrecognised,
            AgentGroup.working,
            AgentGroup.idle,
          ]),
          AgentGroup.working,
          reason: 'approvals sort to the TOP of the page, so leaving them '
              'closed still leaves them visible; working is what is live',
        );
      });

      test('approvals are next', () {
        expect(
          defaultExpandedGroup([
            AgentGroup.needsYou,
            AgentGroup.stopped,
            AgentGroup.idle,
          ]),
          AgentGroup.needsYou,
        );
      });

      test('idle is the last of the three', () {
        expect(
          defaultExpandedGroup([AgentGroup.unrecognised, AgentGroup.idle]),
          AgentGroup.idle,
        );
      });

      test('a board of only dead or unreadable rows opens the first one', () {
        expect(
          defaultExpandedGroup([AgentGroup.stopped, AgentGroup.unrecognised]),
          AgentGroup.stopped,
          reason: 'none of the three preferred groups is here, so it falls back '
              'to whatever the board sorts first — a screen of nothing but '
              'headings reads as broken rather than as quiet',
        );
        expect(defaultExpandedGroup([AgentGroup.unrecognised]),
            AgentGroup.unrecognised);
      });

      test('an empty board opens nothing', () {
        expect(defaultExpandedGroup(const <AgentGroup>[]), isNull);
      });
    });

    test('unknown status groups as unrecognised, never idle', () {
      final row = AgentRow(info: info(status: 'unknown'));
      expect(row.group, AgentGroup.unrecognised);
    });

    test('absent status groups as unrecognised, never idle', () {
      final row = AgentRow(info: info());
      expect(row.status, isA<AgentAbsent>());
      expect(row.group, AgentGroup.unrecognised);
    });

    test('unrecognised wire status groups as unrecognised', () {
      final row = AgentRow(info: info(status: 'waiting_approval'));
      expect(row.group, AgentGroup.unrecognised);
    });

    test('done is quiet, so it groups with idle', () {
      expect(AgentRow(info: info(status: 'done')).group, AgentGroup.idle);
    });

    test('a dead pane is stopped regardless of its last status', () {
      final row = AgentRow(
        info: info(status: 'blocked'),
        isLive: false,
      );
      expect(row.group, AgentGroup.stopped);
    });
  });

  group('escalation-only overlays', () {
    test('input_pending escalates a non-blocked agent into needsYou', () {
      final row = AgentRow(info: info(status: 'working', inputPending: true));
      expect(row.group, AgentGroup.needsYou);
    });

    test('input_pending never applies to a dead pane', () {
      final row = AgentRow(
        info: info(status: 'working', inputPending: true),
        isLive: false,
      );
      expect(row.group, AgentGroup.stopped);
    });

    test('last-known blocked rescues an agent whose peer went quiet', () {
      final row = AgentRow(info: info(status: 'unknown', lastKnown: 'blocked'));
      expect(row.group, AgentGroup.needsYou);
    });

    test('a LIVE idle status is authoritative over a stale blocked value', () {
      // The indefinite precondition is load-bearing: escalating here would
      // resurrect a state the server already replaced.
      final row = AgentRow(info: info(status: 'idle', lastKnown: 'blocked'));
      expect(row.group, AgentGroup.idle);
    });

    test('last-known working does NOT restore the working group', () {
      final row = AgentRow(info: info(status: 'unknown', lastKnown: 'working'));
      expect(row.group, AgentGroup.unrecognised);
    });
  });

  group('census', () {
    test('a null census treats every row as live', () {
      final list = AgentList(agents: [info(paneId: 'w1:p1', status: 'idle')]);
      expect(list.rows.single.isLive, isTrue);
    });

    test('a missing pane id in the census marks the row stopped', () {
      final list = AgentList(
        agents: [info(paneId: 'w1:p1', status: 'working')],
        livePaneIds: {'w1:p9'},
      );
      expect(list.rows.single.group, AgentGroup.stopped);
    });
  });

  group('ordering and composition', () {
    test('groups order by rank, then most-recent turn, then pane id', () {
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p1', status: 'idle', completedMs: 100),
          info(paneId: 'w1:p2', status: 'blocked', completedMs: 50),
          info(paneId: 'w1:p3', status: 'working', completedMs: 999),
          info(paneId: 'w1:p4', status: 'nonsense_status', completedMs: 1),
        ],
      );
      expect(
        list.rows.map((r) => r.id).toList(),
        ['w1:p2', 'w1:p4', 'w1:p3', 'w1:p1'],
      );
    });

    test('equal timestamps fall back to pane id so the list is stable', () {
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p9', status: 'working', completedMs: 5),
          info(paneId: 'w1:p2', status: 'working', completedMs: 5),
        ],
      );
      expect(list.rows.map((r) => r.id).toList(), ['w1:p2', 'w1:p9']);
    });

    test('a tie on the wall clock is broken by state_change_seq', () {
      // The wall clock cannot answer "these two finished in the same second —
      // which one just moved?". The server's own counter can, and it is used
      // ONLY here: as a primary key it would reorder a group every time a
      // status flickered, because it counts lifecycle transitions and not time.
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p1', status: 'working', completedMs: 5, seq: 100),
          info(paneId: 'w1:p2', status: 'working', completedMs: 5, seq: 300),
          info(paneId: 'w1:p3', status: 'working', completedMs: 5, seq: 200),
        ],
      );
      expect(list.rows.map((r) => r.id).toList(), ['w1:p2', 'w1:p3', 'w1:p1']);
    });

    test('a missing counter falls through to the pane id, not to a guess', () {
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p1', status: 'working', completedMs: 5, seq: 100),
          info(paneId: 'w1:p2', status: 'working', completedMs: 5),
        ],
      );
      // p2 has no seq at all. It must not be treated as seq 0 (which would sort
      // it last) nor as infinity (first): the next real key decides.
      expect(list.rows.length, 2);
      expect(list.rows.first.id, 'w1:p1');
    });

    test('state_change_seq never outranks the wall clock or the group', () {
      final list = AgentList(
        agents: [
          // Older turn but a much higher counter: the group and the timestamp
          // still decide.
          info(paneId: 'w1:p1', status: 'working', completedMs: 1, seq: 9999),
          info(paneId: 'w1:p2', status: 'working', completedMs: 500, seq: 2),
        ],
      );
      expect(list.rows.first.id, 'w1:p2');
    });

    test('empty groups are omitted from sections', () {
      final list = AgentList(agents: [info(status: 'idle')]);
      expect(list.sections.map((s) => s.group).toList(), [AgentGroup.idle]);
    });

    test('archived agents leave the live board and the counts entirely', () {
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p1', status: 'blocked'),
          info(paneId: 'w1:p2', status: 'idle', archived: true),
        ],
      );
      expect(list.rows.map((r) => r.id), ['w1:p1']);
      expect(list.archived.map((r) => r.id), ['w1:p2']);
      expect(list.needsYouCount, 1);
    });
  });

  group('isQuiet refuses to claim all-clear', () {
    test('an uninterpretable agent prevents quiet', () {
      final list = AgentList(agents: [info(status: 'brand_new_state')]);
      expect(list.isQuiet, isFalse);
    });

    test('a missing status prevents quiet', () {
      final list = AgentList(agents: [info()]);
      expect(list.isQuiet, isFalse);
    });

    test('working and idle alone are quiet', () {
      final list = AgentList(
        agents: [info(paneId: 'w1:p1', status: 'working'), info(paneId: 'w1:p2', status: 'idle')],
      );
      expect(list.isQuiet, isTrue);
      expect(list.needsYouCount, 0);
      expect(list.needsYouSummary, isNull);
    });

    test('stopped alone is quiet — a gone pane needs nothing from anybody', () {
      final list = AgentList(
        agents: [info(status: 'working')],
        livePaneIds: const {},
      );
      expect(list.isQuiet, isTrue);
    });
  });

  group('activity headline uses its own order, not the list order', () {
    test('a working agent outranks a freshly stopped one', () {
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p1', status: 'working'),
          info(paneId: 'w1:p2', status: 'idle'),
        ],
        livePaneIds: const {'w1:p1'},
      );
      expect(list.activityLead!.id, 'w1:p1');
    });

    test('needsYou wins, and stopped is the headline only when it is all there is', () {
      final list = AgentList(
        agents: [
          info(paneId: 'w1:p1', status: 'blocked'),
          info(paneId: 'w1:p2', status: 'working'),
        ],
      );
      expect(list.activityLead!.id, 'w1:p1');
    });
  });

  group('compactTimeInState', () {
    test('never shows seconds', () {
      expect(compactTimeInState(0, 30 * 1000), '0m');
      expect(compactTimeInState(0, 59 * 1000), '0m');
    });

    test('minutes, then hours, then days', () {
      expect(compactTimeInState(0, 5 * 60 * 1000), '5m');
      expect(compactTimeInState(0, 3 * 3600 * 1000), '3h');
      expect(compactTimeInState(0, 2 * 86400 * 1000), '2d');
    });

    test('a future timestamp yields no badge rather than a wrong one', () {
      expect(compactTimeInState(5000, 1000), isNull);
    });

    test('no anchor yields no badge', () {
      expect(compactTimeInState(null, 1000), isNull);
    });
  });
}
