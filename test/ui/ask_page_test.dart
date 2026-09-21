import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/board/ask_page.dart';

/// The approval screen, end to end.
///
/// The domain and the controller are tested on their own; this file tests the
/// thing that only a rendered widget can answer: does the SCREEN make the same
/// promise the logic does? Specifically — when the agent moved on, does no key
/// reach the daemon, and does the page say so instead of showing a success?
///
/// The daemon is scripted per method so each test can make exactly one fact
/// true, and every request is recorded so a "did not send" assertion has
/// something to be about.
class _ScriptedDaemon implements HerdrTransport {
  _ScriptedDaemon(this.handlers);

  final Map<String, String Function(Map<String, Object?> params)> handlers;
  final List<String> methods = [];

  @override
  Future<String> roundTrip(String requestLine) async {
    final req = (jsonDecode(requestLine) as Map).cast<String, Object?>();
    final method = req['method']! as String;
    methods.add(method);
    final handler = handlers[method];
    if (handler == null) {
      return '{"id":"","error":{"code":"unknown_method","message":"nope"}}';
    }
    return handler((req['params']! as Map).cast<String, Object?>());
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) => throw UnimplementedError();

  @override
  Future<void> close() async {}

  bool got(String method) => methods.contains(method);
}

class _FixedConnection extends ConnectionNotifier {
  _FixedConnection(this._status);

  final ConnectionStatus _status;

  @override
  Future<ConnectionStatus> build() async => _status;
}

/// A board that does nothing, so a successful send cannot drag the real
/// notifier (and therefore a real connection) into the test.
class _QuietBoard extends BoardNotifier {
  @override
  Future<AgentList> build() async => AgentList.empty();

  @override
  Future<void> refresh() async {}
}

const _ok = '{"id":"x","result":{"type":"ok"}}';

String _screen(String text) =>
    '{"id":"x","result":{"type":"pane_read","read":'
    '{"pane_id":"w1:p1","text":${jsonEncode(text)},"truncated":false,"revision":0}}}';

String _agentList({String status = 'blocked', int seq = 10}) =>
    '{"id":"x","result":{"type":"agent_list","agents":['
    '{"pane_id":"w1:p1","agent":"claude","agent_status":"$status",'
    '"state_change_seq":$seq}]}}';

const _menuScreen = '''
Do you want to proceed?
❯ 1. Yes
  2. No''';

AgentRow _row({String status = 'blocked'}) => AgentRow(
      info: AgentInfo.fromJson({
        'pane_id': 'w1:p1',
        'agent': 'claude',
        'agent_status': status,
        'state_change_seq': 10,
      }),
      isLive: true,
    );

Widget _host(Widget child, HerdrTransport transport) => ProviderScope(
      overrides: [
        connectionProvider.overrideWith(
          () => _FixedConnection(
            Online(
              client: HerdrClient(transport),
              hello: const HerdrHello(version: '0.9.0', protocol: 22),
              socketPath: '/tmp/herdr.sock',
              hostId: 'h1',
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

void main() {
  testWidgets('shows the question and every option it found', (tester) async {
    await tester.pumpWidget(
      _host(
        AskPage(row: _row()),
        _ScriptedDaemon({
          'agent.read': (_) => _screen(_menuScreen),
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('It is asking you'), findsOneWidget);
    expect(find.text('Do you want to proceed?'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    // The free-text escape hatch is always there — it is the only answer
    // available when the options are not readable.
    expect(find.text('Type only'), findsOneWidget);
  });

  testWidgets('pressing an option sends exactly its key', (tester) async {
    final daemon = _ScriptedDaemon({
      'agent.read': (_) => _screen(_menuScreen),
      'agent.list': (_) => _agentList(),
      'pane.list': (_) => '{"id":"x","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1"}]}}',
      'agent.send_keys': (_) => _ok,
    });

    await tester.pumpWidget(_host(AskPage(row: _row()), daemon));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();

    expect(daemon.got('agent.send_keys'), isTrue);
    expect(find.text('Handed to herdr'), findsOneWidget);
  });

  testWidgets('a stale screen sends NOTHING and says so', (tester) async {
    // The single most important assertion in this file. The agent moved on
    // between the read and the tap; a keystroke here would land in whatever it
    // is doing instead.
    final daemon = _ScriptedDaemon({
      'agent.read': (_) => _screen(_menuScreen),
      'agent.list': (_) => _agentList(status: 'working', seq: 11),
      'pane.list': (_) => '{"id":"x","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1"}]}}',
    });

    await tester.pumpWidget(_host(AskPage(row: _row()), daemon));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();

    expect(daemon.got('agent.send_keys'), isFalse);
    expect(daemon.got('agent.prompt'), isFalse);
    expect(daemon.got('pane.send_text'), isFalse);
    expect(
      find.textContaining('It moved while you were reading'),
      findsOneWidget,
    );
  });

  testWidgets('an unreadable screen refuses to guess, and shows the screen',
      (tester) async {
    await tester.pumpWidget(
      _host(
        AskPage(row: _row()),
        _ScriptedDaemon({
          'agent.read': (_) => _screen('just some output\nwith no question at all'),
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not tell what it is asking'), findsOneWidget);
    // The raw screen is the fallback that keeps this honest — the text is in
    // hand, so it is shown rather than apologised for.
    expect(find.text('Its screen'), findsOneWidget);
    expect(find.textContaining('just some output'), findsOneWidget);
  });

  testWidgets('a read failure offers the terminal instead of a dead end',
      (tester) async {
    await tester.pumpWidget(
      _host(
        AskPage(row: _row()),
        _ScriptedDaemon({}), // agent.read is unknown => the daemon refuses
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not read its screen'), findsOneWidget);
    expect(find.text('Answer in the terminal'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
