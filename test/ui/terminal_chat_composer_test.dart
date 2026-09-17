import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/remote_capabilities.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/domain/terminal/submission.dart';
import 'package:herdr_pocket/ui/pages/terminal/chat_composer.dart';
import 'package:herdr_pocket/ui/pages/terminal/menu_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_harness.dart';

/// The chat window: what it sends, when it sends it, and what its menus list.
///
/// WHY THIS IS WORTH A PAGE-LEVEL TEST. The whole feature is a claim about the
/// WIRE — that a paragraph costs ONE write instead of one per character — and
/// none of the units below it can see that: `Submitter` can be tested for its
/// paste-then-Enter rhythm, but only the page can be tested for "and typing
/// really did not send anything". The bug this suite would have caught on its
/// first run is exactly that kind: the draft listener skipped its work whenever
/// no menu was open, so the slash that OPENS the skills menu was the one
/// keystroke it never saw.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  /// Phone geometry, because this is the one part of the app that stacks three
  /// full-width strips and a floating card at the bottom of the screen.
  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<FakeTerminalDaemon> pump(WidgetTester tester) =>
      pumpTerminalPage(tester, prefs: prefs);

  /// Opens the chat window from the key bar.
  Future<void> openComposer(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Composer'));
    await tester.pumpAndSettle();
    expect(find.byKey(composerFieldKey), findsOneWidget);
  }

  /// Types into the chat field, the way the phone's keyboard does.
  Future<void> write(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(composerFieldKey), text);
    await tester.pumpAndSettle();
  }

  group('sending', () {
    testWidgets('typing into the composer sends NOTHING', (tester) async {
      // The point of the whole feature. Every character typed here would be a
      // round trip in direct mode, and on the link this was built for, most of
      // them would be lost.
      final daemon = await pump(tester);
      await openComposer(tester);

      await write(tester, 'please run the tests and tell me why the last one');

      expect(
        daemon.inputCommands(),
        isEmpty,
        reason: 'nothing reaches the pane until the user presses send',
      );
    });

    testWidgets('send puts one paste and then one Enter on the wire',
        (tester) async {
      final daemon = await pump(tester);
      await openComposer(tester);
      await write(tester, 'hello there');

      await tester.tap(find.byKey(composerSendKey));
      await tester.pump();

      final afterPaste = daemon.inputCommands();
      expect(afterPaste, hasLength(1), reason: 'one message, one write');
      expect(afterPaste.single['text'], contains('hello there'));

      // The Enter is deliberately late: several TUIs treat a carriage return
      // that lands in the same read as a paste as part of the paste, and the
      // message then sits unsent in the box.
      await tester.pump(kSubmitSettle + const Duration(milliseconds: 20));
      final all = daemon.inputCommands();
      expect(all, hasLength(2));
      expect(all.last['text'], '\r');
    });

    testWidgets('a paragraph is one bracketed paste — and follows the pane',
        (tester) async {
      // THE MODE IS THE PANE'S, read at send time. A TUI turns bracketed paste on
      // (`ESC[?2004h` in its own output) precisely so a pasted paragraph lands in
      // its input box instead of submitting line by line; a shell prompt does not,
      // and there the newlines have to become returns. Both are the pane's
      // decision, so both are tested.
      final daemon = await pump(tester);
      await openComposer(tester);
      await write(tester, 'first line\nsecond line');

      await tester.tap(find.byKey(composerSendKey));
      await tester.pump();
      final unbracketed = daemon.inputCommands().last['text']! as String;
      expect(
        unbracketed,
        'first line\rsecond line',
        reason: 'with the mode off, a paste is lines of input',
      );

      // The pane turns it on, the way every TUI does.
      daemon.emitFrame(data: '\x1b[?2004h', width: 65, height: 46);
      await tester.pump();
      await write(tester, 'one\ntwo');
      await tester.tap(find.byKey(composerSendKey));
      await tester.pump();

      final bracketed = daemon.inputCommands().last['text']! as String;
      expect(bracketed, startsWith('\x1b[200~'));
      expect(bracketed, endsWith('\x1b[201~'));
      expect(bracketed, contains('one\ntwo'));
    });

    testWidgets('an empty composer has nothing to send', (tester) async {
      final daemon = await pump(tester);
      await openComposer(tester);

      await tester.tap(find.byKey(composerSendKey));
      await tester.pump();

      expect(daemon.inputCommands(), isEmpty);
    });

    testWidgets('the field is cleared, and the message is not sent twice',
        (tester) async {
      final daemon = await pump(tester);
      await openComposer(tester);
      await write(tester, 'once');

      await tester.tap(find.byKey(composerSendKey));
      await tester.pump();
      await tester.tap(find.byKey(composerSendKey));
      await tester.pump();

      expect(daemon.inputCommands().where((m) => m['text'] != '\r'), hasLength(1));
    });
  });

  group('the two surfaces are exclusive', () {
    testWidgets('closing the composer gives the keyboard back to the pane',
        (tester) async {
      // Direct mode is not gone: it is what the key bar has always been for, and
      // a chat window that swallowed every keystroke forever would be a
      // regression in the one thing this screen already did well.
      final daemon = await pump(tester);
      await openComposer(tester);
      await tester.tap(find.bySemanticsLabel('Composer'));
      await tester.pumpAndSettle();

      expect(find.byKey(composerFieldKey), findsNothing);
      expect(
        daemon.inputCommands(),
        isEmpty,
        reason: 'closing the composer must not send anything either',
      );
    });
  });

  group('the setting', () {
    testWidgets('with it off the button is gone, not dead', (tester) async {
      // An affordance that is permanently unavailable is a worse answer than
      // one that is absent — and on a 2018 phone the strip costs a real part of
      // the screen, which is the whole reason this switch exists.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.composerEnabled': false,
      });
      prefs = await SharedPreferences.getInstance();
      await pump(tester);

      expect(
        find.bySemanticsLabel('Composer'),
        findsNothing,
        reason: 'the key bar should not offer what the setting turned off',
      );
      expect(find.text('esc'), findsOneWidget, reason: 'the key bar itself stays');
    });

    testWidgets('turning it off closes a composer that is already open',
        (tester) async {
      // Otherwise the strip stays on screen with the only button that could
      // close it removed by the same setting.
      await pump(tester);
      await openComposer(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(composerFieldKey)),
      );
      await container
          .read(settingsProvider.notifier)
          .setComposerEnabled(enabled: false);
      await tester.pumpAndSettle();

      expect(find.byKey(composerFieldKey), findsNothing);
    });
  });

  group('on a phone', () {
    // PHONE GEOMETRY, because this is the one part of the app that stacks three
    // full-width strips at the bottom of the screen. A layout that overflows
    // throws inside a widget test, so these are regression tests for a class of
    // bug that is otherwise only visible on a device: the terminal surface, the
    // key bar, the candidate list and the composer are all trying to be on the
    // same 800 points.
    testWidgets('the composer fits under the key bar', (tester) async {
      usePhone(tester);
      await pump(tester);
      await openComposer(tester);

      await write(tester, 'a line long enough to wrap onto a second line here');
      expect(tester.takeException(), isNull);
      expect(find.byKey(composerSendKey), findsOneWidget);
      expect(find.text('esc'), findsOneWidget, reason: 'the key bar is still there');
    });

    testWidgets('the card floats: it does not touch the edges', (tester) async {
      // The reference composer is a panel with air around it, and the margins
      // are the whole of that look — a full-width strip reads as one more row of
      // chrome, which is what this is deliberately not.
      usePhone(tester);
      await pump(tester);
      await openComposer(tester);

      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final card = tester.getRect(find.byKey(composerFieldKey));
      expect(card.left, greaterThan(0));
      expect(
        card.right,
        lessThan(width),
        reason: 'the field is inside a card that has margins of its own',
      );
    });

    testWidgets('a long message stops growing instead of eating the screen',
        (tester) async {
      usePhone(tester);
      await pump(tester);
      await openComposer(tester);

      await write(tester, List.filled(30, 'line').join('\n'));
      expect(tester.takeException(), isNull);

      final field = tester.getSize(find.byKey(composerFieldKey));
      expect(
        field.height,
        lessThan(200),
        reason: 'the field caps at five lines; a terminal behind it has to stay usable',
      );
    });

    testWidgets('the list, the field and the key bar coexist', (tester) async {
      usePhone(tester);
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) =>
            '${RemoteCapabilities.homeMarker}\t/home/u\n'
            '/home/u/.claude/skills/a/SKILL.md\tOne\n'
            '/home/u/.claude/skills/b/SKILL.md\tTwo\n'
            '${remoteExitMarker}0';
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);
      await write(tester, '/');

      expect(tester.takeException(), isNull);
      expect(find.byKey(composerMenuKey), findsOneWidget);
      expect(find.byKey(composerFieldKey), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(composerMenuKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(composerFieldKey)).dy),
        reason: 'the list belongs above the field it filters',
      );
    });

    testWidgets('the keyboard does not push the composer off the screen',
        (tester) async {
      // The inset is the whole reason this screen had a bug once: the terminal
      // surface shrinks, and everything pinned to the bottom has to still fit.
      usePhone(tester);
      await pump(tester);
      await openComposer(tester);

      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final send = tester.getRect(find.byKey(composerSendKey));
      expect(
        send.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height / tester.view.devicePixelRatio),
      );
    });
  });

  group('the menus', () {
    /// A machine with one skill, one command file and one MCP server.
    String probeReply() {
      final lines = StringBuffer()
        ..writeln('${RemoteCapabilities.homeMarker}\t/home/u')
        ..writeln('/home/u/.claude/skills/code-review/SKILL.md\tReview the changes')
        ..write('\u0001HERDR-FILE\u0001/home/u/proj/.mcp.json\n')
        ..write('{"mcpServers":{"vision":{"command":"uv"}}}\n')
        ..write('${remoteExitMarker}0');
      return lines.toString();
    }

    testWidgets('a slash opens the skills, with the workspace as the source',
        (tester) async {
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/');

      expect(find.byKey(composerMenuKey), findsOneWidget);
      expect(find.text('code-review'), findsOneWidget);
      expect(
        find.text('Review the changes'),
        findsOneWidget,
        reason: "a skill's own description is the only thing that says what it does",
      );
      // One round trip, however many characters follow.
      final reads = daemon.shellCommands.length;
      await write(tester, '/cod');
      expect(daemon.shellCommands.length, reads);
    });

    testWidgets('picking a skill types the slash command', (tester) async {
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/cod');
      await tester.tap(find.text('code-review'));
      await tester.pumpAndSettle();

      final field = tester.widget<CupertinoTextField>(
        find.byKey(composerFieldKey),
      );
      expect(
        field.controller!.text,
        '/code-review ',
        reason: 'the pick is a text the agent understands, not a chip',
      );
      expect(
        find.byKey(composerMenuKey),
        findsNothing,
        reason: 'the trailing space ends the token, which closes the menu',
      );
    });

    testWidgets('the same menu lists the MCP servers the workspace declares',
        (tester) async {
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/vis');
      expect(find.text('vision'), findsOneWidget);
      expect(find.text('uv'), findsOneWidget);
    });

    testWidgets('an at-sign lists the files and folders to mention',
        (tester) async {
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => _fileListing(['lib/main.dart', 'lib/app.dart']);
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '@lib');

      expect(find.byKey(composerMenuKey), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(
        find.text('lib'),
        findsWidgets,
        reason: 'the directory is the row detail, and two rows share one',
      );

      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();
      final field = tester.widget<CupertinoTextField>(find.byKey(composerFieldKey));
      expect(field.controller!.text, '@lib/main.dart ');
    });

    testWidgets('a plain shell gets files, not skills', (tester) async {
      // The pane this was first tried on: a shell in a repo. `pane.list` leaves
      // `agent` empty for it, and `/` there is a path separator — so a slash
      // must NOT open a menu, and the `…` button has to offer the one thing a
      // shell can use, which is a path.
      // One scripted machine, two answers: the `@` menu wants a file listing
      // and the `/` menu wants the capability probe.
      final daemon = FakeTerminalDaemon(paneRows: 46, agent: null)
        ..onCommand = (command) => command.contains('ls-files')
            ? _fileListing(['lib/main.dart', 'lib/app.dart'])
            : probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/code');
      expect(
        find.byKey(composerMenuKey),
        findsNothing,
        reason: 'a shell has no skills to offer',
      );

      // The button names what it will open: a shell has files, not skills.
      expect(
        find.bySemanticsLabel('files'),
        findsOneWidget,
        reason: 'the … button must offer the workspace files on a shell pane',
      );

      // Empty again, so what the pick produces is the pick's own doing.
      await write(tester, '');
      await tester.tap(find.byKey(composerCommandsKey));
      await tester.pumpAndSettle();

      expect(find.byKey(composerMenuKey), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();
      final field = tester.widget<CupertinoTextField>(
        find.byKey(composerFieldKey),
      );
      expect(
        field.controller!.text,
        'lib/main.dart ',
        reason: 'a shell resolves no @mention, so it gets the bare path',
      );
    });

    testWidgets('a path typed into an agent pane does not open the menu either',
        (tester) async {
      // `/usr/local` is a path in anybody's language, and this used to pop the
      // skills list over it.
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, 'look at /usr/local');
      expect(find.byKey(composerMenuKey), findsNothing);
    });

    testWidgets('a machine that has nothing says so', (tester) async {
      // An empty list and "I could not look" are different answers, and this is
      // the one that is a FACT about the machine. The other one is below.
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => '${RemoteCapabilities.homeMarker}\t/home/u\n'
            '${remoteExitMarker}0';
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/');

      expect(find.byKey(composerMenuKey), findsOneWidget);
      expect(find.text('No skills or MCP servers found on this machine.'), findsOneWidget);
    });

    testWidgets('a machine that could not be read says THAT instead',
        (tester) async {
      // No sentinel: the reply is a prefix, and a prefix of a capability list
      // shown as a complete one is the menu lying about the machine.
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => 'not a reply at all';
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/');

      expect(find.byKey(composerMenuKey), findsOneWidget);
      expect(find.textContaining('Could not read it:'), findsOneWidget);
    });

    testWidgets('the empty state is as wide as the list', (tester) async {
      // A Column hands its children loose cross-axis constraints, so a panel
      // whose child is one short sentence shrink-wraps to the sentence — and its
      // own background and hairline come in with it. The two states of one panel
      // have to be the same width.
      usePhone(tester);
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await write(tester, '/zzzznomatch');

      expect(find.byKey(composerMenuKey), findsOneWidget);
      final screen =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(
        tester.getSize(find.byKey(composerMenuKey)).width,
        screen,
        reason: 'the panel is full width whether or not it has rows in it',
      );
      expect(find.text('Nothing matches.'), findsOneWidget);
    });

    testWidgets("the field says what it is for, in the app's language",
        (tester) async {
      await pump(tester);
      await openComposer(tester);
      expect(find.text('Type here'), findsOneWidget);
    });

    testWidgets('the button opens the same menu a slash would', (tester) async {
      final daemon = FakeTerminalDaemon(paneRows: 46)
        ..onCommand = (command) => probeReply();
      await pumpTerminalPage(tester, prefs: prefs, daemon: daemon);
      await openComposer(tester);

      await tester.tap(find.byKey(composerCommandsKey));
      await tester.pumpAndSettle();

      expect(find.byKey(composerMenuKey), findsOneWidget);
      final field = tester.widget<CupertinoTextField>(find.byKey(composerFieldKey));
      expect(field.controller!.text, '/');
    });
  });
}

/// A file listing the way the shell command answers one.
String _fileListing(List<String> paths) =>
    '${paths.map((p) => p).join('\n')}${remoteExitMarker}0';
