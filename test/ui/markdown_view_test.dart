import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';
import 'package:herdr_pocket/ui/markdown/markdown_view.dart';
import 'package:herdr_pocket/ui/markdown/mermaid_block.dart';

/// The Markdown renderer, block by block.
///
/// These assert the things a screenshot cannot: that a table is a GRID rather
/// than a paragraph of pipes, that a fenced block's tokens are actually
/// coloured, and that a diagram that does not parse shows its source instead of
/// an empty box. Each of those fails silently in the other direction — the page
/// still draws, it just draws the wrong thing.
const _document = '''
# Title

A paragraph with **bold**, *italic* and `inline code`.

| Name | Value | Note |
| :--- | ----: | :--: |
| a | 1 | first |
| b | 2 | second |

```dart
final x = 1; // comment
```

- [x] done
- [ ] todo

> quoted text

---

![a picture](img.png)
''';

const _mermaid = '''
```mermaid
graph TD
  A[Start] --> B{Works?}
  B -->|yes| C[Ship it]
```
''';

Widget _host(Widget child) => HerdrTheme(
  colors: HerdrColors.dark,
  child: CupertinoApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: CupertinoPageScaffold(
      child: child,
    ),
  ),
);

void main() {
  testWidgets('renders headings, prose and inline markup', (tester) async {
    await tester.pumpWidget(_host(const MarkdownView(source: _document)));
    await tester.pump();

    expect(find.textContaining('Title'), findsWidgets);
    expect(find.textContaining('A paragraph with'), findsOneWidget);
    // The markup characters themselves must not survive into the output.
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('`inline code`'), findsNothing);
    expect(find.textContaining('inline code'), findsOneWidget);
  });

  testWidgets('renders a table as a grid', (tester) async {
    await tester.pumpWidget(_host(const MarkdownView(source: _document)));
    await tester.pump();

    expect(find.byType(Table), findsOneWidget);
    // Every cell of the table, header included.
    for (final cell in ['Name', 'Value', 'Note', 'a', '1', 'first']) {
      expect(find.text(cell), findsWidgets, reason: 'cell $cell');
    }
    // The pipes are syntax, not content.
    expect(find.textContaining('|'), findsNothing);
  });

  testWidgets('colours a fenced code block and names its language', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const MarkdownView(source: _document)));
    await tester.pump();

    expect(find.text('dart'), findsOneWidget);

    // The highlighted spans are the evidence that a grammar ran: at least one
    // span inside the block must carry a colour that is not the block's plain
    // ink.
    final colours = <Color>{};
    for (final element in tester.widgetList<Text>(find.byType(Text))) {
      final span = element.textSpan;
      span?.visitChildren((child) {
        if (child is TextSpan && child.style?.color != null) {
          colours.add(child.style!.color!);
        }
        return true;
      });
    }
    final palette = CodePalette.of(Brightness.dark);
    expect(colours, contains(palette.keyword));
    expect(colours, contains(palette.comment));
  });

  testWidgets('renders task list items as boxes, not as marks', (tester) async {
    await tester.pumpWidget(_host(const MarkdownView(source: _document)));
    await tester.pump();

    expect(find.textContaining('[x]'), findsNothing);
    expect(find.textContaining('[ ]'), findsNothing);
    expect(find.text('done'), findsOneWidget);
    expect(find.text('todo'), findsOneWidget);
    // Two boxes, one of them ticked.
    expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
  });

  testWidgets('draws an image reference as a chip, not as an empty gap', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const MarkdownView(source: _document)));
    await tester.pump();

    expect(find.text('a picture'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.photo), findsOneWidget);
  });

  testWidgets('an image with nothing to name it falls back to a word', (
    tester,
  ) async {
    // `![]()` carries neither alt text nor a source, and an unlabelled chip
    // would be a mystery icon. The alt text and the file name both win when
    // they exist — this is only the last resort.
    await tester.pumpWidget(_host(const MarkdownView(source: '![]()')));
    await tester.pump();

    expect(find.text('image'), findsOneWidget);
  });

  testWidgets('draws a mermaid fence as a diagram', (tester) async {
    await tester.pumpWidget(_host(const MarkdownView(source: _mermaid)));
    await tester.pump();

    expect(find.byType(MermaidBlock), findsOneWidget);
    // The source must NOT be on screen as text: this is the whole difference
    // between a preview and a syntax-highlighted file.
    expect(find.textContaining('graph TD'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('a broken mermaid fence shows its source and says why', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MarkdownView(
          source: '```mermaid\ngraph TD\n  A -->\\n```',
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MermaidBlock), findsOneWidget);
    expect(find.textContaining('Could not draw this diagram'), findsOneWidget);
    expect(find.textContaining('graph TD'), findsOneWidget);
  });

  testWidgets('an unknown fence is plain text, not a blank block', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MarkdownView(
          source: '```brainfuck\n++++[>++++<-]>\n```',
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('++++[>++++<-]>'), findsOneWidget);
    // No language label: nothing was compiled, so there is nothing to name.
    expect(find.text('brainfuck'), findsNothing);
  });

  test('the language normaliser strips the class-name prefix', () {
    expect(highlightLanguageId('language-dart'), 'dart');
    expect(highlightLanguageId('Dart'), 'dart');
    expect(highlightLanguageId('lang-sh'), 'bash');
    expect(highlightLanguageId('dart linenums'), 'dart');
    // Aliases come from the grammars themselves, not from a second table.
    expect(highlightLanguageId('sh'), 'bash');
    expect(highlightLanguageId('py'), 'python');
    expect(highlightLanguageId('yml'), 'yaml');
    expect(highlightLanguageId('mermaid'), isNull);
    expect(languageId('mermaid'), 'mermaid');
    expect(languageId(null), isNull);
    expect(highlightLanguageId('not-a-language'), isNull);
  });
}
