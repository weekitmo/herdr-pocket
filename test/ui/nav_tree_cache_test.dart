import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/root_shell.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_harness.dart';

/// 切页之后，列表还在。
///
/// REPORTED FROM THE PHONE (2026-09-21): 「工作区/看板这里，好像如果 ssh 不稳定，
/// 切换 nav tab 或者从另外的页面回来时，原本的列表就不见了」—— and the tree did
/// disappear, because `navTreeProvider` is auto-disposing (deliberately: it rides
/// the board's event heartbeat, see its own doc) and kept no memory of what it had
/// already read. Leaving the page destroyed the only copy; coming back re-read it,
/// and on a link that was down the re-read answered "no workspaces" — which is not
/// an answer, it is a lie about the user's machine.
///
/// The rule these tests hold to is the one the board has followed since Phase 26:
/// **the last thing actually read stays on screen until something newer arrives**,
/// and a list from another machine is never used to fill the gap.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets('the tree survives a trip to the board taken while the link is down',
      (tester) async {
    final daemon = FakeTerminalDaemon(paneRows: 46);
    final harness = await _Harness.pump(tester, prefs, daemon: daemon);
    await harness.openWorkspaces(tester);

    expect(find.text('dev'), findsOneWidget, reason: 'the first read landed');
    expect(find.text('No workspaces'), findsNothing);

    // Away to the board. The workspaces page is torn down with it — that part is
    // by design (see `RootShell`), and it is exactly what used to take the data
    // with it.
    await harness.openBoard(tester);

    // The link drops while the user is looking elsewhere: a recovery, which is
    // the state an unstable SSH link spends its time in.
    harness.container.read(_statusProvider.notifier).status =
        const Connecting(attempt: 1, afterLoss: true);
    await _settle(tester);

    await harness.openWorkspaces(tester);

    expect(
      find.text('dev'),
      findsOneWidget,
      reason: 'the tree that was already read is still the best answer, and a '
          'blank tree says the workspaces are gone — which is the one thing we '
          'know is not true',
    );
    expect(find.text('No workspaces'), findsNothing);
  });

  testWidgets('a slow read does not blank the tree that is already there',
      (tester) async {
    final daemon = FakeTerminalDaemon(paneRows: 46);
    final harness = await _Harness.pump(tester, prefs, daemon: daemon);
    await harness.openWorkspaces(tester);
    expect(find.text('dev'), findsOneWidget);

    await harness.openBoard(tester);

    // The second visit's read is on a link that has not answered yet. This is
    // the ordinary case on a bad network: the request is not refused, it is
    // SLOW — and the page must not spend that time pretending to be empty.
    daemon.treeGate = Completer<void>();
    await harness.openWorkspaces(tester);

    expect(
      find.text('dev'),
      findsOneWidget,
      reason: 'what was read before is shown while the next read is in flight',
    );
    expect(find.text('No workspaces'), findsNothing);

    // And when it lands, it replaces the seed: the cache is a floor for the
    // first frame, not a second source of truth.
    daemon.treeGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('dev'), findsOneWidget);
    expect(
      harness.container.read(navTreeProvider).isLoading,
      isFalse,
      reason: 'the read that was in flight has landed and been applied',
    );
  });

  testWidgets("switching machines drops the previous machine's tree at once",
      (tester) async {
    final daemon = FakeTerminalDaemon(paneRows: 46);
    final harness = await _Harness.pump(tester, prefs, daemon: daemon);
    await harness.openWorkspaces(tester);
    expect(find.text('dev'), findsOneWidget);

    // The other machine's link is up, but its census has not answered. This is
    // the window the report was about: a rebuild keeps the previous value, so
    // without the machine check the page went on showing machine A's
    // workspaces — and a tap on one of them opens a terminal for a pane that
    // does not exist on the machine the user just switched to.
    final gate = Completer<void>();
    final other = _ScriptedMachine(label: 'other', gate: gate);
    harness.container.read(_machineProvider.notifier).host = _hostB;
    harness.container.read(_statusProvider.notifier).status = Online(
          client: HerdrClient(other),
          hello: const HerdrHello(version: '0.9.0', protocol: 22),
          socketPath: '/tmp/herdr.sock',
          hostId: _hostB.id,
        );
    await _settle(tester);

    expect(
      find.text('dev'),
      findsNothing,
      reason: "machine A's workspaces are not machine B's workspaces",
    );
    // And it does not claim machine B has nothing, either: not read yet and
    // nothing there look identical on a phone, and only one of them is true.
    expect(find.text('No workspaces'), findsNothing);
    expect(find.text('Reading workspaces…'), findsOneWidget);

    // And the machine that DOES answer fills the page.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('other'), findsOneWidget);
  });

  testWidgets('a machine that has been read is served from memory on return',
      (tester) async {
    final daemon = FakeTerminalDaemon(paneRows: 46);
    final harness = await _Harness.pump(tester, prefs, daemon: daemon);
    await harness.openWorkspaces(tester);
    expect(find.text('dev'), findsOneWidget);

    // Away to another machine and back, with the link unable to answer the
    // second time: what was read from THIS machine is still its answer.
    harness.container.read(_machineProvider.notifier).host = _hostB;
    harness.container.read(_statusProvider.notifier).status =
        const Connecting(attempt: 1, afterLoss: true);
    await _settle(tester);
    expect(find.text('dev'), findsNothing);

    daemon.treeGate = Completer<void>();
    harness.container.read(_machineProvider.notifier).host = _hostA;
    harness.container.read(_statusProvider.notifier).status =
        const Connecting(attempt: 1, afterLoss: true);
    await _settle(tester);

    expect(
      find.text('dev'),
      findsOneWidget,
      reason: 'the machine we came back to was read before, and its tree is '
          'remembered by machine id',
    );
  });
}

const _hostA = HostProfile(
  id: 'a',
  label: 'devbox',
  username: 'dev',
  host: '10.0.0.5',
);
const _hostB = HostProfile(
  id: 'b',
  label: 'laptop',
  username: 'dev',
  host: '10.0.0.6',
);

/// The shell, its machine, and a connection whose state the test drives.
class _Harness {
  _Harness(this.container);

  final ProviderContainer container;

  static Future<_Harness> pump(
    WidgetTester tester,
    SharedPreferences prefs, {
    required FakeTerminalDaemon daemon,
  }) async {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        processKeeperProvider.overrideWithValue(_FakeKeeper()),
        currentHostProvider.overrideWith((ref) => ref.watch(_machineProvider)),
        connectionProvider.overrideWith(_ScriptedConnection.new),
        // Not what is under test, and the real one would open a second channel
        // on the fake daemon's script.
        boardProvider.overrideWith(_QuietBoard.new),
      ],
    );
    addTearDown(container.dispose);

    container.read(_machineProvider.notifier).host = _hostA;
    container.read(_statusProvider.notifier).status = Online(
          client: HerdrClient(daemon),
          hello: const HerdrHello(version: '0.9.0', protocol: 22),
          socketPath: '/tmp/herdr.sock',
          hostId: _hostA.id,
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HerdrTheme(
          colors: HerdrColors.dark,
          child: CupertinoApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: RootShell(),
          ),
        ),
      ),
    );
    // NOT `pumpAndSettle`: a machine that has not been read yet shows the
    // centred wait, and a spinner never settles (the same note the board's own
    // connection tests carry).
    await _settle(tester);
    return _Harness(container);
  }

  Future<void> openBoard(WidgetTester tester) async {
    await tester.tap(find.bySemanticsIdentifier(UiId.dockBoard));
    await _settle(tester);
  }

  Future<void> openWorkspaces(WidgetTester tester) async {
    await tester.tap(find.bySemanticsIdentifier(UiId.dockWorkspaces));
    await _settle(tester);
  }
}

/// Pumps a couple of frames rather than `pumpAndSettle`.
///
/// A recovery shows a spinner, and a spinner never settles — `pumpAndSettle`
/// would time out on the animation working exactly as designed (the same note
/// the board's own connection tests carry).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// The machine the app is pointed at, as a value the test can change.
class _Machine extends Notifier<HostProfile?> {
  @override
  HostProfile? build() => _hostA;

  /// Read back through the notifier: a setter needs its getter to be a pair.
  HostProfile? get host => state;
  set host(HostProfile? value) => state = value;
}

final _machineProvider =
    NotifierProvider<_Machine, HostProfile?>(_Machine.new);

/// The connection's state, so a loss can happen at a chosen moment.
class _Status extends Notifier<ConnectionStatus> {
  @override
  ConnectionStatus build() => const Disconnected();

  ConnectionStatus get status => state;
  set status(ConnectionStatus value) => state = value;
}

final _statusProvider =
    NotifierProvider<_Status, ConnectionStatus>(_Status.new);

class _ScriptedConnection extends ConnectionNotifier {
  /// No `async` and no await: the status is a value the test already owns, and
  /// the future is part of the base class's contract rather than this fake's
  /// work.
  @override
  Future<ConnectionStatus> build() =>
      Future<ConnectionStatus>.value(ref.watch(_statusProvider));
}

class _QuietBoard extends BoardNotifier {
  @override
  Future<AgentList> build() async => AgentList.empty();

  @override
  Future<void> refresh() async {}
}

/// A machine whose census can be held, so the switch can be examined in
/// flight. Everything it reports is labelled, so a test can tell whose rows are
/// on screen.
class _ScriptedMachine implements HerdrTransport {
  _ScriptedMachine({required this.label, this.gate});

  final String label;
  final Completer<void>? gate;

  @override
  Future<String> roundTrip(String requestLine) async {
    final method = (jsonDecode(requestLine) as Map)['method'] as String?;
    await gate?.future;
    return switch (method) {
      'workspace.list' =>
        '{"id":"x","result":{"type":"workspace_list","workspaces":['
            '{"workspace_id":"$label","number":1,"label":"$label",'
            '"focused":true,"tab_count":1,"pane_count":1}]}}',
      'tab.list' =>
        '{"id":"x","result":{"type":"tab_list","tabs":[{"tab_id":"$label:t1",'
            '"workspace_id":"$label","number":1,"label":"1","focused":true,'
            '"pane_count":1}]}}',
      'pane.list' =>
        '{"id":"x","result":{"type":"pane_list","panes":[{"pane_id":"$label:p1",'
            '"workspace_id":"$label","tab_id":"$label:t1","focused":true}]}}',
      _ => '{"id":"","error":{"code":"unknown_method","message":"n/a"}}',
    };
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError('no channels on this fake');

  @override
  Future<void> close() async {}
}

class _FakeKeeper implements ProcessKeeper {
  /// These fakes stand in for the Android one, which is the only platform
  /// where the feature exists -- and the settings row is drawn from this.
  @override
  bool get isSupported => true;

  @override
  Future<bool> start({required String title, required String text}) async => true;

  @override
  Future<void> stop() async {}
}
