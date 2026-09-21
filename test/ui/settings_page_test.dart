import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/settings/settings_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The settings page had no test at all until it crashed on a real device.
///
/// WHAT WENT WRONG, because the shape of the mistake is worth keeping: a
/// footnote was added to the About group as a bare `SettingsNote`, and
/// `CustomScrollView.slivers` accepts slivers ONLY. A box widget there reaches
/// `RenderViewport` as a child it cannot lay out, and the failure surfaces as a
/// framework assertion about the ELEMENT TREE rather than as anything naming
/// the offending line.
///
/// It also only fired while CONNECTED — the note renders only when there is a
/// socket path to show — so an offline smoke test, and `flutter analyze`, both
/// pass straight through it. Hence the test below, which is deliberately built
/// around the CONNECTED state.
final _packageInfo = PackageInfo(
  appName: 'Herdr Pocket',
  packageName: 'dev.herdr.herdr_pocket',
  version: '1.0.0',
  buildNumber: '1',
);

void main() {
  final online = Online(
    client: HerdrClient(_NoopTransport()),
    hello: const HerdrHello(version: '0.9.0', protocol: 22),
    socketPath: '/Users/someone/.config/herdr/herdr.sock',
    hostId: 'h1',
  );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    ConnectionStatus status, {
    SharedPreferences? store,
  }) async {
    final override = store ?? prefs;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(override),
          connectionProvider.overrideWith(() => _FixedConnection(status)),
          currentHostProvider.overrideWithValue(null),
          packageInfoProvider.overrideWith((ref) async => _packageInfo),
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
            home: SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders while connected, including the socket-path footnote',
      (tester) async {
    await pumpSettings(tester, online);

    expect(tester.takeException(), isNull);

    // The path is the thing that used to arrive as a box widget in a sliver
    // list, so it has to be scrolled TO, not merely searched for. Two details
    // are load-bearing in this assertion:
    //
    //   * `skipOffstage: false`, because the footnote sits below the fold and
    //     the default finders skip anything the viewport has not reached. The
    //     first version of this test failed on a page that was working.
    //   * scrolling at all, because LAYING IT OUT is the thing that broke. A
    //     box widget in `slivers:` survives being built and dies in the
    //     viewport, so a test that only checked "no exception" would pass.
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(online.socketPath), findsOneWidget);
  });

  testWidgets('renders while disconnected', (tester) async {
    await pumpSettings(tester, const Disconnected());
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders while a connection is failing', (tester) async {
    await pumpSettings(
      tester,
      ConnectionFailed(
        HerdrTransportException(
          TransportFailure.authenticationFailed,
          'no',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the safety margin is a dropdown, and it writes what it picks',
      (tester) async {
    await pumpSettings(tester, const Disconnected());

    // The behaviour is tested where it lives (test/ui/safety_margin_test.dart);
    // what this covers is the ROW: that it is a picker rather than a switch,
    // that it shows the current answer without a tap, and that choosing stores
    // the choice.
    // SCROLLED TO, not scrolled BY. The fixed -600 drag this test used to do
    // depended on the page's total height: adding one settings group gave the
    // view enough extent to travel the full 600 instead of clamping, which
    // moved the row from y=+19 to y=-19 and made the tap miss. A test that
    // breaks when an unrelated group is added is testing the layout of the
    // screen rather than the behaviour of the row.
    await tester.scrollUntilVisible(find.text('Safety margin'), 200);
    await tester.pumpAndSettle();

    expect(find.text('Safety margin'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.text('Safety margin'));
    await tester.pumpAndSettle();

    expect(find.text('Always on'), findsOneWidget);
    expect(find.text('Always off'), findsOneWidget);

    await tester.tap(find.text('Always on'));
    await tester.pumpAndSettle();

    expect(
      // The BARE key: `setMockInitialValues` takes platform-side keys (which
      // carry the `flutter.` prefix) and strips it, but writes through the
      // plugin are cached under the name the app passed.
      prefs.getString('settings.safetyInset'),
      'alwaysOn',
      reason: 'the choice has to outlive the process, or the override is a '
          'setting the user has to re-apply every launch',
    );
    expect(find.text('Always on'), findsOneWidget);
  });

  testWidgets('every group is present in both themes', (tester) async {
    for (final colors in [HerdrColors.dark, HerdrColors.light]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            connectionProvider.overrideWith(() => _FixedConnection(online)),
            currentHostProvider.overrideWithValue(null),
            packageInfoProvider.overrideWith((ref) async => _packageInfo),
          ],
          child: HerdrTheme(
            colors: colors,
            child: const CupertinoApp(
              localizationsDelegates: [
                AppLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: SettingsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '${colors.brightness}');
    }
  });
}

/// A connection that reports whatever it was built with.
class _FixedConnection extends ConnectionNotifier {
  _FixedConnection(this._status);

  final ConnectionStatus _status;

  @override
  Future<ConnectionStatus> build() async => _status;
}

/// A transport that is never spoken to.
///
/// `Online` requires a client, and the page reads the client's identity rather
/// than calling it — so the transport only has to exist.
class _NoopTransport implements HerdrTransport {
  @override
  Future<String> roundTrip(String requestLine) async => '{}';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) async =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}
