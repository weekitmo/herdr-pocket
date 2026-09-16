import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/data/providers/refresh.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/workspace/pane_actions.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_icon.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/components/pane_actions_sheet.dart';
import 'package:herdr_pocket/ui/components/refresh/herdr_refresh.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/files/file_tree_page.dart';
import 'package:herdr_pocket/ui/pages/git/git_page.dart';
import 'package:herdr_pocket/ui/pages/launch/launch_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/layout_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';

/// The machine's own hierarchy: workspaces, their tabs, and the panes in them.
///
/// WHY THIS EXISTS ALONGSIDE THE BOARD. The board answers "does anything need
/// me?" and deliberately flattens the machine — it shows agents, not places.
/// That is the right default, and it is useless the moment the question changes
/// to "what is over in that other workspace?" or "which pane is that shell in?".
/// herdr's own UI is a tree, so a client that only has a flat list cannot
/// express what the user already knows about their machine.
///
/// The tree is the SAME data the daemon reports (`workspace.list` + `tab.list`
/// + `pane.list`), joined in the domain layer where the joining is tested. This
/// file only draws it.
class WorkspacesPage extends ConsumerWidget {
  const WorkspacesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final tree = ref.watch(navTreeProvider);

    final value = tree.value ?? WorkspaceTree.empty();

    // NO GLASS STRIP BEHIND THE BAR — see the board for the measurement that
    // removed it: a half-transparent panel across the top of a page is a BAND,
    // and the bar is supposed to be the page.
    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: EasyRefresh(
            header: HerdrRefreshHeader(deck: ref.watch(refreshStyleDeckProvider)),
            onRefresh: () => withRefreshAnimation(
              () => ref.read(navTreeProvider.notifier).refresh(),
            ),
            child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              HerdrSliverTopBar(
                title: l10n.workspacesTitle,
                actions: [
                  // CIRCLED, unlike every other page's actions, and that is a
                  // deliberate exception rather than a leak: this page's bar has
                  // NO leading button (it is one of the three roots), so its two
                  // actions are the only chrome in the row and a circle gives
                  // them the weight the way back has everywhere else. On a page
                  // that already has a circle on the left, more circles would be
                  // a toolbar.
                  HerdrBarButton(
                    circled: true,
                    // Starting something is the other half of watching it,
                    // and this page is where the user is already thinking
                    // about workspaces and panes.
                    onPressed: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const LaunchPage(),
                      ),
                    ),
                    child: const Icon(CupertinoIcons.add),
                  ),
                  HerdrBarButton(
                    circled: true,
                    onPressed: () =>
                        ref.read(navTreeProvider.notifier).refresh(),
                    child: const Icon(CupertinoIcons.arrow_clockwise),
                  ),
                ],
              ),

              // WHERE THE REFRESH ANIMATION GROWS. A place, not a flag:
              // at the end of the slivers it would open at the bottom.
              const HeaderLocator.sliver(),
              if (value.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Empty(
                    title: l10n.workspacesEmptyTitle,
                    body: l10n.workspacesEmptyBody,
                    colors: colors,
                  ),
                )
              else
                for (final node in value.workspaces)
                  ..._workspaceSlivers(context, ref, node, colors, l10n),
              // Reserve room for the floating dock, which is drawn over this
              // page by the shell above.
              if (!value.isEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(height: HerdrDock.reserveOf(context)),
                ),
            ],
            ),
        ),
    );
  }

  List<Widget> _workspaceSlivers(
    BuildContext context,
    WidgetRef ref,
    WorkspaceNode node,
    HerdrColors colors,
    AppLocalizations l10n,
  ) {
    final workspace = node.workspace;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NumberBadge(number: workspace.number, colors: colors),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      workspace.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: TextSize.title,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.workspacesCounts(workspace.tabCount, node.paneCount),
                      style: TextStyle(
                        color: colors.textFaint,
                        fontSize: TextSize.meta,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              _FocusControl(
                focused: workspace.isFocused,
                label: l10n.workspacesFocusWorkspace,
                currentLabel: l10n.workspacesCurrent,
                colors: colors,
                onFocus: () => _focus(
                  context,
                  () => ref
                      .read(navTreeProvider.notifier)
                      .focusWorkspace(workspace.workspaceId),
                  l10n,
                ),
              ),
            ],
          ),
        ),
      ),
      for (final tab in node.tabs)
        ..._tabSlivers(context, ref, tab, colors, l10n),
      if (node.hasOrphans)
        ..._tabSlivers(
          context,
          ref,
          TabNode(
            tab: TabInfo(
              tabId: 'orphan:${node.workspace.workspaceId}',
              workspaceId: node.workspace.workspaceId,
              number: 0,
              label: l10n.workspacesPanesLabel,
              paneCount: node.orphanPanes.length,
            ),
            panes: node.orphanPanes,
          ),
          colors,
          l10n,
        ),
    ];
  }

  List<Widget> _tabSlivers(
    BuildContext context,
    WidgetRef ref,
    TabNode tab,
    HerdrColors colors,
    AppLocalizations l10n,
  ) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.sm),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  // The tab header is the way into the split view, and only
                  // when there is a split to see: offering it on a one-pane tab
                  // would open a page whose whole content is "there is nothing
                  // here".
                  onTap: tab.panes.length > 1 && !tab.tab.tabId.startsWith('orphan:')
                      ? () => _push(
                            context,
                            LayoutPage(
                              paneId: tab.panes.first.paneId,
                              title: tab.tab.displayName,
                            ),
                          )
                      : null,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tab.tab.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: TextSize.note,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (tab.panes.length > 1) ...[
                        const SizedBox(width: Space.xs),
                        Icon(
                          CupertinoIcons.rectangle_split_3x1,
                          size: 14,
                          color: colors.accent,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Space.sm),
              _FocusControl(
                focused: tab.tab.isFocused,
                label: l10n.workspacesFocusTab,
                currentLabel: l10n.workspacesCurrent,
                colors: colors,
                compact: true,
                // A pane whose tab the daemon did not list gets a synthetic
                // tab id, and there is no real id to focus — so the control is
                // absent rather than present-and-failing.
                onFocus: tab.tab.tabId.startsWith('orphan:')
                    ? null
                    : () => _focus(
                          context,
                          () => ref
                              .read(navTreeProvider.notifier)
                              .focusTab(tab.tab.tabId),
                          l10n,
                        ),
              ),
            ],
          ),
        ),
      ),
      if (tab.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.lg, Space.sm),
            child: Text(
              l10n.workspacesNoPanes,
              style: TextStyle(color: colors.textFaint, fontSize: TextSize.note),
            ),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          sliver: SliverList.separated(
            itemCount: tab.panes.length,
            separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
            itemBuilder: (context, i) => _PaneRow(
              pane: tab.panes[i],
              colors: colors,
              l10n: l10n,
              onTap: () => _openPane(context, tab.panes[i]),
              onLongPress: () =>
                  _paneActions(context, ref, tab.panes[i], colors, l10n),
            ),
          ),
        ),
    ];
  }

  void _openPane(BuildContext context, PaneInfo pane) {
    _push(
      context,
      TerminalPage(paneId: pane.paneId, title: pane.displayName),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => page),
    );
  }

  /// Long press opens the actions rather than putting a second tap target on
  /// the row.
  ///
  /// Focusing a pane MOVES THE USER'S DESKTOP. That is not something to put
  /// under a 20-pixel icon that a thumb hits on the way to the row; the row's
  /// tap opens a terminal here, and changing the machine's focus is asked for
  /// explicitly.
  Future<void> _paneActions(
    BuildContext context,
    WidgetRef ref,
    PaneInfo pane,
    HerdrColors colors,
    AppLocalizations l10n,
  ) async {
    final action = await showPaneActions(context, pane: pane, withOpen: true);

    if (!context.mounted || action == null) return;
    switch (action) {
      case PaneAction.open:
        _openPane(context, pane);
      case PaneAction.browseFiles:
        _push(context, FileTreePage(path: pane.cwd!));
      case PaneAction.git:
        _push(context, GitPage(cwd: pane.cwd!));
      case PaneAction.focus:
        await _focus(
          context,
          () => ref.read(navTreeProvider.notifier).focusPane(pane.paneId),
          l10n,
        );
    }
  }

  /// Runs a focus change and reports the outcome in the user's terms.
  ///
  /// The failure path matters more than the success one: herdr may have refused
  /// because the pane closed, and saying so beats leaving the user to wonder
  /// whether their tap registered.
  Future<void> _focus(
    BuildContext context,
    Future<void> Function() action,
    AppLocalizations l10n,
  ) async {
    try {
      await action();
      if (context.mounted) _toast(context, l10n.workspacesFocusDone, isError: false);
    } on Object {
      if (context.mounted) _toast(context, l10n.workspacesFocusFailed, isError: true);
    }
  }

  void _toast(BuildContext context, String message, {required bool isError}) =>
      showHerdrToast(context, message, isError: isError);
}

/// A square showing the workspace number.
///
/// Rebuilt verbatim after an over-eager edit deleted it; every value here is
/// taken from the widget it replaced rather than re-invented.
class _NumberBadge extends StatelessWidget {
  const _NumberBadge({required this.number, required this.colors});

  final int number;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: Border.all(color: colors.hairlineQuiet),
      ),
      child: Text(
        '$number',
        style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
      ),
    );
  }
}

/// Shows either "this is focused" or "tap to focus it".
class _FocusControl extends StatelessWidget {
  const _FocusControl({
    required this.focused,
    required this.label,
    required this.currentLabel,
    required this.colors,
    this.onFocus,
    this.compact = false,
  });

  final bool focused;
  final String label;
  final String currentLabel;
  final HerdrColors colors;
  final VoidCallback? onFocus;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (focused) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AgentStatusDot(color: colors.working, isActive: false, diameter: 6),
          const SizedBox(width: 5),
          Text(
            currentLabel,
            style: TextStyle(
              color: colors.statusTextWorking,
              fontSize: compact ? TextSize.micro : TextSize.meta,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }
    if (onFocus == null) return const SizedBox.shrink();

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onFocus,
      child: Semantics(
        button: true,
        label: label,
        child: Icon(
          CupertinoIcons.scope,
          size: compact ? 15 : 17,
          color: colors.accent,
        ),
      ),
    );
  }
}

/// One pane.
class _PaneRow extends StatelessWidget {
  const _PaneRow({
    required this.pane,
    required this.colors,
    required this.l10n,
    required this.onTap,
    required this.onLongPress,
  });

  final PaneInfo pane;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final group = pane.group;
    // A pane with no agent is a shell, and a shell does not work: showing the
    // spinning ring on one would be motion with nothing behind it.
    final working = group == AgentGroup.working && pane.isAgent;
    final statusColor = working
        ? groupColor(colors, group)
        : pane.isAgent
            ? groupColor(colors, group)
            : colors.textFaint;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm + 2,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(Radii.uniform),
          // No outline by default, same as the board's cards: the surface step
          // plus the shadow is what separates a row from its ground. Focus has
          // its own marker (see [_FocusControl]) — an outline only a shade
          // darker than the divider colour was never legible as a state.
          boxShadow: Elevation.card(colors),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: Center(
                child: working
                    ? WorkingRing(color: statusColor)
                    : AgentStatusDot(
                        color: statusColor,
                        isActive: false,
                        diameter: 7,
                      ),
              ),
            ),
            const SizedBox(width: Space.sm),
            if (pane.isAgent) ...[
              AgentIcon(agent: pane.agent),
              const SizedBox(width: Space.sm),
            ],
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
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textFaint,
                      fontSize: TextSize.meta,
                      fontFamily: pane.isAgent ? HerdrFonts.mono : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            // The focused pane trades its id for the marker. Focus is the fact
            // the user came to this screen to check, and the id is already in
            // the long-press sheet — so the badge takes the space, using the
            // same dot-plus-word the workspace and tab headers use rather than
            // inventing a second way to say the same thing.
            if (pane.isFocused)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AgentStatusDot(
                    color: colors.working,
                    isActive: false,
                    diameter: 6,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    l10n.workspacesCurrent,
                    style: TextStyle(
                      color: colors.statusTextWorking,
                      fontSize: TextSize.micro,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              )
            else
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

  /// Agent id plus directory, or just the directory for a plain shell.
  String _subtitle() {
    final dir = _shortPath(pane.foregroundCwd ?? pane.cwd ?? '');
    if (pane.isAgent) {
      return dir.isEmpty ? pane.agent : '${pane.agent} · $dir';
    }
    return dir.isEmpty ? l10n.terminalTitle : dir;
  }

  static String _shortPath(String path) {
    if (path.isEmpty) return '';
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return path;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.title,
    required this.body,
    required this.colors,
  });

  final String title;
  final String body;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(color: colors.hairline, width: 1.5),
              borderRadius: BorderRadius.circular(Radii.uniform),
            ),
          ),
          const SizedBox(height: Space.lg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.text,
              fontSize: TextSize.title,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Space.sm),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textDim, fontSize: TextSize.strong, height: 1.4),
          ),
        ],
      ),
    );
  }
}
