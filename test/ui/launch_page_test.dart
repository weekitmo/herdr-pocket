import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/launch/launch_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The launcher, end to end.
///
/// This is the screen that CHANGES THE MACHINE — it creates a workspace and
/// starts a process on it. So the assertions are about traffic, not pixels:
/// which calls went out, in what order, with what arguments, and — for the
/// failures — that the flow stopped before the risky half.
class _ScriptedDaemon implements HerdrTransport {
  _ScriptedDaemon(this.handlers);

  final Map<String, String Function(Map<String, Object?> params)> handlers;
  final List<String> methods = [];
  final List<Map<String, Object?>> calls = [];

  @override
  Future<String> roundTrip(String requestLine) async {
    final req = (jsonDecode(requestLine) as Map).cast<String, Object?>();
    final method = req['method']! as String;
    methods.add(method);
    calls.add(req);
    final handler = handlers[method];
    if (handler == null) {
      return '{"id":"","error":{"code":"unknown_method","message":"no handler for $method"}}';
    }
    return handler((req['params']! as Map).cast<String, Object?>());
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) => throw UnimplementedError();

  @override
  Future<void> close() async {}

  Map<String, Object?> paramsOf(String method) {
    for (final c in calls.reversed) {
      if (c['method'] == method) {
        return (c['params']! as Map).cast<String, Object?>();
      }
    }
    return const {};
  }

  bool got(String method) => methods.contains(method);
  int indexOf(String method) => methods.indexOf(method);
}

class _FixedConnection extends ConnectionNotifier {
  _FixedConnection(this._status);

  final ConnectionStatus _status;

  @override
  Future<ConnectionStatus> build() async => _status;
}

class _QuietBoard extends BoardNotifier {
  @override
  Future<AgentList> build() async => AgentList.empty();

  @override
  Future<void> refresh() async {}
}

/// Two agents, one of them not installed — the shape a live daemon sent.
const _integrations = '{"id":"x","result":{"type":"integration_list","integrations":['
    '{"target":"pi","label":"pi","command":"pi","available":true,"state":"not_installed"},'
    '{"target":"claude","label":"claude","command":"claude","available":false,'
    '"state":"not_installed"}]}}';

const _repo = '{"id":"x","result":{"type":"worktree_list",'
    '"source":{"repo_key":"/x/.git","repo_name":"x","repo_root":"/x/repo",'
    '"source_checkout_path":"/x/repo","source_workspace_id":"w9"},"worktrees":[]}}';

const _notARepo = '{"id":"x","error":{"code":"not_git_worktree",'
    '"message":"Herdr worktree actions require a path inside a Git work tree"}}';

const _created = '{"id":"x","result":{"type":"workspace_created",'
    '"workspace":{"workspace_id":"w11"},"tab":{"tab_id":"w11:t1"},'
    '"root_pane":{"pane_id":"w11:p1"}}}';

const _started = '{"id":"x","result":{"type":"agent_started",'
    '"agent":{"pane_id":"w11:p1","agent":"pi","agent_status":"working"},'
    '"argv":["pi"]}}';

Widget _host(Widget child, HerdrTransport transport) => ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        connectionProvider.overrideWith(
          () => _FixedConnection(
            Online(
              client: HerdrClient(transport),
              hello: const HerdrHello(version: '0.9.0', protocol: 22),
              socketPath: '/tmp/herdr.sock',
            ),
          ),
        ),
        boardProvider.overrideWith(_QuietBoard.new),
      ],
      child: HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: child,
        ),
      ),
    );

/// Scrolls the primary button into view before tapping it.
///
/// The form is a lazy ListView, so the button is not merely off-screen — it is
/// not built at all until it is scrolled to.
Future<void> _tapCreate(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Create and start'),
    200,
    // The page has more than one scrollable (the form, and the text fields
    // inside it), so the target has to be named.
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Create and start'));
}

/// Pumps long enough for the launcher's wait-for-the-shell loop to finish.
///
/// The loop is attempt-counted with a 250 ms interval, so this advances the
/// test clock past a couple of rounds. `pumpAndSettle` cannot be used: the page
/// shows a spinner while it works.
Future<void> _awaitPaneReady(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Pumps a few frames WITHOUT settling: the page shows a spinner while it
/// works, and `pumpAndSettle` never returns while one is on screen.
Future<void> _tick(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// A daemon that behaves like the real one.
///
/// Two things it models that the first version did not, both learned from
/// running the write path against a live daemon:
///
///  * creating a workspace makes its pane EXIST — the launcher probes
///    `pane.list` before starting, so a fake that forgets to add the pane sends
///    the page down its failure branch;
///  * a fresh pane's shell is NOT in the foreground for a moment. That is
///    `agent_pane_busy` on the wire, and it is the whole reason [AgentLauncher]
///    exists.
_ScriptedDaemon _happyDaemon({
  String worktree = 'ok',
  int busyProbesForNewPane = 1,
  bool newPaneEverAppears = true,
}) {
  // pane id -> agent detected in it, which is what the picker's reasons read.
  final panes = <String, String>{'w9:p3': '', 'w9:p1': 'pi'};
  var newPaneProbes = 0;

  String processInfo(String id) {
    if (id == 'w11:p1') {
      newPaneProbes++;
      final ready = newPaneProbes > busyProbesForNewPane;
      return '{"id":"x","result":{"type":"pane_process_info","process_info":'
          '{"pane_id":"w11:p1","shell_pid":4,"foreground_processes":'
          '${ready ? '[]' : '[{"pid":5,"name":"sh"}]'}}}}';
    }
    if (id == 'w9:p1') {
      return '{"id":"x","result":{"type":"pane_process_info","process_info":'
          '{"pane_id":"w9:p1","shell_pid":2,"foreground_processes":'
          '[{"pid":977,"name":"node","argv0":"pi"}]}}}';
    }
    return '{"id":"x","result":{"type":"pane_process_info","process_info":'
        '{"pane_id":"w9:p3","shell_pid":3,"foreground_processes":[]}}}';
  }

  String paneList() {
    final rows = panes.entries.map((e) {
      final ws = e.key.split(':').first;
      return '{"pane_id":"${e.key}","workspace_id":"$ws","tab_id":"$ws:t1",'
          '"agent":"${e.value}","cwd":"/Users/x/repo"}';
    }).join(',');
    return '{"id":"x","result":{"type":"pane_list","panes":[$rows]}}';
  }

  return _ScriptedDaemon({
    'integration.list': (_) => _integrations,
    'pane.list': (_) => paneList(),
    'worktree.list': (_) => worktree == 'ok' ? _repo : _notARepo,
    'pane.process_info': (params) => processInfo(params['pane_id']! as String),
    'workspace.create': (_) {
      if (newPaneEverAppears) panes['w11:p1'] = '';
      return _created;
    },
    'worktree.create': (_) {
      if (newPaneEverAppears) panes['w11:p1'] = '';
      return _created;
    },
    'agent.start': (_) => _started,
  });
}

/// The injected settings store.
///
/// `main()` awaits `SharedPreferences.getInstance()` before `runApp` and
/// injects it, and `SettingsNotifier` reads it while building — so any widget
/// tree containing a page that reads settings needs one here too.
late SharedPreferences _prefs;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('offers the agents herdr reports, and marks the missing ones',
      (tester) async {
    final daemon = _happyDaemon();
    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);

    // 'pi' appears twice on purpose: once as a chip, once as the suggested
    // name. 'claude' is only ever a chip, because it is not installed and so
    // is never suggested.
    expect(find.text('pi'), findsNWidgets(2));
    expect(find.text('claude'), findsOneWidget);
    // The greyed-out explanation is one line, not one per chip.
    expect(find.textContaining('not installed on this machine'), findsOneWidget);
  });

  testWidgets('starts from where the panes already are', (tester) async {
    // A blank directory field on a phone is a question the app can answer
    // itself: the panes know where the user works.
    final daemon = _happyDaemon();
    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);

    expect(find.text('/Users/x/repo'), findsOneWidget);
  });

  testWidgets('offers the worktree option inside a repository', (tester) async {
    await tester.pumpWidget(_host(const LaunchPage(), _happyDaemon()));
    await _tick(tester);
    expect(find.text('Use an isolated worktree'), findsOneWidget);
  });

  testWidgets('outside a repository it says why the option is missing',
      (tester) async {
    // A silently absent control is worse than a disabled one: the user cannot
    // tell whether the app does not support it or the directory is wrong.
    await tester.pumpWidget(
      _host(const LaunchPage(), _happyDaemon(worktree: 'no')),
    );
    await _tick(tester);
    expect(find.text('Use an isolated worktree'), findsNothing);
    expect(find.textContaining('not inside a git repository'), findsOneWidget);
  });

  testWidgets('creates a workspace, THEN starts the agent in its root pane',
      (tester) async {
    final daemon = _happyDaemon();
    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);

    await _tapCreate(tester);
    await _awaitPaneReady(tester);

    expect(daemon.got('workspace.create'), isTrue);
    expect(daemon.paramsOf('workspace.create')['cwd'], '/Users/x/repo');
    expect(daemon.got('agent.start'), isTrue);

    // The order is the substance: an agent started before its pane exists has
    // nowhere to go.
    expect(
      daemon.indexOf('workspace.create'),
      lessThan(daemon.indexOf('agent.start')),
    );

    final start = daemon.paramsOf('agent.start');
    expect(start['pane_id'], 'w11:p1');
    expect(start['kind'], 'pi');
    expect(start['name'], 'pi');
    // The daemon's own allowance for a brand-new pane's shell to take the
    // foreground — the race this flow would otherwise lose.
    expect(start['timeout_ms'], 10000);
  });

  testWidgets('worktree mode creates a worktree instead of a plain workspace',
      (tester) async {
    final daemon = _happyDaemon();
    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);

    await tester.tap(find.byType(CupertinoSwitch).last);
    await _tick(tester);
    await tester.enterText(find.byType(CupertinoTextField).at(1), 'fix/login');
    await _tapCreate(tester);
    await _awaitPaneReady(tester);

    expect(daemon.got('worktree.create'), isTrue);
    expect(daemon.got('workspace.create'), isFalse);
    expect(daemon.paramsOf('worktree.create')['branch'], 'fix/login');
    expect(daemon.paramsOf('worktree.create')['cwd'], '/Users/x/repo');
    // `path` is the daemon's convention to own, so we never send one.
    expect(daemon.paramsOf('worktree.create').containsKey('path'), isFalse);
    expect(daemon.got('agent.start'), isTrue);
  });

  testWidgets('pane mode lists every pane, with a reason for the unusable ones',
      (tester) async {
    final daemon = _happyDaemon();
    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);

    await tester.tap(find.byType(CupertinoSwitch).first);
    await _tick(tester);

    // The busy pane is still LISTED. A list that silently omits the pane the
    // user is looking at is a list that looks broken — and the reason is the
    // whole point of judging the surface on the client.
    expect(find.text('pi'), findsWidgets);
    expect(find.textContaining('is already in it'), findsOneWidget);
    expect(find.textContaining('owns the foreground'), findsNothing);
  });

  testWidgets('pane mode starts in that pane without creating anything',
      (tester) async {
    final daemon = _happyDaemon();
    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);

    await tester.tap(find.byType(CupertinoSwitch).first);
    await _tick(tester);
    await _tapCreate(tester);
    await _tick(tester);

    expect(daemon.got('agent.start'), isTrue);
    expect(daemon.paramsOf('agent.start')['pane_id'], 'w9:p3');
    // Nothing was created, so there is nothing to clean up if the start fails.
    expect(daemon.got('workspace.create'), isFalse);
    expect(daemon.got('worktree.create'), isFalse);
  });

  testWidgets('a pane that never shows up says so, in those words',
      (tester) async {
    // The pane is created in the daemon's answer but never appears in
    // `pane.list`, which is what the launcher probes before starting. It gives
    // up rather than waiting, and the page has to SAY so next to the button —
    // not spin, and not claim success.
    final daemon = _happyDaemon(newPaneEverAppears: false);

    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);
    await _tapCreate(tester);
    await _tick(tester);

    expect(find.textContaining('no pane id'), findsOneWidget);
    expect(daemon.got('agent.start'), isFalse);
    // And the form is usable again rather than stuck on a spinner.
    expect(find.text('Create and start'), findsOneWidget);
  });

  testWidgets('a workspace with no root pane stops before starting anything',
      (tester) async {
    final daemon = _happyDaemon();
    daemon.handlers['workspace.create'] =
        (_) => '{"id":"x","result":{"type":"workspace_created",'
            '"workspace":{"workspace_id":"w11"}}}';

    await tester.pumpWidget(_host(const LaunchPage(), daemon));
    await _tick(tester);
    await _tapCreate(tester);
    await _tick(tester);

    expect(daemon.got('agent.start'), isFalse);
    expect(find.textContaining('no pane id'), findsOneWidget);
  });
}
