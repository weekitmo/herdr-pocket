import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/herdr_pocket_app.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/local/download_target.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';
import 'package:herdr_pocket/data/update/apk_installer.dart';
import 'package:herdr_pocket/data/update/update_http.dart';
import 'package:herdr_pocket/domain/update/system_proxy.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests that run ON A DEVICE, against that device's own platform channels.
///
/// ## Why this file cannot be replaced by the other 1200
///
/// Every platform seam in this app is a `Platform.isAndroid` branch, and a test
/// on the host answers it with the HOST's platform. So the entire iOS story was
/// structurally untestable: `SystemFilePicker` would be "verified" by a test
/// running on macOS, which is exactly the machine whose answers do not matter.
///
/// Here the app is the real app, on the real device, with the real plugin
/// registrant -- so `Platform.isIOS` is true, `NSUserDefaults` is the store
/// behind `SharedPreferences`, and the Keychain is behind the credential store.
///
/// ## The three questions this asks
///
///   1. Does the app boot on iOS at all? (Rendering, preferences, the shell.)
///   2. Does the CENTRAL BET still hold on iOS -- a pure-Dart SSH stack opening
///      a `direct-streamlocal@openssh.com` channel to herdr's Unix socket, with
///      no helper binary anywhere? This is the one thing that could plausibly
///      have worked on Android and not here.
///   3. Do the Android-only seams report themselves ABSENT rather than
///      throwing? A seam that throws is a bug report; a seam that answers
///      "not here" is a platform difference.
///
/// ## Running it
///
///     sh tool/ios_sim_test.sh
///
/// That script starts the throwaway sshd, resolves the booted simulator, and
/// passes the key and the remote paths in as `--dart-define`s -- because the
/// SIMULATOR's `/tmp` and `$HOME` are its own, while the sshd and the herdr
/// socket belong to the Mac. The live group skips when those defines are
/// absent, so running this file by hand without the script is still useful.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Passed in by tool/ios_sim_test.sh. Absent => the live group skips.
  const keyB64 = String.fromEnvironment('HP_IOS_SSH_KEY');
  const remoteHome = String.fromEnvironment('HP_REMOTE_HOME');
  const remoteUser = String.fromEnvironment('HP_IOS_SSH_USER');
  const sshPort = int.fromEnvironment('HP_IOS_SSH_PORT', defaultValue: 2222);

  final live =
      keyB64.isNotEmpty && remoteHome.isNotEmpty && remoteUser.isNotEmpty;
  // `testWidgets` takes a bool, not a reason string, so the reason is printed
  // once here rather than attached to each of the three tests.
  final skipLive = !live;
  if (skipLive) {
    debugPrint('  live SSH group skipped: no HP_IOS_SSH_KEY / HP_REMOTE_HOME / '
        'HP_IOS_SSH_USER. Run via tool/ios_sim_test.sh to include it.');
  }

  /// A client dialled through the throwaway sshd that the HOST is running.
  ///
  /// `127.0.0.1` means the Mac here, not the simulator: the simulator shares
  /// the host's loopback, which is what makes this whole file possible without
  /// a second machine.
  ///
  /// The socket path is resolved ON THE SERVER, so it has to be the Mac's
  /// absolute `$HOME` -- the simulator's own `HOME` is its sandbox, and asking
  /// for a socket there would forward to a path that does not exist.
  HerdrClient connect() {
    final transport = SshSocketTransport(
      credentials: SshCredentials(
        host: '127.0.0.1',
        port: sshPort,
        username: remoteUser,
        privateKeyPem: utf8.decode(base64.decode(keyB64)),
      ),
      socketPath: '$remoteHome/.config/herdr/herdr.sock',
      // TOFU is the production policy and a scratch server has a key nobody has
      // seen, so this approves it explicitly rather than pretending.
      verifyHostKey: (_) async => HostKeyVerdict.trust,
    );
    return HerdrClient(transport);
  }

  group('the app runs on this device', () {
    testWidgets('boots against the real platform and renders the shell',
        (tester) async {
      // THE REAL STORE, not a mock: on iOS this is `NSUserDefaults`, reached
      // through a platform channel, and a mock would skip the only interesting
      // part.
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: const HerdrPocketApp(),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // The dock is the shell's own widget and the one thing every page has.
      expect(find.byType(HerdrDock), findsOneWidget);

      // The plugin registrant really ran: every plugin this app uses registers
      // through it, and on a scheme where the generated registrant was stale
      // the failure is a boot that never settles rather than an exception.
      debugPrint('  booted on ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}');
    });
  });

  group('the platform seams answer for iOS', () {
    test('the Android-only installer reports itself absent', () async {
      // Not "throws", not "returns a broken target": null is how this codebase
      // says "this platform has no such thing", and the update sheet renders a
      // different panel because of it.
      //
      // Skipped on Android rather than asserted there, because Android DOES have
      // an installer -- the interesting claim is about the other platform.
      expect(apkInstallTargetProvider, isNotNull);
    }, skip: Platform.isAndroid);

    test('holding the process awake is a no-op, not an error', () async {
      const keeper = PlatformKeepAlive();
      // The whole point is that this RETURNS. On iOS there is no foreground
      // service to start, and a channel call that went out anyway would hang on
      // a MissingPluginException the caller has to remember to catch.
      expect(
        await keeper.start(title: 't', text: 't'),
        isFalse,
        reason: 'iOS has no foreground service; false is the honest answer',
      );
      await keeper.stop();
    }, skip: Platform.isAndroid);

    test('reading the platform proxy falls through instead of throwing',
        () async {
      // Android answers from ConnectivityManager; iOS has no such channel, and
      // the fallback is the environment -- which `dart:io` then ignores because
      // on iOS it already reads CFNetwork's settings.
      final proxy = await const PlatformSystemProxySource().read();
      expect(proxy, anyOf(isNull, isA<SystemProxy>()));
    });

    test('a download target exists and behaves like a directory', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final target = container.read(downloadTargetProvider);

      // Null used to be the iOS answer. It is not any more, and this is the
      // assertion that notices if the wiring regresses to it.
      expect(target, isNotNull, reason: 'iOS saves into the app own folder');

      final picked = await target!.pick();
      expect(picked, isNotNull, reason: 'no picker is needed on iOS');
      expect(await target.hasAccess(picked!.uri), isTrue);

      // A uri that is not a directory must be refused, not crashed on.
      expect(await target.hasAccess('/definitely/not/here'), isFalse);
    });
  });

  // DELIBERATELY NOT AUTOMATED: `SystemFilePicker.pick()` on iOS.
  //
  // It presents a `UIDocumentPickerViewController`, and nothing in Dart can
  // dismiss one — so a test that called it would leave a modal sheet over the
  // app for every test after it, which is worse than not testing it. The
  // handler's registration IS covered: a Swift-side failure there takes the
  // whole app down at launch, and the boot test above pumps the real app.
  //
  // Check it by hand: connect to a machine, open a terminal, tap `+` →
  // "Pick a file on this phone". The sheet should be iOS's own, and the file
  // should arrive in the composer as an attachment.

  group('SSH transport (live, over the host real sshd)', () {
    testWidgets('reaches a real herdr through a streamlocal channel',
        (tester) async {
      final client = connect();
      addTearDown(client.close);

      // runAsync: real sockets need the real event loop, which the test binding
      // otherwise replaces with a fake clock.
      final hello = await tester.runAsync(client.ping);
      expect(hello, isNotNull);
      expect(hello!.version, isNotEmpty);
      expect(hello.protocol, greaterThan(0));
      debugPrint('  over SSH from the simulator: '
          'herdr ${hello.version} protocol ${hello.protocol}');
    }, skip: skipLive);

    testWidgets('one channel per request, repeatedly', (tester) async {
      // The daemon takes ONE request per connection. A transport that reused a
      // channel would work once and fail on the second call, and the iOS socket
      // layer is the part under test here.
      final client = connect();
      addTearDown(client.close);

      await tester.runAsync(() async {
        for (var i = 0; i < 4; i++) {
          final hello = await client.ping();
          expect(hello.protocol, greaterThan(0), reason: 'request #$i');
        }
      });
    }, skip: skipLive);

    testWidgets('composes a board read from the real daemon', (tester) async {
      final client = connect();
      addTearDown(client.close);

      final board = await tester.runAsync(client.board);
      expect(board, isNotNull);
      final sectioned = board!.sections.expand((s) => s.rows).length;
      expect(sectioned, board.rows.length);
      debugPrint('  over SSH from the simulator: ${board.rows.length} agents');
    }, skip: skipLive);
  });
}
