import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/root_shell.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE SWITCH HAS TO ACTUALLY SWITCH.
///
/// This is the regression test for a bug found on the phone, and it is the one
/// bug a unit test of the policy could never have caught: the policy was right
/// and the controller was right, but `RootShell` read the setting with
/// `ref.read` instead of watching it — so flipping the switch changed the
/// stored value, redrew nothing, and left the notification sitting there. A
/// settings row that does not do anything is worse than no row at all.
///
/// Only the WIRING is under test here: the decision is in `keep_alive_test.dart`
/// and the service is in Kotlin.
void main() {
  testWidgets('turning the switch off stops a running service at once',
      (tester) async {
    final fake = _FakeKeepAlive();
    final container = await _pump(tester, fake);

    // A connection first: this is what makes the service wanted.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(
      fake.starts,
      1,
      reason: 'an online connection with the setting on holds the process',
    );

    final startsSoFar = fake.starts;

    // Now the user turns it off. No reconnect, no navigation, no restart.
    await container.read(settingsProvider.notifier).setKeepAlive(enabled: false);
    await tester.pumpAndSettle();

    expect(
      fake.stops,
      1,
      reason: 'the row must stop the service, not just store the preference',
    );
    expect(
      fake.starts,
      startsSoFar,
      reason: 'and must not start another one on the way out',
    );

    // And back on again, so the switch is proven to work in both directions.
    await container.read(settingsProvider.notifier).setKeepAlive(enabled: true);
    await tester.pumpAndSettle();
    expect(fake.starts, startsSoFar + 1);
    expect(fake.stops, 1);
  });
}

/// Pumps the shell with a connection already up and a fake service.
Future<ProviderContainer> _pump(WidgetTester tester, _FakeKeepAlive fake) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    // The dial is wanted, so the shell comes up online — without this the
    // policy has nothing to hold and the test would prove nothing.
    'flutter.settings.autoConnect': true,
    'flutter.settings.keepAlive': true,
  });
  prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      processKeeperProvider.overrideWithValue(fake),
      hostConnectorProvider.overrideWithValue(_OnlineConnector()),
      // The board is not what this test is about, and the real one subscribes
      // to events over a transport this fake does not carry — leaving a
      // resubscribe timer pending, which `flutter_test` (rightly) fails the
      // test over.
      boardProvider.overrideWith(_EmptyBoard.new),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: RootShell(),
        ),
      ),
    ),
  );
  return container;
}

late SharedPreferences prefs;

/// A connector whose one dial works, so the shell reaches `Online`.
class _OnlineConnector extends HostConnector {
  _OnlineConnector()
      : super(
          credentialsFor: (_) async => const SshSecrets(password: 'x'),
          verifyHostKey: (_) async => HostKeyVerdict.trust,
        );

  @override
  Future<({HerdrClientBundle bundle, String socketPath})> connect(
    HostProfile profile,
  ) async {
    const path = '/home/dev/.config/herdr/herdr.sock';
    return (
      bundle: HerdrClientBundle(transport: _PingingTransport(), socketPath: path),
      socketPath: path,
    );
  }
}

/// A board with nothing in it, so nothing subscribes to anything.
class _EmptyBoard extends BoardNotifier {
  @override
  Future<AgentList> build() async => AgentList.empty();
}

class _PingingTransport implements HerdrTransport {
  @override
  Future<String> roundTrip(String requestLine) async =>
      '{"id":"1","result":{"version":"0.9.0","protocol":22}}';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}

class _FakeKeepAlive implements ProcessKeeper {
  int starts = 0;
  int stops = 0;

  int get startCount => starts;

  @override
  Future<bool> start({required String title, required String text}) async {
    starts++;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}
