import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/domain/workspace/pane_actions.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/menu_popover.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The sheet of things you can do with a pane.
///
/// ONE SHEET, TWO DOORS. It is opened by a long press on a pane row in the
/// workspaces list and by the overflow button in the terminal — the same
/// question asked from two places, so it is the same sheet with the same rows
/// in the same order. Building it twice is how the two copies drift.
///
/// The rows come from [paneActionsFor]: an action appears only when following
/// it leads somewhere, so a pane with no working directory does not offer to
/// show its files, and a pane the machine is already looking at does not offer
/// to focus itself.
Future<PaneAction?> showPaneActions(
  BuildContext context, {
  required PaneInfo pane,
  bool withOpen = false,
  List<String> traceAgents = const [],
}) {
  final l10n = AppLocalizations.of(context);
  return showCupertinoModalPopup<PaneAction>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      // The sheet's header is drawn by Cupertino too, at its own sizes. Both
      // lines are pulled onto the app's ladder for the same reason the rows are.
      title: Text(
        pane.displayName,
        style: const TextStyle(fontSize: TextSize.strong),
      ),
      // The directory, not the pane id. "w9:p3" is what the DAEMON calls it and
      // it is the one thing on screen the user has never seen anywhere else;
      // the path is what tells them whether this is the pane they meant.
      message: Text(
        pane.cwd ?? pane.paneId,
        style: const TextStyle(
          fontFamily: HerdrFonts.mono,
          fontSize: TextSize.meta,
        ),
      ),
      actions: [
        for (final action in paneActionsFor(
          pane,
          withOpen: withOpen,
          traceAgents: traceAgents,
        ))
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(action),
            child: actionSheetLabel(labelForPaneAction(action, l10n)),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: actionSheetLabel(l10n.actionCancel),
      ),
    ),
  );
}

/// The glyph for one action.
///
/// Two answers, because the app ships two icon sets and the menu has to agree
/// with whichever is switched on — a menu of themed icons under a navbar of
/// system ones would look like two apps stapled together.
(UiIconName, IconData) paneActionGlyph(PaneAction action) => switch (action) {
  PaneAction.open => (UiIconName.workspaces, CupertinoIcons.arrow_right_square),
  PaneAction.browseFiles => (UiIconName.folder, CupertinoIcons.folder),
  PaneAction.git => (UiIconName.branch, CupertinoIcons.arrow_branch),
  // The themed set has no document glyph; `BlocksAndArrows` is the closest
  // thing in it to "a structured list of what happened", and the row's label
  // does the rest of the work. A proper doc icon means fetching one into
  // `assets/ui_icons/` and re-recording the manifest.
  PaneAction.trace => (UiIconName.panes, CupertinoIcons.doc_text),
  PaneAction.focus => (UiIconName.aim, CupertinoIcons.scope),
};

/// What each row says.
///
/// Shared so that one action is never called two different things depending on
/// which screen opened the sheet.
String labelForPaneAction(PaneAction action, AppLocalizations l10n) =>
    switch (action) {
      PaneAction.open => l10n.actionOpen,
      PaneAction.browseFiles => l10n.filesTitle,
      PaneAction.git => l10n.gitTitle,
      PaneAction.trace => l10n.paneActionTrace,
      PaneAction.focus => l10n.workspacesFocusPane,
    };
