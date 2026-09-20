import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/latency.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/hosts/hosts_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The latency number on a machine's card, and the gesture that takes one.
///
/// What is asserted here is the READOUT, not the measurement: the measuring
/// lives in `test/data/latency_test.dart`, and this file is about where the
/// answer is shown and what a card says when there is no answer yet.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hosts.profiles': '[{"id":"h1","label":"devbox","username":"dev",'
          '"host":"10.0.0.5","port":22}]',
      'hosts.selected': 'h1',
    });
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpHosts(WidgetTester tester, SpyLatency latency) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          hostLatencyProvider.overrideWith(() => latency),
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
            home: HostsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a machine that has never been measured shows no number',
      (tester) async {
    // A blank slot is honest; `0 ms` would be a claim about a machine that has
    // not said anything.
    await pumpHosts(tester, SpyLatency());

    expect(find.textContaining('ms'), findsNothing);
    expect(find.text('Test latency'), findsNothing);
  });

  testWidgets('a measured machine shows its number', (tester) async {
    await pumpHosts(
      tester,
      SpyLatency(readings: {
        'h1': const HostLatency(millis: 42),
      }),
    );

    expect(find.text('42 ms'), findsOneWidget);
  });

  testWidgets('a failed measurement says so, beside the last number',
      (tester) async {
    await pumpHosts(
      tester,
      SpyLatency(readings: {
        'h1': const HostLatency(millis: 42, failed: true),
      }),
    );

    expect(find.text('No answer'), findsOneWidget);
    expect(
      find.text('42 ms'),
      findsNothing,
      reason: 'the failure is the news; the old number would be shown as the '
          'current state, which is exactly what it is not',
    );
  });

  testWidgets('press and hold offers a latency test', (tester) async {
    final latency = SpyLatency();
    await pumpHosts(tester, latency);

    await tester.longPress(find.text('devbox'));
    await tester.pumpAndSettle();

    expect(find.text('Test latency'), findsOneWidget);

    await tester.tap(find.text('Test latency'));
    await tester.pumpAndSettle();

    expect(
      latency.measured,
      ['h1'],
      reason: 'the row applies the answer itself, so there is nothing to open '
          'and nothing to wait for',
    );
  });
}

/// The real notifier, with the measurement replaced by a note that it happened.
///
/// A SPY RATHER THAN A FAKE MAP because the question this file asks is about
/// the wiring — does the row read the reading, does the gesture reach the
/// measurement — and a hand-built map would not prove either end.
class SpyLatency extends HostLatencyNotifier {
  SpyLatency({this.readings = const {}});

  final Map<String, HostLatency> readings;
  final List<String> measured = [];

  @override
  Map<String, HostLatency> build() => readings;

  @override
  Future<void> measure(HostProfile host, {HerdrClient? live}) async {
    measured.add(host.id);
  }
}
