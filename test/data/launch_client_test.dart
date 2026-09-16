import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// Pins the wire shape of the CREATION calls.
///
/// These are the ones that change the user's machine — a new workspace, a new
/// checkout, an agent process. A wrong parameter name here is not a cosmetic
/// bug: herdr answers with a missing-field error and the user sees "nothing
/// happened" on an action that was supposed to create something visible on
/// their desktop.
class _RecordingTransport implements HerdrTransport {
  _RecordingTransport(this.reply);

  final String Function(Map<String, Object?> params) reply;
  final List<Map<String, Object?>> sent = [];

  @override
  Future<String> roundTrip(String requestLine) async {
    final req = (jsonDecode(requestLine) as Map).cast<String, Object?>();
    sent.add(req);
    return reply((req['params']! as Map).cast<String, Object?>());
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) => throw UnimplementedError();

  @override
  Future<void> close() async {}

  Map<String, Object?> get last => sent.last;
  Map<String, Object?> get params =>
      (last['params']! as Map).cast<String, Object?>();
}

void main() {
  group('integration.list', () {
    test('unwraps the list and keeps availability', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"integration_list","integrations":['
            '{"target":"cursor","label":"Cursor","command":"cursor-agent",'
            '"available":false,"state":"not_installed"},'
            '{"target":"pi","label":"pi","command":"pi",'
            '"available":true,"state":"not_installed"}]}}',
      );
      final list = await HerdrClient(transport).integrationList();

      expect(transport.last['method'], HerdrMethod.integrationList);
      expect(list.length, 2);
      // The target is NOT the command — the whole reason this list comes from
      // the daemon instead of a table in our source.
      expect(list.first.target, 'cursor');
      expect(list.first.command, 'cursor-agent');
      expect(list.first.available, isFalse);
      expect(list[1].available, isTrue);
    });

    test('an empty answer is an empty list, not a crash', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"integration_list"}}',
      );
      expect(await HerdrClient(transport).integrationList(), isEmpty);
    });
  });

  group('pane.process_info', () {
    test('sends the pane id and unwraps process_info', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"pane_process_info","process_info":'
            '{"pane_id":"w9:p1","shell_pid":23816,'
            '"foreground_process_group_id":977,'
            '"foreground_processes":[{"pid":977,"name":"node","argv0":"pi",'
            '"cwd":"/Users/x/repo"}]}}}',
      );
      final info = await HerdrClient(transport).paneProcessInfo(paneId: 'w9:p1');

      expect(transport.params['pane_id'], 'w9:p1');
      expect(info?.paneId, 'w9:p1');
      expect(info?.shellPid, 23816);
      expect(info?.foregroundProcesses.single.argv0, 'pi');
      expect(info?.foregroundProcesses.single.cwd, '/Users/x/repo');
    });

    test('a missing process_info is null, not a fabricated empty one', () async {
      // null means "we could not check", which the launch decision treats as a
      // refusal. Returning an empty object would read as "the shell is free".
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"pane_process_info"}}',
      );
      expect(await HerdrClient(transport).paneProcessInfo(paneId: 'w1:p1'), isNull);
    });
  });

  group('workspace.create', () {
    test('sends the path, asks for focus, and unwraps the new structure',
        () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"workspace_created",'
            '"workspace":{"workspace_id":"w11","label":"repo"},'
            '"tab":{"tab_id":"w11:t1","workspace_id":"w11"},'
            '"root_pane":{"pane_id":"w11:p1","workspace_id":"w11","tab_id":"w11:t1"}}}',
      );
      final created = await HerdrClient(transport).workspaceCreate(
        cwd: '/Users/x/repo',
        label: 'repo',
      );

      expect(transport.last['method'], HerdrMethod.workspaceCreate);
      expect(transport.params['cwd'], '/Users/x/repo');
      expect(transport.params['label'], 'repo');
      // The daemon defaults this to false; we default it to true because the
      // user just asked for the workspace.
      expect(transport.params['focus'], isTrue);
      expect(created.workspaceId, 'w11');
      expect(created.paneId, 'w11:p1');
    });

    test('omits env rather than sending an empty object', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"workspace_created"}}',
      );
      await HerdrClient(transport).workspaceCreate(cwd: '/x');
      expect(transport.params.containsKey('env'), isFalse);
    });
  });

  group('worktree.create', () {
    test('sends the branch and base, and unwraps the checkout', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"worktree_created",'
            '"workspace":{"workspace_id":"w12"},'
            '"tab":{"tab_id":"w12:t1"},'
            '"root_pane":{"pane_id":"w12:p1"},'
            '"worktree":{"path":"/Users/x/.herdr/worktrees/fix-login",'
            '"label":"fix-login","branch":"fix/login","is_bare":false,'
            '"is_detached":false,"is_linked_worktree":true,"is_prunable":false}}}',
      );
      final created = await HerdrClient(transport).worktreeCreate(
        cwd: '/Users/x/repo',
        branch: 'fix/login',
        base: 'main',
      );

      expect(transport.last['method'], HerdrMethod.worktreeCreate);
      expect(transport.params['branch'], 'fix/login');
      expect(transport.params['base'], 'main');
      // Never set by us: where worktrees live is the daemon's convention.
      expect(transport.params.containsKey('path'), isFalse);
      expect(created.paneId, 'w12:p1');
      expect(created.worktree?.branch, 'fix/login');
      expect(created.worktree?.isLinked, isTrue);
    });

    test('not_git_worktree surfaces so the UI can say which thing failed',
        () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","error":{"code":"not_git_worktree",'
            '"message":"Herdr worktree actions require a path inside a Git work tree"}}',
      );
      await expectLater(
        HerdrClient(transport).worktreeCreate(cwd: '/tmp', branch: 'x'),
        throwsA(
          isA<HerdrApiException>()
              .having((e) => e.code, 'code', 'not_git_worktree'),
        ),
      );
    });
  });

  group('worktree.list', () {
    test('passes the path through and reads the source', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"worktree_list",'
            '"source":{"repo_key":"/x/.git","repo_name":"x","repo_root":"/x",'
            '"source_checkout_path":"/x","source_workspace_id":"w9"},'
            '"worktrees":[]}}',
      );
      final listing = await HerdrClient(transport).worktreeList(cwd: '/x');

      expect(transport.params['cwd'], '/x');
      expect(listing.isRepository, isTrue);
      expect(listing.source?.repoName, 'x');
    });
  });

  group('agent.start', () {
    test('sends the three required fields and unwraps the agent', () async {
      final transport = _RecordingTransport(
        (_) => '{"id":"x","result":{"type":"agent_started",'
            '"agent":{"pane_id":"w11:p1","agent":"claude","agent_status":"working"},'
            '"argv":["claude"]}}',
      );
      final agent = await HerdrClient(transport).agentStart(
        name: 'claude',
        kind: 'claude',
        paneId: 'w11:p1',
      );

      expect(transport.last['method'], HerdrMethod.agentStart);
      expect(transport.params['name'], 'claude');
      expect(transport.params['kind'], 'claude');
      expect(transport.params['pane_id'], 'w11:p1');
      expect(transport.params.containsKey('args'), isFalse);
      expect(transport.params.containsKey('timeout_ms'), isFalse);
      expect(agent?.agent, 'claude');
    });

    test('agent_not_ready surfaces with its own code', () async {
      // What the daemon says when the pane's foreground is occupied. The UI is
      // supposed to have refused first — this is the backstop, and it has to be
      // reportable rather than swallowed.
      final transport = _RecordingTransport(
        (_) => '{"id":"","error":{"code":"agent_not_ready",'
            '"message":"pane is not an idle shell"}}',
      );
      await expectLater(
        HerdrClient(transport).agentStart(
          name: 'x',
          kind: 'claude',
          paneId: 'w1:p1',
        ),
        throwsA(
          isA<HerdrApiException>().having((e) => e.code, 'code', 'agent_not_ready'),
        ),
      );
    });
  });
}
