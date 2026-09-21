import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/board_sections.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/refresh.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_icon.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/components/connection_status_line.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/components/loading_block.dart';
import 'package:herdr_pocket/ui/components/refresh/herdr_refresh.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:herdr_pocket/ui/pages/board/ask_page.dart';
import 'package:herdr_pocket/ui/pages/hosts/hosts_page.dart';
import 'package:herdr_pocket/ui/pages/shell/shell_entry.dart';
import 'package:herdr_pocket/ui/pages/terminal/jump_sheet.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';

/// The step the centred wait should name for [status], if any.
///
/// A free function rather than logic inside the widget so the page's decision
/// (is this dial worth the centred block?) and the block's wording come from
/// the same reading of the same state.
String? _dialStep(AppLocalizations l10n, ConnectionStatus? status) {
  if (status is! Connecting) return null;
  return connectionStageStep(l10n, status.stage);
}

/// The status board.
///
/// The screen's entire argument is its ORDER: it answers "does anything need
/// me?", so the answer is at the top and everything quiet is at the bottom.
/// That ordering is computed in the domain layer, and unit-tested there — this
/// file only draws it.
class BoardPage extends ConsumerStatefulWidget {
  const BoardPage({super.key});

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  // WHICH SECTIONS ARE OPEN IS NO LONGER HELD HERE.
  //
  // It was two `Set`s on this State — with a comment explaining that the choice
  // "should reset when the app does" — and it did not even manage that: every
  // rebuild of the root shell (a trip to Settings and back is enough) threw the
  // user's answer away. The memory now lives on disk, per machine, and the
  // default is "everything open". See `boardSectionsProvider`.

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final board = ref.watch(boardProvider);
    final connection = ref.watch(connectionProvider);

    // WHAT THIS MACHINE HAS ACTUALLY ANSWERED, which is not the same as what
    // the provider is holding: a rebuild keeps the previous value on purpose
    // (that is what makes a reconnect quiet), so for as long as a machine
    // switch takes, `board.value` can still be the machine the user just left.
    // The cache is keyed by machine, so asking it for THIS one cannot answer
    // with another's — and `null` from it is the one thing the screen must not
    // draw as an empty board.
    final hostId = ref.watch(currentHostProvider.select((h) => h?.id ?? ''));
    final read = ref.read(boardCacheProvider).forHost(hostId);

    final agents = read ?? board.value ?? AgentList.empty();
    final status = connection.value;
    final failure = status is ConnectionFailed ? status : null;

    // A dial in flight. `isLoading` is part of the test and not just
    // `status is Connecting`: the provider retains its previous value while it
    // rebuilds, so the frame right after the user taps "retry" still carries
    // the old failure — and reading that as the current state is how a retry
    // that is working looks like a retry that did nothing.
    final dialling = connection.isLoading || status is Connecting;

    // Built as an explicit list rather than a collection-if inside the slivers
    // array: the failure notice, the idle state, the empty state and the
    // sections are four separate cases, and spelling them out once here keeps
    // it readable.
    final host = ref.watch(currentHostProvider);
    final idle = status is Disconnected;

    final body = <Widget>[];

    // NOTHING TO SHOW YET: the first dial, or the first board read that follows
    // it. This is the one state that gets the centred block instead of the
    // line — see [LoadingBlock] — and the reason it is conditional on there
    // being no rows is that a RECONNECT must keep the board it already has.
    // Blanking that board says "your agents are gone", which is the lie Phase
    // 26 removed; with rows on screen the line stays exactly where it was.
    //
    // `read == null` is the third way to be here, and the one a machine switch
    // creates: the link is up but nothing has been read from THIS machine yet,
    // and a summary of zeroes would be a claim about it that nobody has made.
    // It is scoped to `Online` on purpose — a machine that is not even dialling
    // has its own line and its own button ("Not connected", "Reconnect"), and
    // those must not be replaced by a spinner. A FAILURE is out for the same
    // reason: it is a line with an action, not a wait.
    final awaitingFirstBoard = agents.rows.isEmpty &&
        failure == null &&
        (dialling || board.isLoading || (read == null && status is Online));

    if (awaitingFirstBoard) {
      // TWO WAITS, SAID DIFFERENTLY. Before `Online`, the question is how the
      // dial is going. After it, the transport is fine and the board itself is
      // being read — which the old wording could not express at all, so the
      // last thing the user saw before the first agent appeared was an
      // unchanged "connecting…".
      final reading = status is Online;
      body.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: LoadingBlock(
            title: reading
                ? l10n.boardLoadingAgents
                : connectionStatusLabel(l10n, status, loading: dialling),
            step: reading ? null : _dialStep(l10n, status),
            target: reading ? null : host?.displayTarget,
            colors: colors,
          ),
        ),
      );
    } else {
      // The connection's own state, as a LINE rather than a card — for every
      // state that is not "online". See [ConnectionStatusLine] for why: a card
      // here competes with the agents, which are the only thing on this screen
      // that is actually a card.
      //
      // "Not connected yet" is not a failure and does not get the failure
      // wording; it gets the same line with a different button, because the
      // difference between "nothing is wrong, ask me to dial" and "it tried and
      // could not" is a difference in the ACTION, not in the layout.
      if (dialling || failure != null || idle) {
        body.add(
          SliverToBoxAdapter(
            child: ConnectionStatusLine(
              status: status,
              colors: colors,
              loading: dialling,
              detail: idle && host != null ? host.displayTarget : null,
              action: _connectionAction(
                l10n,
                host,
                dialling: dialling,
                failure: failure,
              ),
            ),
          ),
        );
      }
      // The state of the world, before any row. One line that answers "is
      // anything wrong?" without reading a card — which is what the board is
      // for, and what a screen of plain rows does not do.
      //
      // SHOWN WHENEVER WE HAVE AN ANSWER, including the answer "zero of
      // everything". It used to be hidden when every group was empty, on the
      // grounds that the empty state below said it better; that made "no agents"
      // and "no WORKING agents" the same picture, which is the one question this
      // strip exists to settle.
      if (!idle && failure == null && !dialling) {
        body.add(
          SliverToBoxAdapter(
            child: _SummaryStrip(
              key: boardSummaryKey,
              counts: agents.groupCounts,
              colors: colors,
            ),
          ),
        );
      }
      if (agents.rows.isEmpty && failure == null && !idle && !dialling) {
        body.add(
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(
              title: l10n.boardEmptyTitle,
              body: l10n.boardEmptyBody,
              colors: colors,
            ),
          ),
        );
      } else {
        // WHICH SECTIONS ARE OPEN is no longer computed here — see
        // `boardSectionsProvider`, which remembers the user's own answer per
        // machine. All this does is draw what that says.
        for (final section in agents.sections) {
          body.addAll(_sectionSlivers(section, colors, l10n));
        }
        // THERE IS DELIBERATELY NOTHING HERE FOR "nothing needs you".
        //
        // An earlier version filled this space with an all-clear block. The
        // argument for it was that the board exists to answer one question, and
        // when the answer is "no" it should say so rather than leaving the user
        // to infer it from silence. The argument against it, which won: the
        // summary strip above already answers the question with counts, and a
        // second, larger statement of the same thing spends a third of the
        // screen restating what the user can already see. Empty space is not a
        // missing answer — it is the answer, written in the only way that does
        // not repeat itself.
        //
        // The genuinely-empty case (no agents at all) still gets its own state,
        // because there the absence is ambiguous: no rows could mean "nothing is
        // running" or "the daemon is not talking to me", and only one of those is
        // fine to walk away from.
      }
    }

    // NO GLASS STRIP BEHIND THE BAR, and that was a decision rather than an
    // omission. It used to sit there so the blur had something to blur — and a
    // half-transparent panel across the top of the page is a BAND: measured on
    // the device it painted #2B3242 over a #252932 page, which is exactly the
    // "why is the title bar a different colour" question the strip was there to
    // answer. The bar has no background at all now (see `top_bar.dart`), so
    // there is nothing for a blur to sit behind, and glass is left to the
    // chrome that really does float: the dock and the terminal's key bar.
    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      // A Stack, so the way into a terminal floats over the board
      // rather than taking a row of it: the board's content is the
      // cards, and a button in the flow would push whichever card is
      // last off the bottom on a short screen.
      child: Stack(
        children: [
          EasyRefresh(
            header: HerdrRefreshHeader(deck: ref.watch(refreshStyleDeckProvider)),
            // Pull to refresh, because a status board is the one screen where
            // "is this still true?" is the question being asked. Wired to the
            // same read the events and the safety net use — the gesture is a
            // shortcut, not a second mechanism.
            onRefresh: () => withRefreshAnimation(() async {
              final notifier = ref.read(connectionProvider.notifier);
              if (ref.read(connectionProvider).value is! Online) {
                notifier.connect();
                return;
              }
              await ref.read(boardProvider.notifier).refresh();
            }),
            child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              HerdrSliverTopBar(
                title: l10n.boardTitle,
                // The board is a root: the dock is how you leave it, so there is no
                // way back. What sits on the LEFT is the way to the machines —
                // one tap away rather than behind a settings tab, because on a
                // phone this is the screen you need when the board says "offline",
                // which is exactly when you are least able to go hunting through
                // menus.
                leading: HerdrBarButton(
                  identifier: UiId.openMachines,
                  label: l10n.hostsTitle,
                  onPressed: _openMachines,
                  // Which glyphs the chrome uses is one setting, read here rather
                  // than threaded through: the dock and the terminal ask the same
                  // question, and a parameter would have to travel through four
                  // widgets to arrive at the three places that draw it.
                  child: ref.watch(settingsProvider.select((s) => s.iconSet)) ==
                          AppIconSet.themed
                      ? UiIcon(
                          UiIconName.machine,
                          size: 22,
                          variant: UiIconVariant.themed,
                          background: colors.surface,
                        )
                      : const Icon(CupertinoIcons.rectangle_stack),
                ),
                // The bar carries two things: the way to anywhere on the machine,
                // and whether this machine is reachable.
                actions: [
                  HerdrBarButton(
                    identifier: UiId.openJump,
                    label: l10n.jumpTitle,
                    // Only meaningful with a tree to jump around in, and the
                    // button is the answer to "where is that agent" — a question
                    // nobody asks before connecting.
                    onPressed: !idle && failure == null ? _openJump : null,
                    child: const Icon(CupertinoIcons.arrow_up_right_square),
                  ),
                  _ConnectionBadge(
                    status: status,
                    colors: colors,
                    loading: connection.isLoading,
                  ),
                ],
              ),
              // WHERE THE REFRESH ANIMATION GROWS, and the position is not
              // cosmetic: this sliver is a PLACE, not a flag. Put at the end of the
              // list it would open the panel at the bottom of the page.
              //
              // Directly under the navigation bar rather than above it, so the bar
              // stays put and the panel opens underneath — the arrangement the
              // easy_refresh examples use, and the one that keeps the large title
              // from being dragged off by a gesture about something else.
              const HeaderLocator.sliver(),
              ...body,
              // Room for the floating dock. Reserved from the dock's own
              // arithmetic so the two cannot drift: a hard-coded number here is how
              // the last card ends up half-covered on one screen and not another.
              SliverToBoxAdapter(
                child: SizedBox(
                  // The dock's band PLUS the button's: the button floats in the
                  // gap above the dock, so leaving only the dock's reserve puts
                  // the last card underneath it.
                  height: HerdrDock.reserveOf(context) +
                      ShellEntryButton.bandOf(context),
                ),
              ),
            ],
            ),
          ),
          Positioned(
            right: Space.lg,
            // ABOVE the dock, not beside it. The dock is a centred
            // pill, so on a narrow phone the gap between its right edge
            // and the screen edge is only a few dozen points — a button
            // sharing that band sits on the pill on a smaller screen.
            bottom: HerdrDock.reserveOf(context),
            child: const ShellEntryButton(),
          ),
        ],
      ),
    );
  }

  /// What the connection line offers the user, if anything.
  ///
  /// THREE ANSWERS TO THREE QUESTIONS, and the chip's label is the whole
  /// difference between them: "connect" on a machine that was never dialled,
  /// "reconnect" on one that failed, and "add machine" when there is nothing to
  /// dial at all. Nothing is offered while a dial is in flight — a button that
  /// restarts what is already running is a button that makes the wait longer.
  /// Both entry points for the machines screen, so the button and the semantics
  /// node that mirrors it cannot grow different behaviour.
  void _openMachines() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => const HostsPage()),
    );
  }

  void _openJump() => unawaited(showJumpSheet(context));

  ({String label, VoidCallback onTap})? _connectionAction(
    AppLocalizations l10n,
    HostProfile? host, {
    required bool dialling,
    required ConnectionFailed? failure,
  }) {
    if (dialling) return null;

    if (host == null) {
      return (
        label: l10n.hostAdd,
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(builder: (_) => const HostsPage()),
        ),
      );
    }

    return (
      label: failure == null ? l10n.actionConnect : l10n.actionReconnect,
      onTap: () {
        unawaited(HapticFeedback.mediumImpact());
        ref.read(connectionProvider.notifier).connect();
      },
    );
  }

  /// Opens the agent's live terminal.
  ///
  /// One tap from the board, which is the whole interaction model: the board
  /// answers "does anything need me", and the terminal is what you do about
  /// the answer.
  void _openTerminal(BuildContext context, AgentRow row) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => TerminalPage(
          paneId: row.info.paneId,
          title: row.title,
        ),
      ),
    );
  }

  /// Opens the question an agent is waiting on.
  ///
  /// See [AskPage] — it re-reads the screen before sending anything, and says
  /// so rather than guessing when the screen does not look like a question.
  void _ask(BuildContext context, AgentRow row) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => AskPage(row: row)),
    );
  }

  List<Widget> _sectionSlivers(
    ({AgentGroup group, List<AgentRow> rows}) section,
    HerdrColors colors,
    AppLocalizations l10n,
  ) {
    final heading = groupHeading(l10n, section.group);
    // THE USER'S OWN ANSWER, for this machine. Watched rather than read: this
    // is what makes a tap on a heading redraw the list.
    //
    // AND IT CANNOT GO STALE. The sections drawn are always the live ones from
    // `AgentList` — the caller iterates exactly what the daemon just reported —
    // so an agent (or a whole tab) closed on the remote machine disappears from
    // the board immediately. The remembered state is only consulted for groups
    // that are present right now, which is what keeps a preference recorded on
    // Tuesday from drawing a heading with nothing under it on Wednesday.
    final collapsed = ref.watch(boardSectionsProvider).contains(section.group);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.lg,
            Space.lg,
            Space.sm,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref
                .read(boardSectionsProvider.notifier)
                .toggle(section.group),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: Motion.press,
                  child: Icon(
                    CupertinoIcons.chevron_down,
                    size: 13,
                    color: colors.textFaint,
                  ),
                ),
                const SizedBox(width: Space.xs),
                Text(heading.text, style: heading.style(colors)),
                const SizedBox(width: Space.sm),
                Text(
                  '${section.rows.length}',
                  style: TextStyle(
                    color: colors.textFaint,
                    fontSize: TextSize.micro,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (collapsed) const SliverToBoxAdapter(child: SizedBox.shrink())
      else if (section.group == AgentGroup.unrecognised)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: Text(
              l10n.groupUnrecognisedHint,
              style: TextStyle(
                color: colors.textDim,
                fontSize: TextSize.note,
                height: 1.35,
              ),
            ),
          ),
        ),
      if (collapsed)
        const SliverToBoxAdapter(child: SizedBox.shrink())
      else
        SliverList.separated(
          itemCount: section.rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: _CardPress(
              key: ValueKey(section.rows[i].info.paneId),
              // A row that needs you opens the QUESTION, not the terminal.
              //
              // The board's job is to answer "does anything need me?" — and
              // when the answer is yes, the next thing a person wants is the
              // question itself, which they can answer from here. Every other
              // row still opens the terminal: for those, watching is the point.
              onTap: section.group == AgentGroup.needsYou
                  ? () => _ask(context, section.rows[i])
                  : () => _openTerminal(context, section.rows[i]),
              child: AgentCard(
                row: section.rows[i],
                colors: colors,
              ),
            ),
          ),
        ),
    ];
  }
}

/// A card that dips when pressed.
///
/// The board had no press feedback at all, which on a phone reads as "did that
/// register?" — the tap target is the whole card and there was nothing to
/// confirm it. A scale rather than a colour change, because colour here means
/// status and a card that tinted on touch would be borrowing the wrong word.
class _CardPress extends StatefulWidget {
  const _CardPress({required this.child, required this.onTap, super.key});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_CardPress> createState() => _CardPressState();
}

class _CardPressState extends State<_CardPress> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // The whole card is the target and it opens a live terminal, so a tap
        // that produced only a screen change gives no confirmation that it
        // landed on the right row. One light tick does.
        unawaited(HapticFeedback.selectionClick());
        widget.onTap();
      },
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.985 : 1,
        duration: Motion.press,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// One agent.
///
/// A card rather than a table row: the tap target is the whole card, and the
/// card carries the three things that matter — whether it needs you, what it
/// is, and how long it has been that way.
class AgentCard extends StatelessWidget {
  const AgentCard({
    required this.row,
    required this.colors,
    this.onTap,
    super.key,
  });

  final AgentRow row;
  final HerdrColors colors;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final statusColor = groupColor(colors, row.group);
    final isWorking = row.group == AgentGroup.working;
    // "Live": the card is either asking for you or busy. Stopped and idle cards
    // are archive — they are still worth reading, but nothing about them is
    // happening, and ringing them would flatten the difference between "this
    // needs a decision" and "this is a receipt".
    final isActive =
        row.group == AgentGroup.needsYou || row.group == AgentGroup.working;
    final info = row.info;

    // What the machine says about itself, in the order a person reads it: what
    // it is, what is answering, how full its head is. Every part is optional
    // and a missing one is simply absent — the integrations report different
    // keys and an older daemon reports none at all.
    final meta = [
      if (info.agent.isNotEmpty) info.agent,
      ?info.model,
      if (info.contextUsage case final usage?)
        '${_compact(usage.used)} / ${_compact(usage.total)}',
    ];

    final cwd = info.cwd;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.uniform),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(Radii.uniform),
            // Quiet cards have NO outline: the surface step and the shadow
            // already separate them from the ground, and a hairline on top of
            // both is a third way of saying the same thing. Only a card that is
            // doing something gets an edge, and then it is a full ring in the
            // light blue rather than a spine down one side — the spine read as
            // a decoration that happened to be coloured, and it took the card's
            // left margin with it.
            border: isActive
                ? Border.all(color: colors.cardEdgeActive)
                : null,
            boxShadow: Elevation.card(colors),
          ),
          child: Stack(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(Space.md),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: isWorking
                                  ? WorkingRing(color: statusColor)
                                  : AgentStatusDot(
                                      color: statusColor,
                                      isActive: false,
                                      diameter:
                                          row.group == AgentGroup.needsYou
                                              ? 9
                                              : 8,
                                    ),
                            ),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // The guard is at the CALL SITE, not in
                                      // the widget: an `agent.list` row always
                                      // names an agent, so an empty id here
                                      // means something is wrong with the row
                                      // rather than with the icon — and a card
                                      // that silently grew a "?" chip for it
                                      // would hide that.
                                      if (info.agent.isNotEmpty) ...[
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 1),
                                          child: AgentIcon(
                                            agent: info.agent,
                                            size: 20,
                                          ),
                                        ),
                                        const SizedBox(width: Space.sm),
                                      ],
                                      Expanded(
                                        child: Text(
                                          row.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: colors.text,
                                            fontSize: TextSize.strong,
                                            fontWeight: FontWeight.w600,
                                            height: 1.25,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: Space.sm),
                                      _TimeBadge(
                                        row: row,
                                        colors: colors,
                                      ),
                                    ],
                                  ),
                                  if (meta.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      meta.join('  ·  '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.textDim,
                                        fontSize: TextSize.meta,
                                        fontFamily: HerdrFonts.mono,
                                        height: 1.2,
                                      ),
                                    ),
                                  ],
                                  if (cwd != null && cwd.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      AgentCard._shortPath(cwd),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.textFaint,
                                        fontSize: TextSize.meta,
                                        fontFamily: HerdrFonts.mono,
                                        height: 1.2,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // NO CONTEXT GAUGE. There used to be a 3px bar pinned to the
              // card's bottom edge, filled in proportion to how much of the
              // agent's context window is used. It was removed for saying the
              // same thing twice: `54k / 1.0M` is already in the meta line
              // above, and a bar that is 5% full adds nothing to that number.
              // The one thing it did better — being visible from across the
              // room when an agent is about to run out of head — is not worth
              // putting a second, quieter copy of a fact on every card for.
            ],
          ),
        ),
      ),
    );
  }

  /// Trims `262000` to `262k` so the pair fits on a phone without an ellipsis.
  static String _compact(int value) {
    if (value >= 1000000) {
      final m = value / 1000000;
      return '${m.toStringAsFixed(m < 10 ? 1 : 0)}M';
    }
    if (value >= 1000) return '${(value / 1000).round()}k';
    return '$value';
  }

  /// Keeps the last two segments of a path — enough to identify the project
  /// without turning a long checkout path into an ellipsis.
  static String _shortPath(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return path;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }
}

/// How long the agent has been in its current state.
///
/// Machine voice — tabular figures so the badges form a readable column rather
/// than a ragged one as the numbers change width.
class _TimeBadge extends StatelessWidget {
  const _TimeBadge({required this.row, required this.colors});

  final AgentRow row;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    final label = compactTimeInState(
      row.info.statusAnchorUnixMs,
      DateTime.now().millisecondsSinceEpoch,
    );
    if (label == null) return const SizedBox(width: 2);

    return Text(
      label,
      style: TextStyle(
        color: colors.textFaint,
        fontSize: TextSize.micro,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// A quiet dot plus a word describing the connection.
class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({
    required this.status,
    required this.colors,
    this.loading = false,
  });

  final ConnectionStatus? status;
  final bool loading;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The wording comes from the same function the board's own status line
    // uses, so the badge cannot end up saying "offline" while the line below
    // says "retrying".
    final label = connectionStatusLabel(l10n, status, loading: loading);
    final color = switch (status) {
      Online() => colors.done,
      ConnectionFailed() => colors.died,
      _ => colors.textFaint,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AgentStatusDot(color: color, isActive: false, diameter: 6),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: colors.textFaint,
            fontSize: TextSize.meta,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
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
          // A quiet mark rather than an illustration: the board's whole thesis
          // is that colour is meaning, so a decorative empty-state graphic
          // would be the one place colour means nothing.
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(color: colors.hairline, width: 1.5),
              shape: BoxShape.circle,
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

/// Identifies the summary strip.
///
/// A public key because the strip deliberately repeats words that also appear
/// below it — every group name, and every count — and a test that cannot name
/// the strip has to assert on "somewhere on this screen there is a 0", which is
/// not the question.
const Key boardSummaryKey = ValueKey('board-summary');

/// The state of the whole board, in one line.
///
/// EVERY group, in the board's own order, with its count — including the ones
/// sitting at zero. Quiet by construction: dots and numbers, no sentence — a
/// summary that needed reading would be a worse version of the cards
/// underneath it.
///
/// WHY ZEROES ARE SHOWN. A summary that only lists what exists reads as
/// complete while it is not: "the working count is missing" and "nothing is
/// working" draw the same picture, and the reader has to work out which one
/// they are looking at. A dimmed zero is one glyph and removes the doubt. The
/// zero rows are drawn in the faintest ink rather than the same ink as the
/// counts, so the loud thing is still the loudest thing.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.counts,
    required this.colors,
    super.key,
  });

  final List<({AgentGroup group, int count})> counts;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xs),
      child: Wrap(
        spacing: Space.lg,
        runSpacing: Space.xs,
        children: [
          for (final entry in counts)
            Opacity(
              // The empty groups stay legible and stay quiet: they are there to
              // answer a question, not to compete with the ones that have rows.
              opacity: entry.count == 0 ? 0.55 : 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AgentStatusDot(
                    color: groupColor(colors, entry.group),
                    isActive: false,
                    diameter: 7,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    groupHeading(l10n, entry.group).text,
                    style: TextStyle(
                      color: colors.textDim,
                      fontSize: TextSize.meta,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${entry.count}',
                    style: TextStyle(
                      color: colors.text,
                      fontSize: TextSize.meta,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
