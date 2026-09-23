import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/ledger.dart';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/data/transcripts/transcript_locator.dart';
import 'package:herdr_pocket/domain/transcript/session_ledger.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/transcript/ledger_page.dart';

/// The ledger screen.
///
/// WHAT THIS FILE PROTECTS: that the screen says what it knows and says when it
/// does not. Every number on it comes from another program's private file, so
/// the failure modes are all of the same kind — a screen that looks complete
/// while being wrong. Three of them are pinned here: a tool that never returned
/// is not a fast success, a reading found by guessing says so, and a record we
/// could not read is a sentence rather than an empty list.
void main() {
  Widget page({
    LocatedTranscript? located,
    bool reachable = true,
    String agentId = 'pi',
  }) => ProviderScope(
    overrides: [
      ledgerLoaderProvider.overrideWithValue(
        reachable
            ? ({required agentId, required cwd, pid}) async =>
                  located ?? FoundTranscript(
                    location: const TranscriptLocation(
                      path: '/home/u/.pi/agent/sessions/--work--/s.jsonl',
                      source: TranscriptSource.openFile,
                    ),
                    parse: ParsedTranscript(_session()),
                    truncated: false,
                  )
            : null,
      ),
    ],
    child: HerdrTheme(
      colors: HerdrColors.dark,
      child: CupertinoApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: LedgerPage(agentId: agentId, cwd: '/work/app'),
      ),
    ),
  );

  testWidgets('the summary counts the session', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('pi-2.5'), findsOneWidget); // the model
    expect(find.text('Turns'), findsOneWidget);
    // One failure and one open call, both named rather than folded into the
    // count: "3 calls" that hides a failure is the number nobody needed.
    expect(find.textContaining('3 calls'), findsOneWidget);
    expect(find.textContaining('1 failed'), findsOneWidget);
    expect(find.textContaining('1 with no result'), findsOneWidget);
  });

  testWidgets('every tool gets a row with its own median and busy time', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // Each name appears twice: once in the tool table, once on the call itself.
    expect(find.text('bash'), findsNWidgets(2));
    expect(find.text('read'), findsNWidgets(2));
    // 4s and 6s: the median is one of the two, never their average — so the
    // assertion that matters is that the average is nowhere on the screen.
    expect(find.text('4.0s'), findsWidgets);
    expect(find.text('5.0s'), findsNothing);
    // And the busy total is the sum, not the median.
    expect(find.text('10s'), findsWidgets);
  });

  testWidgets('a turn shows its tokens on the turn, not on a tool', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // The per-turn line: the only place a token count is allowed to appear.
    expect(find.textContaining('1.2k'), findsWidgets);
    expect(find.textContaining('340'), findsWidgets);
  });

  testWidgets('a long answer can be read in full', (tester) async {
    // The first version capped every message at six lines with an ellipsis and
    // no way past it. On a real dsh turn that cut the answer off after its
    // first heading, which reads as "the agent said nothing".
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final long = List.generate(40, (i) => 'line ${i + 1} of the answer').join('\n');
    await tester.pumpWidget(
      page(
        located: FoundTranscript(
          location: const TranscriptLocation(
            path: '/home/u/s.jsonl',
            source: TranscriptSource.openFile,
          ),
          parse: ParsedTranscript(
            LedgerSession(
              agentId: 'dsh',
              turns: [LedgerTurn(index: 1, items: [LedgerText(long)])],
            ),
          ),
          truncated: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The string is in the widget either way — what changes is the cap on how
    // much of it is drawn, so that is what the assertions read.
    Text body() => tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('line 1 of the answer'),
      ),
    );

    expect(body().maxLines, 6);

    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();

    expect(body().maxLines, isNull);
  });

  testWidgets('a session with no turns says so instead of showing nothing', (tester) async {
    await tester.pumpWidget(
      page(
        located: const FoundTranscript(
          location: TranscriptLocation(
            path: '/home/u/.dsh/sessions/--work--/x/session.v3.jsonl.zstd',
            source: TranscriptSource.byDirectory,
          ),
          parse: ParsedTranscript(
            LedgerSession(agentId: 'dsh', cwd: '/work/app'),
          ),
          truncated: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This session has no turns yet'), findsOneWidget);
  });

  testWidgets('a failed call is marked as failed', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.exclamationmark_triangle), findsOneWidget);
  });

  testWidgets('thinking is collapsed to its label and its size', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('Thinking'), findsOneWidget);
    expect(find.textContaining('chars'), findsOneWidget);
    // Collapsed means the body is not on screen yet.
    expect(find.text('I should read the file first'), findsNothing);

    await tester.tap(find.text('Thinking'));
    await tester.pumpAndSettle();
    expect(find.text('I should read the file first'), findsOneWidget);
  });

  testWidgets('a tool call expands to its arguments and output', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('bash').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('"command":"ls"'), findsWidgets);
    expect(find.textContaining('file-a'), findsWidgets);
  });

  testWidgets('a reading found by guessing says so', (tester) async {
    await tester.pumpWidget(
      page(
        located: FoundTranscript(
          location: const TranscriptLocation(
            path: '/home/u/.pi/agent/sessions/--work--/newest.jsonl',
            source: TranscriptSource.byDirectory,
          ),
          parse: ParsedTranscript(_session()),
          truncated: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Newest session in this directory'), findsOneWidget);
    expect(find.textContaining('Only the end of the file was read'), findsOneWidget);
  });

  testWidgets('an open call is labelled as having no result', (tester) async {
    // A tall surface: the second turn is below the fold on a phone-sized one,
    // and a list that has not built a row cannot be asserted about.
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('no result'), findsOneWidget);
  });

  testWidgets('an unreadable agent is a sentence, not an empty ledger', (tester) async {
    await tester.pumpWidget(
      page(located: const UnsupportedAgent('claude', ['pi', 'codex'])),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("This agent's session record cannot be read"),
      findsOneWidget,
    );
  });

  testWidgets('a read that went wrong is not reported as an absent session', (tester) async {
    // The two sentences answer different questions — "this machine has no
    // record" versus "we could not read the record" — and the page used to
    // collapse them, which is how a parser crash reached a phone as an empty
    // directory.
    await tester.pumpWidget(page(located: const UnreadableTranscript()));
    await tester.pumpAndSettle();

    expect(
      find.text("This agent's session record cannot be read"),
      findsOneWidget,
    );
  });

  testWidgets('a machine with no session says so', (tester) async {
    await tester.pumpWidget(page(located: const NoTranscript()));
    await tester.pumpAndSettle();

    expect(
      find.text('No session record found for this directory'),
      findsOneWidget,
    );
  });

  testWidgets('the local-socket transport says it cannot read files', (tester) async {
    await tester.pumpWidget(page(reachable: false));
    await tester.pumpAndSettle();

    expect(
      find.text("The machine's files are not reachable now"),
      findsOneWidget,
    );
  });

  testWidgets('a transcript that will not parse is not shown as a session', (tester) async {
    await tester.pumpWidget(
      page(
        located: const FoundTranscript(
          location: TranscriptLocation(
            path: '/home/u/.pi/agent/sessions/--work--/x.jsonl',
            source: TranscriptSource.openFile,
          ),
          parse: UnusableTranscript('no pi message lines'),
          truncated: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("This agent's session record cannot be read"),
      findsOneWidget,
    );
  });
}

/// A session with one of everything that has a rule attached to it: two tools
/// with different speeds, one failure, one call that never came back, a
/// thinking block, and a turn that reports tokens.
LedgerSession _session() => LedgerSession(
  agentId: 'pi',
  model: 'pi-2.5',
  cwd: '/work/app',
  turns: [
    LedgerTurn(
      index: 1,
      prompt: 'run the tests',
      startedAt: DateTime.utc(2026, 9, 23, 10, 11),
      usage: const TokenUsage(input: 1200, output: 340, cacheRead: 26000),
      items: const [
        LedgerThinking('I should read the file first'),
        LedgerToolCall(
          id: 'c1',
          name: 'bash',
          arguments: '{"command":"ls"}',
          duration: Duration(seconds: 4),
          isError: false,
          result: 'file-a\nfile-b',
        ),
        LedgerToolCall(
          id: 'c2',
          name: 'read',
          arguments: '{"path":"a.dart"}',
          duration: Duration(seconds: 6),
          isError: true,
          result: 'ENOENT',
        ),
      ],
    ),
    LedgerTurn(
      index: 2,
      prompt: 'now fix it',
      startedAt: DateTime.utc(2026, 9, 23, 10, 12),
      items: const [
        LedgerToolCall(id: 'c3', name: 'bash', arguments: '{"command":"sleep 999"}'),
      ],
    ),
  ],
);
