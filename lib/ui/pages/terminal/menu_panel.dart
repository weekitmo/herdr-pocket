import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The candidate list, so a test can aim at the panel rather than at "some
/// widget somewhere that happens to say code-review".
const Key composerMenuKey = ValueKey('terminal.composer.menu');

/// One row of a composer menu.
///
/// Everything the row needs to DISPLAY is here; everything it MEANS is not. The
/// menu does not know what a skill is, and the page builds these out of skills,
/// MCP servers and file paths alike — which is why `insert` is carried rather
/// than derived: the thing that produced the row is the only thing that knows
/// whether a pick is `/code-review` or `@lib/main.dart`.
class ComposerMenuRow {
  const ComposerMenuRow({
    required this.insert,
    required this.title,
    required this.kind,
    this.subtitle = '',
    this.tag = '',
  });

  /// The whole replacement for the token, trigger character included.
  final String insert;

  /// The name, as the user reads it.
  final String title;

  /// The line under the title: a skill's own description, an MCP server's
  /// command, a file's parent directory.
  final String subtitle;

  /// Which group the row belongs to, as an already-localized label. Rows are
  /// shown in the order they arrive, with a header whenever this changes.
  final String kind;

  /// A short right-aligned marker — the source file a skill came from, and so on.
  final String tag;
}

/// The list of things `/` and `@` can insert.
///
/// WHY IT LOOKS LIKE THIS. It is an overlay onto a terminal, so it borrows the
/// terminal's own restraint: no separators between rows, one weight of text for
/// the names, and a quiet second line that is allowed to be cut off — a row that
/// wraps to four lines is a row nobody compares with the one above it.
///
/// It takes LAYOUT SPACE rather than covering the terminal, and that is a
/// decision with a reason: the terminal is bottom-aligned (see
/// `domain/terminal/window.dart`), so the rows it loses are the least
/// interesting ones, and nothing the user typed is ever hidden behind a panel.
class ComposerMenu extends StatelessWidget {
  const ComposerMenu({
    required this.rows,
    required this.colors,
    required this.onPick,
    this.message,
    this.messageIsError = false,
    super.key,
  });

  final List<ComposerMenuRow> rows;
  final HerdrColors colors;
  final ValueChanged<ComposerMenuRow> onPick;

  /// What to say when there is nothing to show — the sentence is built by the
  /// caller, because only the caller knows whether it is looking at a directory
  /// with no files in it or a machine it could not reach.
  final String? message;

  /// Whether [message] is a failure rather than an absence.
  final bool messageIsError;

  /// How tall the panel may get. Roughly five rows: past that the user is
  /// reading, not choosing, and the terminal underneath has paid for it.
  static const double maxHeight = 244;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: composerMenuKey,
      // `width: double.infinity`, and this one line is the whole of a bug the
      // user could see. The panel sits in a Column, and a Column hands its
      // children LOOSE cross-axis constraints. With a list inside, the list
      // takes the full width and everything looks right; with a single sentence
      // inside — "nothing matches" — the container shrink-wrapped to the width
      // of that sentence, and the panel's background and hairline came in with
      // it. Two states of one panel have to be the same width.
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: rows.isEmpty ? _message(context) : _list(),
    );
  }

  Widget _message(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.lg,
      ),
      child: Text(
        message ?? '',
        style: TextStyle(
          color: messageIsError ? colors.died : colors.textFaint,
          fontSize: TextSize.note,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _list() {
    // A header whenever the group changes: the groups ARE the answer to "where
    // did this come from", and a per-row tag on every line is noise on a row
    // that is already carrying a description.
    final children = <Widget>[];
    String? lastKind;
    for (final row in rows) {
      if (row.kind != lastKind) {
        lastKind = row.kind;
        children.add(_header(row.kind));
      }
      children.add(_row(row));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: Space.sm),
      shrinkWrap: true,
      children: children,
    );
  }

  Widget _header(String label) => Padding(
    padding: const EdgeInsets.only(
      left: Space.lg,
      right: Space.lg,
      top: Space.md,
      bottom: Space.xs,
    ),
    child: Text(
      label,
      style: TextStyle(
        color: colors.textFaint,
        fontSize: TextSize.micro,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _row(ComposerMenuRow row) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: 0.6,
      onPressed: () {
        unawaited(HapticFeedback.selectionClick());
        onPick(row);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: TextSize.body,
                    ),
                  ),
                  if (row.subtitle.isNotEmpty)
                    Text(
                      row.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textFaint,
                        fontSize: TextSize.meta,
                      ),
                    ),
                ],
              ),
            ),
            if (row.tag.isNotEmpty) ...[
              const SizedBox(width: Space.sm),
              Text(
                row.tag,
                style: TextStyle(
                  color: colors.textFaint,
                  fontSize: TextSize.micro,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
