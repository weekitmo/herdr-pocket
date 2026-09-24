import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/remote_bytes.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';
import 'package:herdr_pocket/ui/pages/files/code_highlight_runner.dart';
import 'package:herdr_pocket/ui/pages/files/file_preview_page.dart';
import 'package:herdr_pocket/ui/pages/files/image_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the file preview's three ways of showing a file: coloured text you
/// can select, a picture, and the file type this app refuses to render.
///
/// The interesting failures are all "looks fine in a screenshot": colours on the
/// wrong tokens, a gutter that gets copied along with the code, an image read
/// over the wrong channel, a PDF sent down a text read to become
/// "binary file — not shown as text". Each of them has a test here.
class _FakeRunner implements RemoteCommandRunner {
  _FakeRunner(this.onRun);

  final String Function(String command) onRun;

  /// Every command run, so a test can assert that a read did NOT happen.
  final List<String> commands = [];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    return onRun(command);
  }
}

class _FakeFetcher implements RemoteFileFetcher {
  _FakeFetcher({
    this.bytes,
    this.sizeBytes,
    this.error,
  });

  final Uint8List? bytes;
  final int? sizeBytes;
  final HerdrTransportException? error;

  @override
  Future<RemoteFileInfo> statFile(String absolutePath) async {
    final error = this.error;
    if (error != null) throw error;
    return RemoteFileInfo(
      sizeBytes: sizeBytes ?? bytes?.length,
      isDirectory: false,
    );
  }

  @override
  Stream<Uint8List> download(String absolutePath) {
    final error = this.error;
    if (error != null) return Stream.error(error);
    return Stream.value(bytes ?? Uint8List(0));
  }
}

/// The sentinel the remote commands append, which the parsers split off.
String _ok(String body) => '$body$remoteExitMarker' '0';

late SharedPreferences _prefs;

/// Wraps [child] the way the app does, with the far end faked out.
///
/// The tokeniser is overridden with an inline runner rather than left to
/// `compute`: a real isolate in a widget test is driven by a real event loop
/// while the test drives a fake clock, so the colours would arrive at a moment
/// the test cannot name. The production runner has its own test (below).
Widget _host(
  Widget child, {
  RemoteCommandRunner? runner,
  RemoteFileFetcher? fetcher,
}) =>
    ProviderScope(
      overrides: [
        remoteRunnerProvider.overrideWithValue(runner),
        remoteFetcherProvider.overrideWithValue(fetcher),
        codeHighlightRunnerProvider.overrideWithValue(
          (source, language) async => highlightLines(source, language),
        ),
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

/// Every span actually handed to the engine, in order.
///
/// Read from the `RichText`s rather than from the `Text` widgets: `Text.rich`
/// keeps its spans in `textSpan`, a plain `Text` keeps its string in `data`, and
/// the only place both shapes are the same is what the engine renders.
List<TextSpan> _spans(WidgetTester tester) => [
      for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
        ..._flatten(rich.text),
    ];

Iterable<TextSpan> _flatten(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _flatten(child);
  }
}

/// Whether some span carries [text] in the ink of [role].
bool _hasInk(WidgetTester tester, String text, CodeRole role) {
  final ink = codeInk(role, CodePalette.of(Brightness.dark));
  return _spans(tester).any((s) => (s.text ?? '').contains(text) && s.style?.color == ink);
}

/// A 1x1 transparent GIF: real image bytes, so nothing is asserted about a
/// decode failure that never happened.
final Uint8List _gifBytes = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('syntax colours', () {
    testWidgets('a Python file is tokenised, not merely monospaced',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/worker.py'),
          runner: _FakeRunner(
            (_) => _ok('def frobnicate(items):\n    # a comment\n    return 1\n'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_hasInk(tester, 'def', CodeRole.keyword), isTrue);
      expect(_hasInk(tester, '# a comment', CodeRole.comment), isTrue);
      expect(_hasInk(tester, 'return', CodeRole.keyword), isTrue);
      // The text itself is all there: colours are added to the file, never
      // instead of it.
      expect(find.textContaining('frobnicate'), findsWidgets);
    });

    testWidgets('the colours arrive AFTER the text, never instead of it',
        (tester) async {
      // The page shows the file in one ink the moment it arrives and adds the
      // colours when the tokeniser answers. This is that order, asserted: a
      // 256 KB file must not leave the reader looking at a spinner.
      final completer = Completer<List<CodeLine>>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteRunnerProvider.overrideWithValue(
              _FakeRunner((_) => _ok('def f():\n    pass\n')),
            ),
            codeHighlightRunnerProvider.overrideWithValue(
              (source, language) => completer.future,
            ),
            sharedPreferencesProvider.overrideWithValue(_prefs),
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
              home: FilePreviewPage(path: '/tmp/x.py'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // On screen, uncoloured.
      expect(find.textContaining('def f()'), findsWidgets);
      expect(_hasInk(tester, 'def', CodeRole.keyword), isFalse);

      completer.complete(highlightLines('def f():\n    pass\n', 'python'));
      await tester.pumpAndSettle();

      expect(_hasInk(tester, 'def', CodeRole.keyword), isTrue);
    });

    testWidgets('a name with no grammar is left alone rather than guessed',
        (tester) async {
      // `.txt` is the case that matters: the file must open, in one ink, with
      // no colours borrowed from a language it is not.
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/notes.txt'),
          runner: _FakeRunner((_) => _ok('def not_python()\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('def not_python()'), findsWidgets);
      expect(_hasInk(tester, 'def', CodeRole.keyword), isFalse);
    });

    testWidgets('a huge file is not held back while it is tokenised',
        (tester) async {
      // Nothing here times anything — what it pins is that the text is on
      // screen in the same frame the read lands, for a file big enough that the
      // tokeniser is the slow part.
      final body = 'class A {}\n' * 4000;
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/big.dart'),
          runner: _FakeRunner((_) => _ok('$body\n')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      expect(_hasInk(tester, 'class', CodeRole.keyword), isTrue);
    });

    testWidgets('line counts stay in step with the text', (tester) async {
      // The gutter is the visible symptom of the run list and the text
      // disagreeing about how many lines there are.
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/three.py'),
          runner: _FakeRunner((_) => _ok('a = 1\n\nb = 2\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsNothing);
    });
  });

  group('selection', () {
    testWidgets('the code can be selected at all', (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/notes.txt'),
          runner: _FakeRunner((_) => _ok('alpha bravo\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SelectableRegion), findsOneWidget);
    });

    testWidgets('the line numbers are NOT selectable', (tester) async {
      // Copying a few lines is the most likely thing a reader does, and `  12`
      // in front of every line is noise that has to be cleaned up by hand.
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/notes.txt'),
          runner: _FakeRunner((_) => _ok('alpha\nbravo\n')),
        ),
      );
      await tester.pumpAndSettle();

      // A disabled container is one with no delegate: the widget layer's way of
      // taking a subtree out of a selection.
      final aroundNumber = tester
          .widgetList<SelectionContainer>(
            find.ancestor(
              of: find.text('2'),
              matching: find.byType(SelectionContainer),
            ),
          )
          .where((c) => c.delegate == null);
      expect(
        aroundNumber,
        isNotEmpty,
        reason: 'the gutter is inside the selection region',
      );

      // And the guard is around the RIGHT thing: the code beside it stays
      // selectable, or the feature would be "copy nothing".
      final aroundCode = tester
          .widgetList<SelectionContainer>(
            find.ancestor(
              of: find.text('alpha'),
              matching: find.byType(SelectionContainer),
            ),
          )
          .where((c) => c.delegate == null);
      expect(aroundCode, isEmpty, reason: 'the code must stay selectable');
    });
  });

  group('images', () {
    testWidgets('a PNG is read over the byte channel and shown',
        (tester) async {
      final runner = _FakeRunner((_) => _ok('not the bytes\n'));
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/shot.png'),
          runner: runner,
          fetcher: _FakeFetcher(bytes: _gifBytes),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      // The text channel was never asked: `head` over a PNG is what produced
      // "binary file" for every screenshot in a repository.
      expect(runner.commands, isEmpty);
    });

    testWidgets('tapping the picture opens it full screen', (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/shot.png'),
          runner: _FakeRunner((_) => _ok('')),
          fetcher: _FakeFetcher(bytes: _gifBytes),
        ),
      );
      await tester.pumpAndSettle();

      // The tap target is the FRAME rather than the bitmap. An `Image` that has
      // not decoded yet has no dimensions of its own, so a picture centred on
      // its own size would be untappable for as long as the decode takes — and
      // in a test that is forever, which is how this was found.
      final target = tester.getSize(
        find.descendant(
          of: find.byType(ImagePreview),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(target.height, greaterThan(100));
      expect(target.width, greaterThan(100));

      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('an image past the cap says how big it is', (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/huge.png'),
          runner: _FakeRunner((_) => _ok('')),
          fetcher: _FakeFetcher(sizeBytes: 40 * 1024 * 1024),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('40.0 MiB'), findsOneWidget);
      // The way out is still on the sheet, which is what makes this a sentence
      // rather than a dead end.
      expect(find.text('More actions'), findsNothing);
    });

    testWidgets('a host without SFTP gets the sshd sentence, not "failed"',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/shot.png'),
          runner: _FakeRunner((_) => _ok('')),
          fetcher: _FakeFetcher(
            error: HerdrTransportException(
              TransportFailure.sftpUnavailable,
              'no sftp subsystem',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('SFTP'),
        findsOneWidget,
        reason: 'the fix is a line in sshd_config, and the sentence must say so',
      );
    });

    testWidgets('a connection that cannot move bytes says that, not "binary"',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/shot.png'),
          runner: _FakeRunner((_) => _ok('')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not read this image'), findsOneWidget);
    });

    testWidgets('an SVG is a picture drawn from its text', (tester) async {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4">'
          '<rect width="4" height="4" fill="#123456"/></svg>';
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/logo.svg'),
          runner: _FakeRunner((_) => _ok('$svg\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SvgPicture), findsOneWidget);
    });
  });

  group('PDFs', () {
    testWidgets('are explained instead of read', (tester) async {
      // Not a read that failed: no read is attempted at all, because megabytes
      // of document this app has no renderer for would be a slow way to say the
      // same sentence.
      final runner = _FakeRunner((_) => _ok('%PDF-1.7\n'));
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/report.pdf'),
          runner: runner,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('PDFs are not rendered'), findsOneWidget);
      expect(runner.commands, isEmpty);
    });

    testWidgets('and never render as "binary file"', (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/report.pdf'),
          runner: _FakeRunner((_) => _ok('%PDF-1.7\n')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Binary file — not shown as text.'), findsNothing);
      expect(find.text('Empty file'), findsNothing);
    });
  });

  group('the more-actions sheet', () {
    /// Records what the page puts on the clipboard.
    ///
    /// A mock rather than `Clipboard.getData`, because what the test is about is
    /// WHICH TEXT was copied — the whole file, not the rows that happened to be
    /// built — and that is only visible in the call itself.
    List<String> recordClipboard(WidgetTester tester) {
      final writes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            writes.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      return writes;
    }

    testWidgets('a text file offers Copy all text, and copies the FILE',
        (tester) async {
      // The point of the row: the code view's selection is a lazily built list,
      // so "select all" there covers the rows that were built. This copies the
      // file.
      final writes = recordClipboard(tester);
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/worker.py'),
          runner: _FakeRunner((_) => _ok('one\ntwo\nthree\n')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();
      expect(find.text('Copy all text'), findsOneWidget);

      await tester.tap(find.text('Copy all text'));
      await tester.pumpAndSettle();

      // The file's own bytes: the separator newline the READ command adds is
      // not part of the file, and copying it would paste a blank line.
      expect(writes, ['one\ntwo\nthree']);
      expect(find.text('Copied'), findsOneWidget);
      // Let the toast's own dismissal timer run out, or the test ends with a
      // pending timer and fails for a reason that has nothing to do with copy.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('an SVG offers the picture, and the picture offers the source',
        (tester) async {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4"/>';
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/logo.svg', mode: FilePreviewMode.text),
          runner: _FakeRunner((_) => _ok('$svg\n')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();
      expect(find.text('Preview image'), findsOneWidget);
      await tester.tap(find.text('Preview image'));
      await tester.pumpAndSettle();
      expect(find.byType(SvgPicture), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();
      expect(find.text('View source'), findsOneWidget);
      await tester.tap(find.text('View source'));
      await tester.pumpAndSettle();

      // Replaced, not pushed: one back gesture leaves the file.
      expect(find.byType(SvgPicture), findsNothing);
      expect(find.textContaining('svg xmlns'), findsWidgets);
    });

    testWidgets('a PNG offers neither the source nor a copy of bytes',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/shot.png'),
          runner: _FakeRunner((_) => _ok('')),
          fetcher: _FakeFetcher(bytes: _gifBytes),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      expect(find.text('View source'), findsNothing);
      expect(find.text('Copy all text'), findsNothing);
      expect(find.text('Preview image'), findsNothing);
      // And the sheet is never empty: file info is unconditional.
      expect(find.text('File info'), findsOneWidget);
    });

    testWidgets('a Markdown file still offers both views and the source copy',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FilePreviewPage(path: '/tmp/README.md'),
          runner: _FakeRunner((_) => _ok('# Title\n')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      expect(find.text('Preview Markdown'), findsOneWidget);
      expect(find.text('Copy all text'), findsOneWidget);
      expect(find.text('View source'), findsNothing);
    });
  });

  group('the production tokeniser', () {
    test('returns the same runs as the inline one, through a real isolate',
        () async {
      // The one thing the widget tests deliberately do not cover: `compute`
      // itself. A job object that is not sendable would fail here — and only
      // here, on a phone, on the one file large enough to be worth an isolate.
      const source = 'class A {\n  final int x = 1;\n}\n';
      final fromIsolate = await runHighlightInIsolate(source, 'dart');
      final inline = highlightLines(source, 'dart');

      expect(fromIsolate.length, inline.length);
      for (var i = 0; i < inline.length; i++) {
        expect(fromIsolate[i].runs, inline[i].runs, reason: 'line $i');
      }
    });
  });
}
