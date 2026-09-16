import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/git/worktree.dart';
import 'package:herdr_pocket/domain/workspace/agent_launch.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/pane_process.dart';

/// Deciding where an agent may start, and what it should be called.
///
/// `agent.start` only works on a pane whose SHELL owns the foreground, so every
/// question here is really "which of the three conditions failed?" — a refusal
/// the user can act on, instead of the daemon's bare error.
void main() {
  PaneInfo pane({String agent = '', String? cwd, String? foregroundCwd}) =>
      PaneInfo.fromJson({
        'pane_id': 'w1:p1',
        'workspace_id': 'w1',
        'tab_id': 'w1:t1',
        'agent': agent,
        if (cwd != null) 'cwd': cwd,
        if (foregroundCwd != null) 'foreground_cwd': foregroundCwd,
      });

  PaneProcessInfo process(List<Map<String, Object?>> procs) =>
      PaneProcessInfo.fromJson({
        'pane_id': 'w1:p1',
        'shell_pid': 4242,
        'foreground_processes': procs,
      });

  group('evaluateLaunchSurface', () {
    test('a live shell pane with nothing running can host one', () {
      final surface = evaluateLaunchSurface(
        pane: pane(cwd: '/repo'),
        process: process(const []),
        paneIsLive: true,
      );
      expect(surface, isA<CanLaunch>());
    });

    test('a pane that is gone cannot', () {
      final surface = evaluateLaunchSurface(
        pane: pane(cwd: '/repo'),
        process: process(const []),
        paneIsLive: false,
      );
      expect((surface as CannotLaunch).reason, LaunchBlock.gone);
    });

    test('a pane already hosting an agent names the agent, not node', () {
      // The process underneath a `claude` pane is usually `node`, and telling
      // somebody "node is in the way" explains nothing.
      final surface = evaluateLaunchSurface(
        pane: pane(agent: 'claude', cwd: '/repo'),
        process: process([
          {'pid': 977, 'name': 'node', 'argv0': 'claude', 'cwd': '/repo'},
        ]),
        paneIsLive: true,
      );
      expect((surface as CannotLaunch).reason, LaunchBlock.alreadyAgent);
      expect(surface.holder, 'claude');
    });

    test('a busy shell pane names whatever owns the foreground', () {
      final surface = evaluateLaunchSurface(
        pane: pane(cwd: '/repo'),
        process: process([
          {'pid': 12, 'name': 'node', 'argv0': 'vite'},
        ]),
        paneIsLive: true,
      );
      expect((surface as CannotLaunch).reason, LaunchBlock.busy);
      expect(surface.holder, 'vite');
    });

    test('an unanswered process question is a REFUSAL, not a yes', () {
      // "We could not check" is not "it is free". Being wrong here starts an
      // agent on top of somebody's running process.
      final surface = evaluateLaunchSurface(
        pane: pane(cwd: '/repo'),
        process: null,
        paneIsLive: true,
      );
      expect((surface as CannotLaunch).reason, LaunchBlock.unknown);
    });
  });

  group('suggestAgentName', () {
    test('uses the kind when it is free', () {
      expect(suggestAgentName(kind: 'claude'), 'claude');
    });

    test('counts up rather than colliding', () {
      expect(suggestAgentName(kind: 'claude', taken: ['claude']), 'claude-2');
      expect(
        suggestAgentName(kind: 'claude', taken: ['claude', 'claude-2']),
        'claude-3',
      );
    });

    test('falls back to something usable when the kind is empty', () {
      expect(suggestAgentName(kind: '  '), 'agent');
    });
  });

  group('defaultWorkingDirectory', () {
    test('prefers where the process actually is', () {
      expect(
        defaultWorkingDirectory([
          pane(cwd: '/old', foregroundCwd: '/current'),
        ]),
        '/current',
      );
    });

    test('falls back to the pane cwd', () {
      expect(defaultWorkingDirectory([pane(cwd: '/repo')]), '/repo');
    });

    test('skips panes that know nothing, and answers null when none do', () {
      // Null means ASK. Guessing a path here turns a fork into a failure the
      // user has to decode from a daemon error.
      expect(defaultWorkingDirectory([pane(), pane()]), isNull);
    });
  });

  group('PaneProcessInfo', () {
    test('reads the shape a live daemon sends for a shell pane', () {
      final info = PaneProcessInfo.fromJson({
        'pane_id': 'w9:p3',
        'shell_pid': 23816,
        'foreground_processes': <Object?>[],
        'tty': '/dev/ttys003',
      });
      expect(info.shellOwnsForeground, isTrue);
      expect(info.shellPid, 23816);
    });

    test('an agent pane is NOT a launch surface', () {
      final info = PaneProcessInfo.fromJson({
        'pane_id': 'w9:p1',
        'shell_pid': 23816,
        'foreground_processes': [
          {'pid': 977, 'name': 'node', 'argv0': 'pi', 'cwd': '/x'},
        ],
      });
      expect(info.shellOwnsForeground, isFalse);
      expect(info.foregroundProcesses.first.displayName, 'pi');
    });

    test('a process with no argv0 still names itself', () {
      final info = PaneProcessInfo.fromJson({
        'pane_id': 'w1:p1',
        'foreground_processes': [
          {'pid': 3, 'name': 'make'},
        ],
      });
      expect(info.foregroundProcesses.first.displayName, 'make');
    });
  });

  group('WorktreeListing', () {
    // The exact shape a live 0.9.0 answered with.
    final live = WorktreeListing.fromJson(const {
      'source': {
        'repo_key': '/Users/x/Desktop/Apps/my-project/.git',
        'repo_name': 'my-project',
        'repo_root': '/Users/x/Desktop/Apps/my-project',
        'source_checkout_path': '/Users/x/Desktop/Apps/my-project',
        'source_workspace_id': 'w9',
      },
      'worktrees': [
        {
          'branch': 'main',
          'is_bare': false,
          'is_detached': false,
          'is_linked_worktree': false,
          'is_prunable': false,
          'label': 'my-project',
          'open_workspace_id': 'w9',
          'path': '/Users/x/Desktop/Apps/my-project',
        },
        {
          'branch': 'fix/login',
          'is_bare': false,
          'is_detached': false,
          'is_linked_worktree': true,
          'is_prunable': false,
          'label': 'fix-login',
          'open_workspace_id': null,
          'path': '/Users/x/.herdr/worktrees/fix-login',
        },
      ],
    });

    test('is a repository when the daemon described one', () {
      expect(live.isRepository, isTrue);
      expect(live.source?.repoName, 'my-project');
    });

    test('linked worktrees are the ones with their own branch', () {
      // The main checkout is not a candidate for "open an existing worktree" —
      // it is where the user already is.
      expect(live.linked.length, 1);
      expect(live.linked.single.branch, 'fix/login');
    });

    test('an open worktree is shown as open, not offered again', () {
      expect(live.worktrees.first.isOpen, isTrue);
      expect(live.linked.single.isOpen, isFalse);
    });

    test('no source means not a repository — the not_git_worktree answer', () {
      final none = WorktreeListing.fromJson(const {'worktrees': []});
      expect(none.isRepository, isFalse);
    });

    test('a detached checkout still has a branch label for the UI', () {
      final info = WorktreeInfo.fromJson(const {
        'path': '/x',
        'label': 'x',
        'is_detached': true,
      });
      expect(info.branch, isNull);
      expect(info.shortBranch, 'detached');
    });
  });
}
