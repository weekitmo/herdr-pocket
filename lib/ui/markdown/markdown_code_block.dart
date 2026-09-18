import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/code_highlighting.dart';
import 'package:herdr_pocket/ui/markdown/markdown_palette.dart';

/// One fenced code block, highlighted and copyable.
///
/// The header bar is not decoration: a fenced block in a README is usually a
/// COMMAND, and the thing a phone user wants from it is to run it somewhere
/// else. The bar carries the language on the left and the copy action on the
/// right, so the block's tap target never has to double as a control.
///
/// The code itself scrolls HORIZONTALLY and never wraps. Wrapping code is
/// semantically wrong — an indented continuation line becomes indistinguishable
/// from the next statement — and the horizontal drag is also what keeps long
/// lines readable at a font size somebody chose for prose.
class MarkdownCodeBlock extends StatelessWidget {
  /// Renders [code], whose fence said [language].
  const MarkdownCodeBlock({
    required this.code,
    this.language,
    super.key,
  });

  /// The block's text, without the trailing newline the fence produced.
  final String code;

  /// The fence's info string, as written (`dart`, `sh`, `language-dart`).
  final String? language;

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    final l10n = AppLocalizations.of(context);

    final base = TextStyle(
      color: palette.code.plain,
      fontSize: TextSize.note,
      height: 1.5,
      fontFamily: HerdrFonts.mono,
      fontFamilyFallback: HerdrFonts.monoFallback,
    );
    final spans = highlightedSpans(
      code,
      language,
      base: base,
      palette: palette.code,
    );
    final id = highlightLanguageId(language);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(Radii.uniform),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            language: id,
            onCopy: () => _copy(context, l10n),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              Space.md,
              0,
              Space.md,
              Space.md,
            ),
            child: Text.rich(
              TextSpan(style: base, children: spans),
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, AppLocalizations l10n) {
    unawaited(Clipboard.setData(ClipboardData(text: code)));
    unawaited(HapticFeedback.selectionClick());
    showHerdrToast(context, l10n.markdownCodeCopied);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.language, required this.onCopy});

  final String? language;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final palette = MarkdownPalette.of(context);
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, 0),
      child: Row(
        children: [
          // The canonical name, not the fence's spelling: ` ```sh ` and
          // ` ```bash ` are the same grammar, and showing what the app resolved
          // is the difference between a label and a copy of the input.
          if (language != null)
            Text(
              language!,
              style: TextStyle(
                color: palette.chipInk,
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
          const Spacer(),
          Semantics(
            button: true,
            label: l10n.markdownCodeCopy,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCopy,
              child: Padding(
                padding: const EdgeInsets.all(Space.sm),
                child: Icon(
                  CupertinoIcons.doc_on_doc,
                  size: 15,
                  color: palette.chipInk,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
