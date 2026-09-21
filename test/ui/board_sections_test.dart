import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/board_sections.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/board/board_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which board sections are open, and whether the app remembers.
///
/// THE TWO THINGS THIS REPLACED, both of them bugs the user could see:
///
///   1. exactly ONE section was open by default, chosen by a rule on the domain
///      enum — so a board with a working agent and an idle one showed the idle
///      rows but hid the working ones behind a heading;
///   2. the choice lived in two `Set`s on the page's State and reset on any
///      rebuild of the root shell, so "close idle" lasted until the next trip
///      to Settings.
///
/// The replacement is stated in the first test: everything is open, and the
/// only state is what the user closed.
void main() {
  const host = HostProfile(
    id: 'h1',
    label: 'devbox',
    username: 'dev',
    host: '10.0.0.5',
  );

  /// A second machine, for the question "is the memory per machine?".
  const other = HostProfile(
    id: 'h2',
    label: 'laptop',
    username: 'dev',
    host: '10.0.0.6',
  );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpBoard(
    WidgetTester tester, {
    required AgentList board,
    HostProfile machine = host,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentHostProvider.overrideWithValue(machine),
          connectionProvider.overrideWith(_FixedConnection.new),
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
    // NOT `pumpAndSettle`: a working agent draws the thinking ring, which
    // repeats forever — the animation is the point, and a tree containing one
    // never settles. The board's own tests wait this way too.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Two agents in two different groups, so "which sections are open" has an
  /// answer that is not the same for both.
  AgentList twoGroups() => AgentList(
        agents: [
          _agent('w1:p1', 'working', 'build the thing'),
          _agent('w1:p2', 'idle', 'waiting around'),
        ],
      );

  /// One tap on a section heading, and the frame it produces.
  Future<void> tapHeading(WidgetTester tester, String heading) async {
    await tester.tap(sectionHeading(heading));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('the default', () {
    testWidgets('is everything open, not one preferred section', (tester) async {
      await pumpBoard(tester, board: twoGroups());

      expect(
        find.text('build the thing'),
        findsOneWidget,
        reason: 'working is the section that used to be open on its own — and '
            'the one the user was asking about',
      );
      expect(
        find.text('waiting around'),
        findsOneWidget,
        reason: 'and idle is open too: the default is no longer a choice '
            'between them',
      );
    });
  });

  group('the remembered answer', () {
    testWidgets(
        'closing a section hides its rows, and opening it brings them back',
        (tester) async {
      await pumpBoard(tester, board: twoGroups());

      await tapHeading(tester, 'WORKING');
      expect(find.text('build the thing'), findsNothing);
      expect(
        find.text('waiting around'),
        findsOneWidget,
        reason: 'one heading was tapped; the other section is untouched',
      );

      await tapHeading(tester, 'WORKING');
      expect(find.text('build the thing'), findsOneWidget);
    });

    testWidgets('is written down, for the NEXT launch', (tester) async {
      await pumpBoard(tester, board: twoGroups());
      await tapHeading(tester, 'IDLE');

      expect(prefs.getStringList('board.collapsed.h1'), ['idle']);
    });

    testWidgets('and is read back by a cold start', (tester) async {
      // A new container reading the same store IS the next launch: `main()`
      // awaits SharedPreferences and injects it, so this is the same path.
      await prefs.setStringList('board.collapsed.h1', ['idle']);
      await pumpBoard(tester, board: twoGroups());

      expect(
        find.text('waiting around'),
        findsNothing,
        reason: 'the preference is applied on the first frame, not after a tap',
      );
      expect(find.text('build the thing'), findsOneWidget);
    });
  });

  group('per machine', () {
    test('two machines keep two answers', () async {
      await prefs.setStringList('board.collapsed.h2', ['idle']);

      expect(_sections(containerFor(prefs, host)), isEmpty);
      expect(_sections(containerFor(prefs, other)), {AgentGroup.idle});
    });

    test('a group this build does not know is dropped, not fatal', () async {
      await prefs.setStringList('board.collapsed.h1', ['idle', 'gone']);

      expect(_sections(containerFor(prefs, host)), {AgentGroup.idle});
    });
  });
}

/// A container standing in for a launch pointed at one machine.
ProviderContainer containerFor(SharedPreferences prefs, HostProfile machine) {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentHostProvider.overrideWithValue(machine),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// What that machine's board has closed, read through the real provider.
Set<AgentGroup> _sections(ProviderContainer container) =>
    container.read(boardSectionsProvider);

/// The section's OWN heading, never the same word in the summary strip above
/// it — both are drawn, and a tap has to name one of them.
Finder sectionHeading(String text) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is Row &&
            widget.children.isNotEmpty &&
            widget.children.first is AnimatedRotation,
      ),
      matching: find.text(text),
    );

AgentInfo _agent(String paneId, String status, String title) =>
    AgentInfo.fromJson({
      'pane_id': paneId,
      'agent_status': status,
      'agent': 'pi',
      'title': title,
    });

class _FixedConnection extends ConnectionNotifier {
  @override
  Future<ConnectionStatus> build() async => Online(
        client: HerdrClient(_NoopTransport()),
        hello: const HerdrHello(version: '0.9.0', protocol: 22),
        socketPath: '/home/dev/.config/herdr/herdr.sock',
        hostId: 'h1',
      );
}

class _NoopTransport implements HerdrTransport {
  @override
  Future<String> roundTrip(String requestLine) async => '{}';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}

class _FixedBoard extends BoardNotifier {
  _FixedBoard(this.board);

  final AgentList board;

  @override
  Future<AgentList> build() async => board;

  @override
  Future<void> refresh() async {}
}
