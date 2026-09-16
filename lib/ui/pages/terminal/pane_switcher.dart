import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Asks which pane to show, and returns the answer.
///
/// WHY A SHEET AND NOT A GESTURE. A terminal on a phone has already spent its
/// gestures: horizontal drags belong to the scroll view, long-press starts a
/// selection, and tap returns to the live screen. A swipe-to-switch-pane would
/// silently break one of those. A sheet makes the set of panes visible before
/// anything moves, which matters because the entries are other agents' live
/// terminals — switching is not a page turn, it is a change of subject.
Future<PaneInfo?> showPaneSwitcher(
  BuildContext context, {
  required String paneId,
}) {
  return showCupertinoModalPopup<PaneInfo>(
    context: context,
    builder: (_) => _PaneSwitcherSheet(paneId: paneId),
  );
}

class _PaneSwitcherSheet extends ConsumerWidget {
  const _PaneSwitcherSheet({required this.paneId});

  final String paneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final tree = ref.watch(navTreeProvider).value ?? WorkspaceTree.empty();

    final siblings = tree.siblingsOf(paneId);
    final inWorkspace = tree.panesInWorkspaceOf(paneId);
    // Everything else in the workspace, minus what the first section already
    // lists. Computed by id rather than by subtracting lists, because a pane
    // can legitimately appear in both reads and a set difference would drop it
    // from one of them at random.
    final siblingIds = {for (final p in siblings) p.paneId};
    final others = [
      for (final pane in inWorkspace)
        if (!siblingIds.contains(pane.paneId)) pane,
    ];

    final rows = <Widget>[
      if (siblings.length > 1) ...[
        _SectionHeader(label: l10n.paneSwitcherCurrent, colors: colors),
        for (final pane in siblings)
          _PaneTile(
            pane: pane,
            colors: colors,
            current: pane.paneId == paneId,
            l10n: l10n,
          ),
      ],
      if (others.isNotEmpty) ...[
        _SectionHeader(label: l10n.paneSwitcherOtherTabs, colors: colors),
        for (final pane in others)
          _PaneTile(pane: pane, colors: colors, current: false, l10n: l10n),
      ],
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.ground,
          borderRadius: BorderRadius.circular(Radii.uniform),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.lg,
                Space.md,
                Space.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.paneSwitcherTitle,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: TextSize.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: () =>
                        ref.read(navTreeProvider.notifier).refresh(),
                    child: Icon(
                      CupertinoIcons.arrow_clockwise,
                      size: 18,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      l10n.actionClose,
                      style: TextStyle(color: colors.accent, fontSize: TextSize.strong),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        0,
                        Space.lg,
                        Space.xl,
                      ),
                      child: Text(
                        l10n.workspacesNoPanes,
                        style: TextStyle(color: colors.textDim, fontSize: TextSize.body),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        Space.sm,
                        0,
                        Space.sm,
                        Space.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: rows,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.colors});

  final String label;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.xs),
        child: Text(
          label,
          style: TextStyle(
            color: colors.textFaint,
            fontSize: TextSize.micro,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
      );
}

/// One selectable pane.
class _PaneTile extends StatelessWidget {
  const _PaneTile({
    required this.pane,
    required this.colors,
    required this.current,
    required this.l10n,
  });

  final PaneInfo pane;
  final HerdrColors colors;
  final bool current;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    // `pane.group`, not a hand-rolled resolveAgentGroup: `pane.list` returns
    // every pane, and a plain shell reports `agent_status: "unknown"` as its
    // normal value. Judging it by that alone paints most of this sheet amber.
    // The rule — and why — lives on the domain type where it is tested.
    final group = pane.group;
    final statusColor = pane.isAgent ? groupColor(colors, group) : colors.textFaint;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // The current pane is a label, not a button: re-selecting it would tear
      // down and rebuild a live terminal for no change.
      onTap: current ? null : () => Navigator.of(context).pop(pane),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm + 2,
        ),
        decoration: BoxDecoration(
          color: current ? colors.surfaceRaised : colors.surface,
          borderRadius: BorderRadius.circular(Radii.uniform),
        ),
        child: Row(
          children: [
            AgentStatusDot(
              color: statusColor,
              isActive: false,
              diameter: 7,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pane.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: TextSize.strong,
                      fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    pane.isAgent ? pane.agent : l10n.terminalTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textFaint,
                      fontSize: TextSize.micro,
                      fontFamily: HerdrFonts.mono,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              pane.paneId.split(':').last,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
