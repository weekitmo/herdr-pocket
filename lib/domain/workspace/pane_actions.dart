/// What can be done with a pane, decided once.
///
/// ONE LIST, TWO PLACES THAT DRAW IT. The workspaces page offers these behind a
/// long press on a pane row; the terminal page offers them behind an overflow
/// button, because someone who is already looking at the pane should not have to
/// go back out to the list to see what changed in it. Two screens deciding
/// separately which rows a pane qualifies for is how "Git changes" ends up
/// available in one place and not the other — and the rule is not obvious
/// enough to re-derive by reading it twice.
///
/// The rule is: a row is offered only when following it leads somewhere.
library;

import 'package:herdr_pocket/domain/workspace/pane_info.dart';

/// One row of a pane's action sheet.
enum PaneAction {
  /// Open the pane as a terminal here.
  ///
  /// Only the workspaces page offers this, because the terminal page IS the
  /// pane opened — offering it there would be a row that closes the screen it
  /// is on.
  open,

  /// Browse the pane's directory.
  browseFiles,

  /// Read the pane's git status and diff.
  git,

  /// Move the machine's own focus to this pane.
  focus,
}

/// The actions [pane] can actually carry out, in the order they are offered.
///
/// [withOpen] adds [PaneAction.open] in front, for the callers that are not
/// already showing the pane.
///
/// `browseFiles` and `git` both need the pane's working directory, and it is
/// genuinely absent on some panes — the daemon reports `cwd` as optional, and a
/// pane whose shell has exited has none. Offering "Git changes" there would
/// open a page whose only honest content is "no directory", so the row is not
/// drawn at all. Same for focus: a pane that already has the machine's focus
/// has nothing to do.
List<PaneAction> paneActionsFor(PaneInfo pane, {bool withOpen = false}) {
  final hasDirectory = pane.cwd != null && pane.cwd!.trim().isNotEmpty;
  return [
    if (withOpen) PaneAction.open,
    if (hasDirectory) PaneAction.browseFiles,
    if (hasDirectory) PaneAction.git,
    if (!pane.isFocused) PaneAction.focus,
  ];
}
