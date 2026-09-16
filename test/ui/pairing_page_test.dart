import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/host_store.dart';
import 'package:herdr_pocket/data/pairing.dart';
import 'package:herdr_pocket/data/phone_identity.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/pairing.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';
import 'package:herdr_pocket/domain/pairing/pairing_ticket.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/pairing/pairing_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the pairing screen and for what pairing COMMITS on success.
///
/// The commit half is the part worth testing hardest, because its failure is
/// silent in a way the screen never shows: a pairing that writes the profile
/// before the credential produces a machine that appears in the list, that the
/// user then taps, and that fails to authenticate with nothing to explain why.
class _FakeFlow implements PairingFlow {
  _FakeFlow({this.result, this.failure});

  final PairingResult? result;
  final PairingException? failure;

  final List<PairingTicket> seen = [];

  @override
  Duration get timeout => const Duration(seconds: 20);

  @override
  SshSocketTransport Function({
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
  }) get connect => throw UnimplementedError();

  @override
  Future<PairingResult> run(
    PairingTicket ticket, {
    PhoneIdentity? identity,
    String? label,
  }) async {
    seen.add(ticket);
    final f = failure;
    if (f != null) throw f;
    return result!;
  }
}

void main() {
  late SharedPreferences prefs;

  // RESET PER TEST, not once. Both stores are process-wide singletons behind
  // these mocks, so a machine added by one test is still there for the next —
  // and the test that asserts "a failed pairing leaves no machine behind" then
  // fails on a machine a DIFFERENT test created successfully. That is a test
  // finding its own leftovers, which is worse than no test.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The credential and pin stores are `FlutterSecureStorage` underneath, and
    // a platform channel has no implementation under `flutter test`. Without
    // this the commit path throws `MissingPluginException` — a failure of the
    // harness, not of the code, which would hide the ordering bug these tests
    // exist to catch.
    FlutterSecureStorage.setMockInitialValues({});
  });

  String encodePayload({
    String host = '10.0.0.2',
    int port = 22,
    String user = 'you',
    String name = 'Mac mini',
  }) =>
      base64Url
          .encode(utf8.encode(jsonEncode({
            'v': pairingProtocolVersion,
            'h': host,
            'p': port,
            'u': user,
            // The seed, not a PEM: `hdp pair` sends 32 bytes and the app
            // rebuilds the key file, which is what keeps the QR small enough
            // to scan without a wide terminal.
            'k': base64.encode(List<int>.generate(32, (i) => i)),
            'f': 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
            'n': name,
          })))
          .replaceAll('=', '');

  PairingResult sampleResult() {
    final identity = PhoneIdentity.generate(label: 'test phone');
    return PairingResult(
      profile: const HostProfile(
        id: 'pair-1',
        label: 'Mac mini',
        host: '10.0.0.2',
        port: 22,
        username: 'you',
      ),
      identity: identity,
      hostKey: HostKeyRecord(
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
        approvedAt: DateTime(2026),
      ),
    );
  }

  ProviderContainer containerWith(_FakeFlow flow) => ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          pairingFlowProvider.overrideWithValue(flow),
        ],
      );

  group('the screen', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          // `HerdrColors.dark` is a `static const`, so the whole subtree can
          // be constant — which is also why writing `const HerdrColors.dark`
          // is an error: that says "call a constructor named dark".
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
              home: PairingPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers both doors, and marks the scan as recommended',
        (tester) async {
      await pump(tester);

      expect(find.text('Device pairing'), findsOneWidget);
      expect(find.text('SCAN THE PAIRING CODE'), findsOneWidget);
      expect(
        find.text('Recommended'),
        findsOneWidget,
        reason: 'the user asked for the scan to be marked as the easy way in',
      );
      expect(find.text('ENTER PAIRING INFORMATION'), findsOneWidget);
      // NOT uppercased: `sectionTitle` upper-cases the group headings, and
      // the button is not one of those.
      expect(find.text('Pair and connect'), findsOneWidget);

      // The idle line says where the result will appear, so the empty space
      // under the button is explained rather than merely empty.
      expect(
        find.textContaining('The result appears here'),
        findsOneWidget,
      );
    });

    testWidgets('an empty submit explains itself instead of doing nothing',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('Pair and connect'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No pairing string'), findsOneWidget);
    });

    testWidgets('a bad paste gets a sentence that says what was expected',
        (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(CupertinoTextField), 'not a pairing string');
      await tester.tap(find.text('Pair and connect'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('long run of letters'),
        findsOneWidget,
        reason: 'the message a user is most likely to read must name what the '
            'input should have looked like, not that it was wrong',
      );
    });
  });

  group('what pairing commits', () {
    test('success writes the credential BEFORE the profile', () async {
      final flow = _FakeFlow(result: sampleResult());
      final container = containerWith(flow);
      addTearDown(container.dispose);

      await container
          .read(pairingControllerProvider.notifier)
          .start(encodePayload());

      final state = container.read(pairingControllerProvider);
      expect(state, isA<PairingSucceeded>());

      // THE ORDER IS THE ASSERTION. Adding the profile mutates the host list,
      // and the connection layer watches that list — so a profile whose secret
      // is not on disk yet produces an authentication failure, and nothing
      // retries it afterwards.
      final secrets = await container
          .read(hostSecretsStoreProvider)
          .read('pair-1');
      expect(
        secrets?.privateKeyPem,
        contains('BEGIN OPENSSH PRIVATE KEY'),
        reason: "the phone's own key must be in the keystore by the time the "
            'machine is visible in the list',
      );

      final hosts = container.read(hostListProvider);
      expect(hosts.map((h) => h.id), contains('pair-1'));
      expect(
        container.read(selectedHostIdProvider),
        'pair-1',
        reason: 'pairing is the user saying "use this one"',
      );
    });

    test('the pinned host key is the one the pairing string named', () async {
      final result = sampleResult();
      final flow = _FakeFlow(result: result);
      final container = containerWith(flow);
      addTearDown(container.dispose);

      await container
          .read(pairingControllerProvider.notifier)
          .start(encodePayload());

      final pin = await container
          .read(hostKeyStoreProvider)
          .read(result.profile.pinKey);
      expect(pin?.fingerprint, result.hostKey.fingerprint);
      expect(
        result.profile.pinKey,
        '10.0.0.2:22',
        reason: 'the pin key must match the one the connection layer looks up, '
            'or the first real connection asks the user to trust a host they '
            'just paired with',
      );
    });

    test('a failed pairing writes nothing at all', () async {
      final flow = _FakeFlow(
        failure: const PairingException(
          PairingFailure.bootstrapRejected,
          detail: 'expired',
        ),
      );
      final container = containerWith(flow);
      addTearDown(container.dispose);

      await container
          .read(pairingControllerProvider.notifier)
          .start(encodePayload());

      expect(
        container.read(pairingControllerProvider),
        isA<PairingRejected>().having(
          (s) => s.reason,
          'reason',
          PairingFailureReason.codeExpired,
        ),
      );
      expect(
        container.read(hostListProvider),
        isEmpty,
        reason: 'a half-finished pairing must leave no machine behind',
      );
      expect(await container.read(hostSecretsStoreProvider).read('pair-1'), isNull);
    });

    test('a host key mismatch is reported as itself', () async {
      // The one failure that must never be folded into "pairing failed": it is
      // either an expired code or someone in the middle, and the user has to
      // decide which.
      final flow = _FakeFlow(
        failure: const PairingException(PairingFailure.hostKeyMismatch),
      );
      final container = containerWith(flow);
      addTearDown(container.dispose);

      await container
          .read(pairingControllerProvider.notifier)
          .start(encodePayload());

      expect(
        container.read(pairingControllerProvider),
        isA<PairingRejected>().having(
          (s) => s.reason,
          'reason',
          PairingFailureReason.hostKeyMismatch,
        ),
      );
    });

    test('a malformed string never reaches the flow', () async {
      final flow = _FakeFlow(result: sampleResult());
      final container = containerWith(flow);
      addTearDown(container.dispose);

      await container
          .read(pairingControllerProvider.notifier)
          .start('nonsense!!');

      expect(flow.seen, isEmpty, reason: 'nothing should have been dialled');
      expect(container.read(pairingControllerProvider), isA<PairingRejected>());
    });
  });
}
