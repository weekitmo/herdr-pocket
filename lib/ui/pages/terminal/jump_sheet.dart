import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/workspace/jump_target.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';

/// One sheet that maps the whole session.
///
/// The workspaces page shows the SHAPE of the machine — a tree, which is the
/// right answer to "what have I got open?". This answers a different question:
/// "take me to the one that is waiting on me". So it is flat, ordered by
/// urgency using the board's own ranking, and every row carries enough
/// breadcrumb to recognise where it goes.
///
/// Tap opens it here. Long-press also moves the MACHINE's focus, which is a
/// visible side effect on the user's desktop — hence a second, deliberate
/// gesture rather than something that happens every time somebody reads
/// something on their phone.
Future<void> showJumpSheet(BuildContext context) => showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => const _JumpSheet(),
    );

class _JumpSheet extends ConsumerWidget {
  const _JumpSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    final tree = ref.watch(navTreeProvider).value;
    final board = ref.watch(boardProvider).value ?? AgentList.empty();

    final list = tree == null
        ? JumpList.empty()
        : JumpList.join(tree: tree, agents: board);

    return Container(
      decoration: BoxDecoration(
        color: colors.ground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.uniform),
        ),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
              child: Row(
                children: [
                  Text(
                    sectionTitle(context, l10n.jumpTitle),
                    style: TextStyle(
                      color: colors.textFaint,
                      fontSize: TextSize.note,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  // The number the sheet is FOR. Reading it here means the
                  // answer is available before any scrolling happens.
                  if (list.needsYouCount > 0)
                    Text(
                      l10n.boardNeedsYouCount(list.needsYouCount),
                      style: TextStyle(
                        color: colors.waiting,
                        fontSize: TextSize.meta,
                      ),
                    ),
                ],
              ),
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.xxl,
                ),
                child: Text(
                  l10n.jumpEmpty,
                  style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: Space.md),
                  children: [
                    for (final section in list.sections) ...[
                      _SectionHeader(group: section.group, colors: colors, l10n: l10n),
                      for (final target in section.rows)
                        _TargetRow(target: target, colors: colors, l10n: l10n),
                    ],
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
              child: Text(
                l10n.jumpFooter,
                style: TextStyle(
                  color: colors.textFaint,
                  fontSize: TextSize.meta,
                  height: 1.35,
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
  const _SectionHeader({
    required this.group,
    required this.colors,
    required this.l10n,
  });

  final AgentGroup? group;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final label = group == null ? l10n.jumpSectionPanes : groupHeading(l10n, group!).text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xs),
      child: Text(
        sectionTitle(context, label),
        style: TextStyle(color: colors.textFaint, fontSize: TextSize.micro),
      ),
    );
  }
}

class _TargetRow extends ConsumerWidget {
  const _TargetRow({
    required this.target,
    required this.colors,
    required this.l10n,
  });

  final JumpTarget target;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dot = target.group == null
        ? colors.textFaint
        : groupColor(colors, target.group!);

    Future<void> open({required bool focusOnMachine}) async {
      final status = ref.read(connectionProvider).value;
      if (focusOnMachine && status is Online) {
        try {
          await status.client.focusPane(target.paneId);
        } on Object {
          if (context.mounted) {
            showHerdrToast(context, l10n.workspacesFocusFailed, isError: true);
          }
          return;
        }
      }
      if (!context.mounted) return;
      Navigator.of(context).pop();
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => TerminalPage(
            paneId: target.paneId,
            title: target.title,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(open(focusOnMachine: false)),
      onLongPress: () => unawaited(open(focusOnMachine: true)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.text, fontSize: TextSize.body),
                  ),
                  Text(
                    target.breadcrumb,
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
            const SizedBox(width: Space.sm),
            Icon(
              CupertinoIcons.chevron_forward,
              size: 13,
              color: colors.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}
