import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pane these tests attach to, as `pane.list` reports it.
const String kTestPaneId = 'w1:p1';

/// Everything needed to mount [TerminalPage] against a scripted machine.
///
/// Shared rather than copied per test file. The fakes below are the only way to
/// exercise this screen without a daemon, and three copies of them would drift
/// in exactly the way that makes a green suite mean less than it looks like:
/// the page would be tested against three slightly different machines.
Future<FakeTerminalDaemon> pumpTerminalPage(
  WidgetTester tester, {
  required SharedPreferences prefs,
  int paneRows = 46,
  Locale locale = const Locale('en'),
  FakeTerminalDaemon? daemon,
}) async {
  final machine = daemon ?? FakeTerminalDaemon(paneRows: paneRows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        connectionProvider.overrideWith(
          () => FixedConnection(
            Online(
              client: HerdrClient(machine),
              hello: const HerdrHello(version: '0.9.0', protocol: 22),
              socketPath: '/tmp/herdr.sock',
            ),
          ),
        ),
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
          locale: locale,
          home: const TerminalPage(paneId: kTestPaneId, title: 'agent'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return machine;
}

/// Mounts the page against a machine that is not connected.
///
/// For questions about SHAPE rather than about bytes: nothing here sends
/// anything, and a live session would make the test depend on a daemon to ask
/// about a widget.
Future<void> pumpOfflineTerminal(
  WidgetTester tester, {
  required SharedPreferences prefs,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        connectionProvider.overrideWith(OfflineConnection.new),
      ],
      child: const HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: TerminalPage(paneId: kTestPaneId, title: 'agent'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The painter of the terminal surface, and nothing else's.
TerminalPainter surfacePainter(WidgetTester tester) {
  final surface = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is TerminalPainter,
  );
  return tester.widget<CustomPaint>(surface).painter! as TerminalPainter;
}

/// How many rows the surface can show at its current size.
int boxRows(WidgetTester tester, TerminalPainter painter) {
  final surface = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is TerminalPainter,
  );
  return (tester.getSize(surface).height / painter.cellHeight).floor();
}

/// A daemon that answers the tree, runs commands, and holds one terminal
/// channel open.
///
/// It really IS a `RemoteCommandRunner`, so the same page that opens a terminal
/// also sees the command channel the file, git and composer menus use — which is
/// how a test can script a skills probe without a machine.
class FakeTerminalDaemon
    implements HerdrTransport, RemoteStreamRunner, RemoteCommandRunner {
  FakeTerminalDaemon({
    required this.paneRows,
    this.agent = 'claude',
    this.scrollOffset = 0,
    this.scrollMax = 0,
    this.scrollEvents = true,
  });

  final int paneRows;

  /// What `pane.list` reports this pane is scrolled back to.
  final int scrollOffset;

  /// How much history `pane.list` reports for this pane.
  ///
  /// ZERO IS THE DAEMON'S REAL ANSWER for a pane whose program has printed less
  /// than a screenful, and it is the answer the terminal screen has to act on:
  /// a swipe on such a pane must not draw a "3 lines back" bar over a screen
  /// that never moved. A test that wants a scrollable pane says so here.
  final int scrollMax;

  /// Whether the daemon opens `pane.scroll_changed`.
  ///
  /// False is the degrade path — an older protocol, or a daemon that refuses —
  /// and the page has to keep working on its own mirror when it happens.
  final bool scrollEvents;

  /// Holds the workspace tree back until it is completed.
  ///
  /// FOR THE LATE-CENSUS CASE: the page opens its session anyway once the seed
  /// deadline passes, so a test can reach a state where the pane's `agent` is
  /// not known yet and then let the census arrive — which is what happens on a
  /// phone when the tree provider has been disposed between the page opening
  /// and the chat window being opened.
  Completer<void>? treeGate;

  /// What `pane.list` reports for this pane.
  ///
  /// Null means the key is ABSENT, which is exactly how herdr describes a plain
  /// shell — see `PaneInfo.agent`, and the composer's own use of it. Every
  /// question about "is this a TUI" is answered by this field, so a test that
  /// wants a shell has to say so here rather than by hoping.
  final String? agent;

  /// Every command a terminal session was opened with.
  final List<String> openCommands = [];

  /// Every command run through the shell channel, in order.
  final List<String> shellCommands = [];

  /// What the shell channel answers. Empty by default: a reply with no sentinel,
  /// which every reader in the app already has a branch for.
  String Function(String command)? onCommand;

  final List<String> _written = [];
  final _lines = StreamController<String>.broadcast();

  /// The event channel, once something subscribes. Null until then.
  StreamController<String>? _events;

  /// What every subscription asked for, verbatim.
  final List<Map<String, Object?>> subscriptions = [];

  /// Everything the app has written on the terminal channel.
  List<String> sentOnTerminal() => List.unmodifiable(_written);

  /// The frames of the terminal channel, decoded.
  List<Map<String, Object?>> inputCommands() => _written
      .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
      .where((m) => m['type'] == 'terminal.input')
      .toList();

  @override
  Future<HerdrDuplex> openCommandDuplex(String command) async {
    openCommands.add(command);
    return _FakeDuplex(command, _lines.stream, _written);
  }

  @override
  Future<String> runCommand(String command) async {
    shellCommands.add(command);
    return onCommand?.call(command) ?? '';
  }

  /// Sends one rendered frame, the way the daemon does.
  void emitFrame({
    required String data,
    int width = 65,
    int height = 46,
    bool full = true,
  }) {
    _lines.add(
      jsonEncode({
        'type': 'terminal.frame',
        'seq': ++_seq,
        'encoding': 'ansi',
        'full': full,
        'width': width,
        'height': height,
        'bytes': base64.encode(utf8.encode(data)),
      }),
    );
  }

  int _seq = 0;

  @override
  Future<String> roundTrip(String requestLine) async {
    final request = (jsonDecode(requestLine) as Map).cast<String, Object?>();
    final method = request['method'];
    if (const {'workspace.list', 'tab.list', 'pane.list'}.contains(method)) {
      await treeGate?.future;
    }
    return switch (method) {
      'workspace.list' =>
        '{"id":"x","result":{"type":"workspace_list","workspaces":['
            '{"workspace_id":"w1","number":1,"label":"dev","focused":true,'
            '"tab_count":1,"pane_count":1}]}}',
      'tab.list' =>
        '{"id":"x","result":{"type":"tab_list","tabs":['
            '{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1",'
            '"focused":true,"pane_count":1}]}}',
      // `cwd` and `agent` are not decoration: they are what the composer's two
      // menus are ABOUT — the project-scoped skill and MCP roots resolve under
      // the pane's own directory, and the agent decides which of them apply.
      'pane.list' =>
        '{"id":"x","result":{"type":"pane_list","panes":[{"pane_id":"$kTestPaneId",'
            '"workspace_id":"w1","tab_id":"w1:t1","focused":true,'
            '"cwd":"/home/u/proj",'
            // The key is OMITTED for a shell, exactly as herdr omits it.
            '${agent == null ? '' : '"agent":"$agent",'}'
            '"revision":1,"scroll":{"offset_from_bottom":$scrollOffset,'
            '"max_offset_from_bottom":$scrollMax,"viewport_rows":$paneRows}}]}}',
      // Anything else is answered "unknown method" the way the daemon does,
      // rather than by hanging: a page that waits forever in a test is a test
      // that times out with no explanation.
      _ => '{"id":"","error":{"code":"unknown_method","message":"n/a"}}',
    };
  }

  /// The event channel a subscription opens.
  ///
  /// Implemented rather than thrown because the terminal screen now watches
  /// `pane.scroll_changed` while it is open, and a harness that could not answer
  /// would leave that path — the one that corrects a lying scroll bar — only
  /// ever exercised against a live machine.
  @override
  Future<HerdrDuplex> openDuplex(String openLine) async {
    final request = (jsonDecode(openLine) as Map).cast<String, Object?>();
    if (request['method'] != 'events.subscribe') {
      throw UnimplementedError('not an event channel: ${request['method']}');
    }
    subscriptions.add((request['params']! as Map).cast<String, Object?>());
    final controller = StreamController<String>();
    _events = controller;
    if (scrollEvents) {
      controller.add(
        '{"id":"${request['id']}","result":{"type":"subscription_started"}}',
      );
    } else {
      controller.add(
        '{"id":"${request['id']}","error":{"code":"invalid_request",'
        '"message":"unknown subscription"}}',
      );
    }
    return _FakeDuplex('', controller.stream, _written);
  }

  /// Announces a new scroll state the way the daemon does.
  void emitScroll({int? offset, int? max}) {
    final controller = _events;
    if (controller == null || controller.isClosed) return;
    controller.add(
      jsonEncode({
        'event': 'pane.scroll_changed',
        'data': {
          'pane_id': kTestPaneId,
          'workspace_id': 'w1',
          'scroll': {
            'offset_from_bottom': offset ?? scrollOffset,
            'max_offset_from_bottom': max ?? scrollMax,
            'viewport_rows': paneRows,
          },
        },
      }),
    );
  }

  @override
  Future<void> close() async {}
}

class _FakeDuplex implements HerdrDuplex {
  _FakeDuplex(this.command, this._incoming, this._outgoing);

  final String command;
  final Stream<String> _incoming;
  final List<String> _outgoing;

  @override
  Stream<String> get lines => _incoming;

  @override
  void send(String line) => _outgoing.add(line);

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {}
}

/// A connection that will never come up, for questions about shape.
class OfflineConnection extends ConnectionNotifier {
  @override
  Future<ConnectionStatus> build() async => const Disconnected();
}

class FixedConnection extends ConnectionNotifier {
  FixedConnection(this._status);

  final ConnectionStatus _status;

  @override
  Future<ConnectionStatus> build() async => _status;
}
