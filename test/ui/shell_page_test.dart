import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/shell.dart';
import 'package:herdr_pocket/data/transport/shell_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/shell/shell_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The SSH terminal page, driven through a scripted session.
///
/// WHY THIS FILE IS WORTH ITS WEIGHT. Every interesting rule on this page is
/// INVISIBLE when it is wrong:
///
///   * a key that sends `\n` instead of `\r` looks fine until a TUI ignores the
///     return key;
///   * a grid opened at the wrong size wraps every line in the wrong place, and
///     the terminal still scrolls;
///   * an armed `Ctrl` that survives a keypress fires on the NEXT key, which
///     reads as the terminal doing something random;
///   * a session that ends without saying so leaves the user typing into a
///     terminal that has been dead for a minute.
///
/// None of those throws, logs, or looks wrong in a screenshot. So they are
/// pinned here, against the real page, with a fake session instead of an SSH
/// server — which is exactly why `shellRunnerProvider` exists.
void main() {
  const profile = HostProfile(
    id: 'h1',
    label: 'Test box',
    username: 'me',
    host: '10.0.0.1',
  );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpShell(
    WidgetTester tester,
    _FakeRunner runner, {
    Size size = const Size(360 * 3, 800 * 3),
    double pixelRatio = 3,
  }) async {
    // A PHONE'S WIDTH, not the 800-point default: the size this page asks the
    // far end for is derived from the box, so a test at the wrong width is
    // testing a geometry no user has.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = pixelRatio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          shellRunnerProvider.overrideWithValue((_) async => runner),
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
            home: ShellPage(profile: profile),
          ),
        ),
      ),
    );
    // NOT pumpAndSettle: the opening state shows a `CupertinoActivityIndicator`,
    // which never stops animating, so settling would time out at exactly the
    // moment the test is about.
    await tester.pump(); // first frame, which measures the grid
    await tester.pump(); // the post-frame callback opens the session
    await tester.pump(); // the session lands and the widget rebuilds
  }

  /// Pumps the few frames an async tail needs, without `pumpAndSettle` — the
  /// opening state's activity indicator never stops animating, so settling
  /// times out exactly when the test is about that state.
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the pty is opened once, at the size the box asks for', (
    tester,
  ) async {
    final runner = _FakeRunner();
    await pumpShell(tester, runner);

    expect(runner.opened, hasLength(1));
    final asked = runner.opened.single;
    // A plausible grid for a 360-point-wide phone at 12pt: wide enough to be a
    // terminal, narrow enough that the measurement is not obviously wrong.
    expect(asked.cols, greaterThan(30));
    expect(asked.cols, lessThan(120));
    expect(asked.rows, greaterThan(10));
  });

  testWidgets('a wider box resizes the session instead of reopening it', (
    tester,
  ) async {
    final runner = _FakeRunner();
    await pumpShell(tester, runner);
    final first = runner.opened.single;
    final session = runner.sessions.single;

    // Rotate: same session, wider grid.
    tester.view.physicalSize = const Size(800 * 3, 360 * 3);
    await tester.pump();
    expect(
      session.resizes,
      isEmpty,
      reason: 'the window-change is debounced: the keyboard animates, and a '
          'SIGWINCH per animation frame is a full redraw per animation frame',
    );

    await tester.pump(const Duration(milliseconds: 250));
    expect(session.resizes, hasLength(1));
    expect(
      session.resizes.single.cols,
      greaterThan(first.cols),
      reason: 'a landscape phone is wider than a portrait one',
    );
    expect(
      runner.opened,
      hasLength(1),
      reason: 'a resize must never open a second connection',
    );
  });

  testWidgets('the keys send the bytes they name, and nothing else', (
    tester,
  ) async {
    final runner = _FakeRunner();
    await pumpShell(tester, runner);
    final session = runner.sessions.single;

    await tester.tap(find.text('esc'));
    await tester.pump();
    expect(session.sent, [
      [0x1B],
    ]);

    // ENTER IS CARRIAGE RETURN. A line feed works in a canonical-mode shell and
    // is ignored by every TUI in raw mode.
    session.sent.clear();
    await tester.tap(find.text('enter'));
    await tester.pump();
    expect(session.sent, [
      [0x0D],
    ]);

    // And a ready-made control code is one byte, not the letters `C-c`.
    session.sent.clear();
    await tester.tap(find.text('C-c'));
    await tester.pump();
    expect(session.sent, [
      [0x03],
    ]);
  });

  testWidgets('an armed modifier is consumed by the next key', (tester) async {
    final runner = _FakeRunner();
    // A WIDE box, because the strip is a lazy ListView: at a phone's width the
    // first four caps fill the screen and `Ctrl` is never built, so a finder
    // for it finds nothing. That is the strip working as designed — it scrolls
    // — not a bug, and a test that has to scroll to reach the control it is
    // about is testing the scroller.
    await pumpShell(tester, runner, size: const Size(900 * 3, 800 * 3));
    final session = runner.sessions.single;

    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(
      session.sent,
      isEmpty,
      reason: 'arming a modifier sends nothing by itself',
    );

    await tester.tap(find.text('esc'));
    await tester.pump();

    session.sent.clear();
    // The modifier was armed and the previous key could not use it. It must NOT
    // still be armed here: a Ctrl that survives a keypress fires on the key
    // after that, which is the terminal doing something the user did not ask
    // for.
    await tester.tap(find.text('C-c'));
    await tester.pump();
    expect(session.sent, [
      [0x03],
    ]);
  });

  testWidgets('a session that ends says so, and offers a way back', (
    tester,
  ) async {
    final runner = _FakeRunner()..exitCodes.add(3);
    await pumpShell(tester, runner);
    expect(find.text('Open again'), findsNothing);

    await runner.sessions.single.end();
    await flush(tester);

    expect(find.text('The session ended'), findsOneWidget);
    expect(find.text('The process exited with code 3.'), findsOneWidget);

    // The key strip goes away with the session: a keyboard that types into a
    // dead pty is worse than no keyboard.
    expect(find.text('esc'), findsNothing);

    await tester.tap(find.text('Open again'));
    await flush(tester);
    expect(runner.opened, hasLength(2), reason: 'the button opens a new one');
  });

  testWidgets('a session that ends leaves its output on screen', (tester) async {
    final runner = _FakeRunner();
    await pumpShell(tester, runner);
    final session = runner.sessions.single;

    session.emit('zsh: command not found: tmux\r\n');
    await flush(tester);
    await session.end();
    await flush(tester);

    expect(find.text('The session ended'), findsOneWidget);

    // THE OUTPUT IS STILL THERE. The first version replaced the whole surface
    // with a panel on exit, which threw away the only line that says what went
    // wrong — a real device showed "exited with code 127" over a blank screen
    // and the sentence the user needed was `command not found: tmux`.
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<TerminalPainter>()
        .first;
    expect(painter.terminal.buffer.getText(), contains('command not found'));
  });

  testWidgets('a session that exits without a code says that instead of zero', (
    tester,
  ) async {
    // `exitStatus` null means a signal, or an sshd that never sent a status.
    // Rendering that as "exited with code 0" would be a lie about success.
    final runner = _FakeRunner();
    await pumpShell(tester, runner);
    await runner.sessions.single.end();
    await flush(tester);

    expect(
      find.text('The remote side did not report an exit code.'),
      findsOneWidget,
    );
  });

  testWidgets('a dial that fails shows the reason and a way to retry', (
    tester,
  ) async {
    final runner = _FakeRunner()..failWith = Exception('no route to host');
    await pumpShell(tester, runner);

    expect(find.text('Could not open a terminal'), findsOneWidget);
    expect(find.textContaining('no route to host'), findsOneWidget);

    await tester.tap(find.text('Open again'));
    await flush(tester);
    expect(runner.opened, hasLength(2));
  });
}

/// A session that records what it was asked to do and can be ended on cue.
class _FakeSession implements RemoteShellSession {
  final sent = <List<int>>[];
  final resizes = <({int cols, int rows})>[];
  final _output = StreamController<String>();
  int? exitCode;
  bool closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  void sendBytes(List<int> bytes) => sent.add(List<int>.of(bytes));

  @override
  void resize(int cols, int rows) => resizes.add((cols: cols, rows: rows));

  @override
  Future<int?> get exitStatus async => exitCode;

  @override
  Future<void> close() async {
    closed = true;
    if (!_output.isClosed) await _output.close();
  }

  /// Something the remote process printed.
  void emit(String text) => _output.add(text);

  /// The remote process finished.
  Future<void> end() async {
    if (!_output.isClosed) await _output.close();
  }
}

class _FakeRunner implements RemoteShellRunner {
  final opened = <({int cols, int rows})>[];
  final sessions = <_FakeSession>[];

  /// One code per session, consumed in order.
  final exitCodes = <int?>[];

  /// When set, [open] throws it instead of returning a session.
  Exception? failWith;

  @override
  Future<RemoteShellSession> open({
    required int cols,
    required int rows,
  }) async {
    opened.add((cols: cols, rows: rows));
    final failure = failWith;
    if (failure != null) throw failure;

    final session = _FakeSession()
      ..exitCode = exitCodes.isEmpty ? null : exitCodes.removeAt(0);
    sessions.add(session);
    return session;
  }
}
