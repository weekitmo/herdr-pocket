import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/files/file_meta.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/files/file_preview_page.dart';
import 'package:herdr_pocket/ui/pages/files/file_tree_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The long press on a file, and what it leads to.
///
/// The interaction changed shape in this round: the long press used to repeat
/// the trailing download button, and it now opens a panel. These tests are the
/// ones that fail if the old behaviour comes back — they assert what the sheet
/// CONTAINS, not merely that something opened, because a sheet with the wrong
/// rows in it is the failure mode a screenshot looks fine in.
class _FakeRunner implements RemoteCommandRunner {
  _FakeRunner(this.onRun);

  final String Function(String command) onRun;

  @override
  Future<String> runCommand(String command) async => onRun(command);
}

String _ok(String body) => '$body$remoteExitMarker' '0';

/// An `ls -lA --` listing with one directory and files of each kind.
String _listing() => _ok(
      'total 32\n'
      'drwxr-xr-x   4 kit  wheel  128 Jan  4 11:22 src\n'
      '-rw-r--r--   1 kit  wheel    7 Jan  4 11:22 README.md\n'
      '-rw-r--r--   1 kit  wheel    9 Jan  4 11:22 notes.txt\n',
    );

/// A `stat` reply: 1024 bytes, modified at a fixed epoch, no birth time.
String _stat() => _ok('1024\t1700000000\t0\t-rw-r--r--\tkit\twheel\n');

/// The same six fields the real command prints, with a birth time.
String _statWithBirth() =>
    _ok('2048\t1700000000\t1600000000\t-rw-r--r--\tkit\twheel\n');

late SharedPreferences _prefs;

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

RemoteCommandRunner _treeRunner({
  String Function(String command)? stat,
}) =>
    _FakeRunner((command) {
      if (command.contains(' ls -lA ')) return _listing();
      if (command.contains(' stat -c ') || command.contains(' stat -f ')) {
        return (stat ?? (_) => _stat())(command);
      }
      return _ok('readme text\n');
    });

Future<void> _openTree(WidgetTester tester, RemoteCommandRunner runner) async {
  await tester.pumpWidget(_host(const FileTreePage(path: '/tmp/project'), runner));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('the long-press sheet', () {
    testWidgets('offers the Markdown preview for a .md file', (tester) async {
      await _openTree(tester, _treeRunner());
      await tester.longPress(find.text('README.md'));
      await tester.pumpAndSettle();

      // The title names the file and the message carries the path, so the two
      // files with the same name in two folders cannot be confused.
      expect(find.text('Preview Markdown'), findsOneWidget);
      expect(find.text('File info'), findsOneWidget);
      expect(find.text('/tmp/project/README.md'), findsOneWidget);
    });

    testWidgets('does NOT offer a Markdown preview for other files', (
      tester,
    ) async {
      await _openTree(tester, _treeRunner());
      await tester.longPress(find.text('notes.txt'));
      await tester.pumpAndSettle();

      expect(find.text('Preview Markdown'), findsNothing);
      expect(find.text('File info'), findsOneWidget);
    });

    testWidgets('a directory has no sheet at all', (tester) async {
      await _openTree(tester, _treeRunner());
      await tester.longPress(find.text('src'));
      await tester.pumpAndSettle();

      // An empty sheet would teach the user that long pressing does nothing,
      // which is worse than a row that never invites the gesture.
      expect(find.text('File info'), findsNothing);
      expect(find.text('src'), findsWidgets);
    });

    testWidgets('the download row follows the transfer setting', (tester) async {
      await _openTree(tester, _treeRunner());
      await tester.longPress(find.text('README.md'));
      await tester.pumpAndSettle();

      // Transfer is off in this harness's preferences, so it must not be
      // offered — the sheet is the same authority as the trailing button.
      expect(find.text('Download to phone'), findsNothing);
    });
  });

  testWidgets('the sheet is on screen while the finger is still down', (
    tester,
  ) async {
    // The emulator could not answer this: `adb shell input` opens the sheet and
    // it is gone by the next screenshot, which is either the barrier eating the
    // finger's own release or the injected event stream losing the deadline.
    // Flutter's own event model is the authority for what a real finger does —
    // and what a real finger does is hold, see the sheet, and only then lift.
    await _openTree(tester, _treeRunner());

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('README.md')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(CupertinoActionSheet), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    // Still there after the release: a long press is not a drag, and lifting
    // the finger is how the user gets to the menu rather than how they dismiss
    // it.
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    expect(find.text('Preview Markdown'), findsOneWidget);
  });

  group('file info', () {
    testWidgets('shows size, times, permissions and ownership', (tester) async {
      await _openTree(tester, _treeRunner());
      await tester.longPress(find.text('README.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File info'));
      await tester.pumpAndSettle();

      expect(find.text('Size'), findsOneWidget);
      expect(find.text('1 KiB'), findsOneWidget);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('-rw-r--r--'), findsOneWidget);
      expect(find.text('kit'), findsOneWidget);
      expect(find.text('wheel'), findsOneWidget);
      // A zero birth time is the absence of a date, said in words rather than
      // rendered as 1970.
      expect(find.text('Not recorded by the file system'), findsOneWidget);
    });

    testWidgets('renders a recorded birth time as a date', (tester) async {
      await _openTree(
        tester,
        _treeRunner(stat: (_) => _statWithBirth()),
      );
      await tester.longPress(find.text('README.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File info'));
      await tester.pumpAndSettle();

      // Computed with the same formatter the UI uses, so the assertion does not
      // depend on the machine's time zone.
      final expected = formatFileTimestamp(
        DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000),
      );
      expect(find.text(expected), findsOneWidget);
      expect(find.text('Not recorded by the file system'), findsNothing);
    });

    testWidgets('a failed stat says so and does not draw empty rows', (
      tester,
    ) async {
      await _openTree(
        tester,
        _treeRunner(stat: (_) => '$remoteExitMarker' '1'),
      );
      await tester.longPress(find.text('README.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File info'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the file info'), findsOneWidget);
      expect(find.text('Size'), findsNothing);
    });
  });

  group('the Markdown view', () {
    testWidgets('the sheet opens the rendered document, not the bytes', (
      tester,
    ) async {
      final runner = _FakeRunner((command) {
        if (command.contains(' ls -lA ')) return _listing();
        if (command.contains(' stat ')) return _stat();
        return _ok('# Title\n\nsome **bold** words\n');
      });
      await _openTree(tester, runner);
      await tester.longPress(find.text('README.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview Markdown'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Title'), findsWidgets);
      expect(find.textContaining('bold'), findsOneWidget);
      // The markup is gone: this is the renderer, not the file.
      expect(find.textContaining('# Title'), findsNothing);
    });

    testWidgets('the preview page can switch back to the source', (tester) async {
      final runner = _FakeRunner((command) {
        if (command.contains(' ls -lA ')) return _listing();
        if (command.contains(' stat ')) return _stat();
        return _ok('# Title\n');
      });
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(
            path: '/tmp/project/README.md',
            mode: FilePreviewMode.markdown,
          ),
          runner,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();
      expect(find.text('View source'), findsOneWidget);

      await tester.tap(find.text('View source'));
      await tester.pumpAndSettle();

      // Replaced, not pushed: the same file seen two ways, so one back gesture
      // leaves the file rather than undoing the view switch.
      expect(find.text('# Title'), findsOneWidget);
      expect(find.text('View source'), findsNothing);
      expect(find.text('Preview Markdown'), findsNothing);
    });

    testWidgets('the text view offers the preview for a .md file', (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/project/README.md'),
          _treeRunner(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      expect(find.text('Preview Markdown'), findsOneWidget);
      expect(find.text('View source'), findsNothing);
    });

    testWidgets('a non-Markdown file is offered no preview', (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/project/main.dart'),
          _treeRunner(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      expect(find.text('Preview Markdown'), findsNothing);
      expect(find.text('View source'), findsNothing);
      expect(find.text('File info'), findsOneWidget);
    });
  });
}
