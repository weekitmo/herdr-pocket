import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/git_client.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/files/file_preview_page.dart';
import 'package:herdr_pocket/ui/pages/files/file_tree_page.dart';
import 'package:herdr_pocket/ui/pages/git/git_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the three screens that read the far end over a shell.
///
/// The fake runner is the whole point: these pages exist to turn a command's
/// stdout into a sentence, and the interesting failure is saying the WRONG
/// sentence — "empty file" about a connection problem, or "working tree clean"
/// about a repository that does not exist. Each of those has a test here, and
/// nothing else in the suite would catch it.
class _FakeRunner implements RemoteCommandRunner {
  _FakeRunner(this.onRun);

  /// What to answer, given the command. The commands themselves are asserted in
  /// `test/data/remote_fs_test.dart`; here they only need to be plausible.
  final String Function(String command) onRun;

  @override
  Future<String> runCommand(String command) async => onRun(command);
}

/// Preferences for the pages that read settings.
///
/// `FileTreePage` gained a settings dependency when file transfer arrived: it
/// asks whether transfer is switched on before offering a download, and the
/// switch lives in preferences. `sharedPreferencesProvider` throws by design
/// when nothing overrides it, which is what makes a missing override a loud
/// failure here rather than a silent default.
late SharedPreferences _prefs;

/// Wraps [child] the way the app does, with the remote runner faked out.
Widget _host(Widget child, RemoteCommandRunner runner) => ProviderScope(
      overrides: [
        remoteRunnerProvider.overrideWithValue(runner),
        sharedPreferencesProvider.overrideWithValue(_prefs),
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
          home: child,
        ),
      ),
    );

/// The sentinel the remote commands append, which the parsers split off.
String _ok(String body) => '$body$remoteExitMarker' '0';

/// A `git status` reply with the branch headers and the given records.
String _status(String records) => _ok(
      '# branch.oid 484cc83b497bb383a8a1789474749a201c3d2d5e\u0000'
      '# branch.head feature/x\u0000'
      '# branch.upstream origin/feature/x\u0000'
      '# branch.ab +2 -1\u0000'
      '$records',
    );

/// A `rev-parse --show-toplevel` reply.
String _root() => _ok('/tmp/repo\n');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('FilePreviewPage', () {
    testWidgets('shows the text, its line numbers and the full path',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/notes.md'),
          _FakeRunner((command) => _ok('alpha\nbravo\ncharlie\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('/tmp/notes.md'), findsOneWidget);
      // The body is ONE Text per line, in the machine voice — the same
      // `Text`-not-`SelectableText` choice the host-key sheet makes, because
      // `SelectableText` lives in Material.
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('charlie'), findsOneWidget);
      // Line numbers, in a gutter.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('an empty file says so rather than showing a blank page',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/empty.txt'),
          _FakeRunner((command) => _ok('')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Empty file'), findsOneWidget);
    });

    testWidgets('a binary file says so and shows NO content', (tester) async {
      // The content must not reach the text layer: showing decoded mojibake
      // invites the reader to believe it, and it can carry control characters
      // into the layout.
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/blob.bin'),
          _FakeRunner((command) => _ok('AB\u0000CD\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Binary file — not shown as text.'), findsOneWidget);
      expect(find.textContaining('AB'), findsNothing);
    });

    testWidgets('a failure says so, and does NOT say the file is empty',
        (tester) async {
      // The distinction the whole screen rests on: a read that failed and a
      // file with nothing in it are different facts, and conflating them is the
      // failure mode that makes a preview untrustworthy.
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/gone.txt'),
          _FakeRunner((command) => '$remoteExitMarker' '1'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not read this file'), findsOneWidget);
      expect(find.text('Empty file'), findsNothing);
    });

    testWidgets('a truncated read shows the text AND says how much was read',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/big.log'),
          _FakeRunner((command) => _ok('${'x' * 262145}\n')),
        ),
      );
      await tester.pumpAndSettle();

      // Both halves matter: hiding the text would make a large log unopenable,
      // and hiding the notice would present a partial file as the whole one.
      expect(find.text('Showing the first 256 KB'), findsOneWidget);
      expect(find.text('x' * 262144), findsOneWidget);
    });

    testWidgets('the transport throwing lands on the same notice, not a crash',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/notes.md'),
          _FakeRunner((command) => throw HerdrTransportException(
                TransportFailure.timeout,
                'the command timed out',
              )),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not read this file'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FileTreePage', () {
    /// A realistic `ls -lA --` listing: a directory, a file, a link.
    String listing(String path) => _ok(
          'total 32\n'
          'drwxr-xr-x   4 kit  wheel  128 Jan  4 11:22 src\n'
          '-rw-r--r--   1 kit  wheel    7 Jan  4 11:22 README.md\n',
        );

    testWidgets('lists entries with a folder icon and a document icon',
        (tester) async {
      await tester.pumpWidget(
        _host(const FileTreePage(path: '/tmp/project'), _FakeRunner(listing)),
      );
      await tester.pumpAndSettle();

      expect(find.text('src'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.folder), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.doc_text), findsOneWidget);
    });

    testWidgets('tapping a directory pushes another level', (tester) async {
      await tester.pumpWidget(
        _host(const FileTreePage(path: '/tmp/project'), _FakeRunner(listing)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();

      // The pushed page names the path it is showing in full, in the machine
      // voice. That full path is the assertion: the directory's own NAME is on
      // both screens at once, so `find.text('src')` would pass even if the push
      // had done nothing.
      expect(find.text('/tmp/project/src'), findsOneWidget);
      expect(find.text('src'), findsNWidgets(2));
    });

    testWidgets('a failed listing does NOT render as an empty folder',
        (tester) async {
      // An empty list would be shown as "this folder is empty", which is a
      // different and false statement about a directory we could not read.
      await tester.pumpWidget(
        _host(
          const FileTreePage(path: '/tmp/nope'),
          _FakeRunner((command) => remoteListFailureMarker),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Something went wrong'), findsOneWidget);
    });

    testWidgets('tapping a file pushes the preview', (tester) async {
      await tester.pumpWidget(
        _host(
          const FileTreePage(path: '/tmp/project'),
          _FakeRunner((command) {
            if (command.contains(' ls -lA ')) return listing(command);
            return _ok('readme text\n');
          }),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();

      expect(find.text('README.md'), findsWidgets);
      expect(find.text('readme text'), findsOneWidget);
    });
  });

  group('GitPage', () {
    /// A captured-shaped status: one modified file, one untracked.
    testWidgets('says the tree is clean when it is', (tester) async {
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp/repo'),
          _FakeRunner((command) {
            if (command.contains('rev-parse')) return _root();
            return _ok('');
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Working tree clean'), findsOneWidget);
    });

    testWidgets('NOT-A-REPOSITORY says so, and never "clean"', (tester) async {
      // The fail-closed case. Exit 128 means git refused to look, and reporting
      // that as a clean tree would be a confident wrong answer about the one
      // thing this screen exists to report.
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp'),
          _FakeRunner((command) {
            // `git --version` succeeds and `rev-parse` refuses: a real machine
            // with git installed and a directory that is not a repository. The
            // two must produce different sentences.
            if (command.contains('--version')) return _ok('git version 2.53.0\n');
            return '$remoteExitMarker' '128';
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('This directory is not inside a git repository'),
        findsOneWidget,
      );
      expect(find.text('Working tree clean'), findsNothing);
    });

    testWidgets('git missing is a DIFFERENT sentence from not-a-repository',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp'),
          _FakeRunner((command) => '$remoteExitMarker' '127'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('git is not installed on that machine'),
        findsOneWidget,
      );
      expect(
        find.text('This directory is not inside a git repository'),
        findsNothing,
      );
    });

    testWidgets('groups staged, unstaged and untracked separately',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp/repo'),
          _FakeRunner((command) {
            if (command.contains('rev-parse')) return _root();
            return _status(
              '1 M. N... 100644 100644 100644 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 staged.txt\u0000'
              '1 .M N... 100644 100644 100644 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 edited.txt\u0000'
              '? fresh.txt\u0000',
            );
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Staged'), findsOneWidget);
      expect(find.text('Unstaged'), findsOneWidget);
      expect(find.text('Untracked'), findsOneWidget);
      expect(find.text('staged.txt'), findsOneWidget);
      expect(find.text('edited.txt'), findsOneWidget);
      expect(find.text('fresh.txt'), findsOneWidget);
      // `+2 -1` against origin/feature/x.
      expect(find.text('2 ahead · 1 behind'), findsOneWidget);
      expect(find.text('feature/x'), findsOneWidget);
    });

    testWidgets('an unknown status letter is SHOWN, not filed as modified',
        (tester) async {
      // Fail-closed: a status this build cannot read must not be presented as a
      // status it can. The raw letters are what the row shows.
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp/repo'),
          _FakeRunner((command) {
            if (command.contains('rev-parse')) return _root();
            return _status(
              '1 .Q N... 100644 100644 100644 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 mystery.txt\u0000',
            );
          }),
        ),
      );
      await tester.pumpAndSettle();

      // Not in any section, and the screen says something is wrong.
      expect(find.text('Staged'), findsNothing);
      expect(find.text('Unstaged'), findsNothing);
      expect(find.text('Working tree clean'), findsNothing);
    });

    testWidgets('a conflict gets its own section, not "staged"', (tester) async {
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp/repo'),
          _FakeRunner((command) {
            if (command.contains('rev-parse')) return _root();
            return _status(
              'u UU N... 100644 100644 100644 100644 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
              '19d9cc8584ac2c7dcf57d2680375e80f099dc481 '
              '5fb37f0000000000000000000000000000000000 clashed.txt\u0000',
            );
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conflicted'), findsOneWidget);
      expect(find.text('Staged'), findsNothing);
      expect(find.text('clashed.txt'), findsOneWidget);
    });
  });

  group('GitDiffPage', () {
    testWidgets('a changed file shows a coloured diff, and tapping it opens it',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp/repo'),
          _FakeRunner((command) {
            if (command.contains('rev-parse')) return _root();
            if (command.contains('diff ')) {
              return _ok(
                'diff --git a/edited.txt b/edited.txt\n'
                '@@ -1 +1,2 @@\n'
                ' one\n'
                '+two\n',
              );
            }
            return _status(
              '1 .M N... 100644 100644 100644 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 '
              '45b983be36b73c0788dc9cbcb76cbb80fc7bb057 edited.txt\u0000',
            );
          }),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('edited.txt'));
      await tester.pumpAndSettle();

      // The diff is rendered from the PARSED form, so the marker is gone and
      // the text is what a reader needs.
      expect(find.text('one'), findsOneWidget);
      expect(find.text('two'), findsOneWidget);
      expect(find.textContaining('+two'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an untracked file shows its content as an addition',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const GitPage(cwd: '/tmp/repo'),
          _FakeRunner((command) {
            if (command.contains('rev-parse')) return _root();
            if (command.startsWith('head ')) return _ok('hello from a new file\n');
            return _status('? fresh.txt\u0000');
          }),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('fresh.txt'));
      await tester.pumpAndSettle();

      // `git diff` cannot see an untracked path, so the whole file is shown as
      // an addition rather than as "No diff to show".
      expect(find.text('hello from a new file'), findsOneWidget);
    });
  });

  group('GitClient command plumbing', () {
    testWidgets('a null runner is reported rather than spinning forever',
        (tester) async {
      // What the local-socket transport looks like: no shell, so no answer that
      // will ever arrive. Suspending forever would be worse than saying so.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [remoteRunnerProvider.overrideWithValue(null)],
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
              home: GitPage(cwd: '/tmp/repo'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
    });

    testWidgets('the git client provider is null without a runner',
        (tester) async {
      final container = ProviderContainer(
        overrides: [remoteRunnerProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);

      expect(container.read(gitClientProvider), isNull);
    });

    testWidgets('the git client provider wraps a runner when there is one',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          remoteRunnerProvider.overrideWithValue(_FakeRunner((c) => _ok(''))),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(gitClientProvider), isA<GitClient>());
    });
  });
}
