import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/shell.dart';
import 'package:herdr_pocket/data/transport/shell_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/shell/shell_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CLOSING THE SHELL PAGE MUST NOT FREEZE THE APP.
///
/// Found on the phone, reported as "open a shell from the board, go back, and
/// the board will not take taps any more". Everything about it looked like a
/// broken touch layer: the page was drawn, the icons lit up under a finger, and
/// nothing responded. It was not the touch layer at all — the taps arrived, the
/// callbacks ran, the state changed, and then no frame was ever drawn again.
///
/// The cause is a write to a provider from `State.dispose`, which runs inside
/// the frame's unmount pass: `markNeedsBuild` there sets the build owner's
/// "a frame is already on its way" flag and then fails to ask for that frame
/// (see `lib/app/frame_phase.dart`), which stops EVERY later rebuild in the
/// process from scheduling one. Debug builds catch it as a Riverpod assertion;
/// release builds freeze silently.
///
/// So this file pins the two halves that were wrong: the hold is handed back,
/// and it is handed back without writing anything from inside the frame.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets('closing the shell page hands its hold back, and the app lives', (
    tester,
  ) async {
    final container = await _pumpHost(tester, prefs, _FakeRunner());

    // Open a terminal the way the board does, from a page that is watching the
    // hold set — the watcher is what makes the write from `dispose` reach a
    // widget, which is the half that breaks the frame pipeline.
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ShellPage), findsOneWidget);

    expect(
      container.read(keepAliveHoldersProvider),
      contains('shell'),
      reason: 'a live SSH session is reason enough to hold the process, even '
          'with no herdr connection at all',
    );

    // Back out of it.
    await tester.tap(find.byIcon(CupertinoIcons.back));
    await tester.pumpAndSettle();

    expect(find.byType(ShellPage), findsNothing);
    expect(
      tester.takeException(),
      isNull,
      reason: 'a provider write from inside the frame is either an assert '
          '(debug) or an app that never repaints again (release)',
    );
    expect(
      container.read(keepAliveHoldersProvider),
      isNot(contains('shell')),
      reason: 'a hold left behind keeps a foreground service running for a '
          'session nobody has',
    );

    // The app is still alive: a tap still reaches the screen.
    await tester.tap(find.text('bump'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);
  });
}

/// The host page: something to push the shell page from, and something that
/// visibly proves the app still rebuilds afterwards.
Future<ProviderContainer> _pumpHost(
  WidgetTester tester,
  SharedPreferences prefs,
  _FakeRunner runner,
) async {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentHostProvider.overrideWithValue(_profile),
      shellRunnerProvider.overrideWithValue((_) async => runner),
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
          home: _Host(),
        ),
      ),
    ),
  );
  return container;
}

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    // WATCHED, like `RootShell` watches it: the value itself is not drawn, and
    // that is the point — the widget rebuild IS the machinery under test.
    ref.watch(keepAliveHoldersProvider);

    return CupertinoPageScaffold(
      child: Column(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => const ShellPage(profile: _profile),
              ),
            ),
            child: const Text('open'),
          ),
          GestureDetector(
            onTap: () => setState(() => _taps += 1),
            child: const Text('bump'),
          ),
          Text('taps $_taps'),
        ],
      ),
    );
  }
}

class _FakeSession implements RemoteShellSession {
  final _output = StreamController<String>();

  @override
  Stream<String> get output => _output.stream;

  @override
  void sendBytes(List<int> bytes) {}

  @override
  void resize(int cols, int rows) {}

  @override
  Future<int?> get exitStatus async => null;

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }
}

class _FakeRunner implements RemoteShellRunner {
  @override
  Future<RemoteShellSession> open({
    required int cols,
    required int rows,
  }) async => _FakeSession();
}

/// The machine the shell is opened on. A file-level constant rather than a
/// parameter: the page reads it from the widget it is given, and nothing in
/// this file has an opinion about which machine it is.
const _profile = HostProfile(
  id: 'h1',
  label: 'Test box',
  username: 'me',
  host: '10.0.0.1',
);
