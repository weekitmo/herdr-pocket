import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/board/board_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the board reports the connection, and what it says about the board.
///
/// THE COMPLAINTS THIS ANSWERS, in order:
///
///   1. entering a machine on a bad network produced "unreachable" the instant
///      it failed, in a CARD — the same visual weight as an agent, on a screen
///      whose whole point is that agents are the only cards;
///   2. so the connection became a line: a mark, a few words, and a text button
///      for the one thing there is to do about it;
///   3. and the summary now lists the empty groups too, because "no working
///      agents" and "no working count shown" were the same picture.
void main() {
  const host = HostProfile(
    id: 'h1',
    label: 'devbox',
    username: 'dev',
    host: '10.0.0.5',
  );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpBoard(
    WidgetTester tester,
    ConnectionStatus status, {
    HostProfile? machine = host,
    AgentList? board,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentHostProvider.overrideWithValue(machine),
          connectionProvider.overrideWith(() => _FixedConnection(status)),
          if (board != null)
            boardProvider.overrideWith(() => _FixedBoard(board)),
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
            home: BoardPage(),
          ),
        ),
      ),
    );
    // NOT pumpAndSettle: the "thinking" ring repeats forever, so a tree that
    // contains one never settles — which is the animation working as designed.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('the connection, as a line', () {
    testWidgets('a dial in flight is narrated, stage by stage', (tester) async {
      await pumpBoard(tester, const Connecting());

      expect(find.text('Connecting…'), findsWidgets);
      // The ring is the "thinking" mark the rest of the app uses; the card this
      // replaced had none, because a card is a statement and this is a wait.
      expect(find.byType(WorkingRing), findsWidgets);
      expect(
        find.text('Connect'),
        findsNothing,
        reason: 'a button that restarts a dial already running only makes the '
            'wait longer',
      );
    });

    testWidgets('reaching the machine reads differently from leaving the phone',
        (tester) async {
      await pumpBoard(tester, const Connecting(stage: ConnectStage.verifying));

      expect(
        find.text('Verifying…'),
        findsWidgets,
        reason: 'a dial that has the transport up is not the same state as one '
            'that never left the phone',
      );
    });

    testWidgets('a retry counts itself', (tester) async {
      await pumpBoard(tester, const Connecting(attempt: 2));

      expect(find.text('Retrying 2/3…'), findsWidgets);
    });

    testWidgets('the last try says so rather than promising another',
        (tester) async {
      await pumpBoard(tester, const Connecting(attempt: connectionMaxAttempts));

      expect(
        find.text('One last attempt…'),
        findsWidgets,
        reason: '"retrying" promises another try, and on the last one there is '
            'not one',
      );
    });

    testWidgets('a failure is a line with a reconnect, not a card',
        (tester) async {
      await pumpBoard(
        tester,
        ConnectionFailed(
          HerdrTransportException(
            TransportFailure.connectFailed,
            'no route to host',
          ),
          attempts: connectionMaxAttempts,
        ),
      );

      expect(find.text('Connection failed'), findsWidgets);
      expect(find.text('Reconnect'), findsOneWidget);
      // No agent cards: a failed connection has no rows to show, and it must
      // not invent one to sit in.
      expect(find.byType(AgentCard), findsNothing);
      expect(find.byType(WorkingRing), findsNothing);
    });

    testWidgets('a failure the user can act on still says what to do',
        (tester) async {
      await pumpBoard(
        tester,
        ConnectionFailed(
          HerdrTransportException(
            TransportFailure.connectFailed,
            // The sentinel alone on its line — what the shell prelude prints.
            'sh: herdr: command not found\n$herdrNotInstalledSentinel\n',
          ),
        ),
      );

      expect(find.text('Connection failed'), findsWidgets);
      expect(
        find.textContaining('Install herdr'),
        findsOneWidget,
        reason: 'the one failure with a fix keeps its one line of guidance',
      );
    });

    testWidgets('nothing has been dialled yet: a line, a machine and Connect',
        (tester) async {
      await pumpBoard(tester, const Disconnected());

      expect(find.text('Not connected'), findsWidgets);
      expect(
        find.text('dev@10.0.0.5:22'),
        findsOneWidget,
        reason: 'the machine about to be dialled is the useful fact here',
      );
      // "Connect", not "Reconnect": nothing failed, so nothing needs re-doing.
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Reconnect'), findsNothing);
    });

    testWidgets('with no machine saved, the button goes and adds one',
        (tester) async {
      await pumpBoard(tester, const Disconnected(), machine: null);

      expect(find.text('Add machine'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
    });
  });

  group('the summary lists every group', () {
    testWidgets('including the ones at zero', (tester) async {
      await pumpBoard(
        tester,
        _online(),
        board: AgentList(agents: [_agent('w1:p1', 'working')]),
      );

      // The loudest fact on the screen is still "nothing needs you", and the
      // quietest is still listed rather than omitted. `findsWidgets` because a
      // group with rows also gets a SECTION heading of its own — the summary is
      // the one that lists all five.
      for (final group in AgentGroup.values) {
        expect(
          find.text(_heading(group)),
          findsWidgets,
          reason: '${group.name} is missing from the summary',
        );
      }
      expect(summary('0'), findsNWidgets(AgentGroup.values.length - 1));
      expect(summary('1'), findsOneWidget);
    });

    testWidgets('a board with nothing running is zeroes, not an empty strip',
        (tester) async {
      await pumpBoard(tester, _online(), board: AgentList.empty());

      expect(summary('0'), findsNWidgets(AgentGroup.values.length));
      // And the empty state still says why there are no rows.
      expect(find.textContaining('No agents yet'), findsOneWidget);
    });
  });
}

/// A word or count INSIDE the summary strip, never the section header that
/// repeats it below.
Finder summary(String text) => find.descendant(
      of: find.byKey(boardSummaryKey),
      matching: find.text(text),
    );

String _heading(AgentGroup group) => switch (group) {
      AgentGroup.needsYou => 'APPROVALS',
      AgentGroup.stopped => 'STOPPED',
      AgentGroup.unrecognised => 'OTHER',
      AgentGroup.working => 'WORKING',
      AgentGroup.idle => 'IDLE',
    };

/// A live connection, because the summary is the answer to a question — and
/// there is no answer before the question has been asked. An offline board
/// shows its connection line instead of a row of zeroes that would be a lie.
Online _online() => Online(
      client: HerdrClient(_NoopTransport()),
      hello: const HerdrHello(version: '0.9.0', protocol: 22),
      socketPath: '/home/dev/.config/herdr/herdr.sock',
    );

class _NoopTransport implements HerdrTransport {
  @override
  Future<String> roundTrip(String requestLine) async => '{}';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}

AgentInfo _agent(String paneId, String status) => AgentInfo.fromJson({
      'pane_id': paneId,
      // The key is `agent_status`, not `status` — a wrong one parses to null,
      // which lands the row in `unrecognised` and quietly makes a "working"
      // fixture into a different test.
      'agent_status': status,
      'agent': 'pi',
    });

class _FixedConnection extends ConnectionNotifier {
  _FixedConnection(this.status);

  final ConnectionStatus status;

  @override
  Future<ConnectionStatus> build() async => status;
}

class _FixedBoard extends BoardNotifier {
  _FixedBoard(this.board);

  final AgentList board;

  @override
  Future<AgentList> build() async => board;

  @override
  Future<void> refresh() async {}
}
