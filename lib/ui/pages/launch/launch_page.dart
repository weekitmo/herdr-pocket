import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/agent_launcher.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/domain/git/worktree.dart';
import 'package:herdr_pocket/domain/workspace/agent_launch.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/pane_process.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_icon.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';

/// Starting an agent from the phone.
///
/// The board can watch and answer; this is the other half — making something
/// happen on the machine without walking to it. Two paths, one screen:
///
/// * a NEW workspace at a chosen directory (optionally an isolated git
///   worktree, so the agent cannot touch what you are looking at), or
/// * an agent in an existing pane whose shell is free.
///
/// Everything here is a herdr primitive: `workspace.create` / `worktree.create`
/// bring their own root pane, and `agent.start` activates it. No bridge binary,
/// no shell command typed on the user's behalf.
class LaunchPage extends ConsumerStatefulWidget {
  const LaunchPage({this.initialDirectory, super.key});

  /// Where to start. Defaults to wherever the panes already are.
  final String? initialDirectory;

  @override
  ConsumerState<LaunchPage> createState() => _LaunchPageState();
}

class _LaunchPageState extends ConsumerState<LaunchPage> {
  final _directory = TextEditingController();
  final _branch = TextEditingController();
  final _name = TextEditingController();

  HerdrClient? _owner;
  List<AgentIntegration>? _integrations;
  WorktreeListing? _repository;
  List<_PaneCandidate>? _panes;
  String? _kind;
  String? _paneId;
  bool _paneMode = false;
  bool _useWorktree = false;
  bool _busy = false;
  bool _creating = false;
  LaunchFailure? _failure;

  @override
  void dispose() {
    _directory.dispose();
    _branch.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Loads the two facts the form needs, once per connection.
  ///
  /// In `build` rather than `initState` for the reason AskPage learned the hard
  /// way: the connection provider is asynchronous, so on the first frame there
  /// is no client — and a page that captured "not connected" at that instant
  /// reports a connection error on a perfectly good connection.
  Future<void> _load(HerdrClient client) async {
    if (identical(_owner, client)) return;
    _owner = client;

    try {
      final integrations = await client.integrationList();
      final panes = await client.paneList();
      if (!mounted) return;
      setState(() {
        _integrations = integrations;
        // First AVAILABLE agent, not merely the first: defaulting to something
        // whose binary is missing would make the primary button fail on the
        // first tap for no reason the user could see.
        _kind = integrations
                .where((i) => i.available)
                .map((i) => i.target)
                .firstOrNull ??
            integrations.map((i) => i.target).firstOrNull;
        _name.text = suggestAgentName(
          kind: _kind ?? 'agent',
          taken: _existingNames(),
        );
        _directory.text = widget.initialDirectory ??
            defaultWorkingDirectory(panes) ??
            '';
      });
      await _probeRepository(client);
    } on Object catch (e) {
      if (mounted) setState(() => _failure = LaunchFailure.from(e));
    }
  }

  /// Asks whether the chosen directory is inside a git work tree.
  ///
  /// Asked rather than assumed, because the answer is what decides whether the
  /// worktree option is offered at all — and `not_git_worktree` is a normal
  /// answer, not an error to show.
  Future<void> _probeRepository(HerdrClient? client) async {
    final c = client ?? _owner;
    final cwd = _directory.text.trim();
    if (c == null || cwd.isEmpty) return;
    try {
      final listing = await c.worktreeList(cwd: cwd);
      if (!mounted) return;
      setState(() {
        _repository = listing.isRepository ? listing : null;
        if (!listing.isRepository) _useWorktree = false;
      });
    } on Object {
      // A refusal here is information, not a failure: no repository means the
      // plain workspace path, which is still a perfectly good thing to do.
      if (mounted) {
        setState(() {
          _repository = null;
          _useWorktree = false;
        });
      }
    }
  }

  /// Asks each pane what is running in it, then judges it.
  ///
  /// The judgement is [evaluateLaunchSurface]'s — a pane whose shell does not
  /// own the foreground cannot take an agent, and the user gets to see WHICH
  /// condition failed instead of a refusal from the daemon.
  Future<void> _loadPanes() async {
    final client = _owner;
    if (client == null || _panes != null) return;
    try {
      final panes = await client.paneList();
      final candidates = <_PaneCandidate>[];
      for (final pane in panes) {
        PaneProcessInfo? info;
        try {
          info = await client.paneProcessInfo(paneId: pane.paneId);
        } on Object {
          info = null;
        }
        candidates.add(
          _PaneCandidate(
            pane: pane,
            surface: evaluateLaunchSurface(
              pane: pane,
              process: info,
              paneIsLive: true,
            ),
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _panes = candidates;
        _paneId ??= candidates
            .where((c) => c.surface is CanLaunch)
            .map((c) => c.pane.paneId)
            .firstOrNull;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _failure = LaunchFailure.from(e));
    }
  }

  Future<void> _create() async {
    final client = _owner;
    if (client == null || _busy) return;

    setState(() {
      _busy = true;
      _failure = null;
      _creating = true;
    });

    try {
      final cwd = _directory.text.trim();
      final label = _name.text.trim().isEmpty ? 'agent' : _name.text.trim();

      // The pane path starts in a shell that already exists, so there is
      // nothing to create — which also means there is nothing to clean up if
      // the agent refuses to start.
      if (_paneMode) {
        final paneId = _paneId;
        if (paneId == null) throw const _LaunchException(LaunchProblem.noPane);
        setState(() => _creating = false);
        await AgentLauncher(client).startWhenReady(
          paneId: paneId,
          name: label,
          kind: _kind ?? '',
        );
        if (!mounted) return;
        ref.invalidate(navTreeProvider);
        await Navigator.of(context).pushReplacement(
          CupertinoPageRoute<void>(
            builder: (_) => TerminalPage(paneId: paneId, title: label),
          ),
        );
        return;
      }

      final created = _useWorktree
          ? await client.worktreeCreate(
              cwd: cwd.isEmpty ? null : cwd,
              branch: _branch.text.trim().isEmpty ? null : _branch.text.trim(),
              label: label,
            )
          : await client.workspaceCreate(
              cwd: cwd.isEmpty ? null : cwd,
              label: label,
            );

      final paneId = created.paneId;
      if (paneId == null) {
        // The daemon answered without a root pane, so there is nowhere to put
        // an agent. Saying so beats sending an agent.start at an empty string.
        throw const _LaunchException(LaunchProblem.noPane);
      }

      setState(() => _creating = false);

      // WAITS for the pane's shell to take the foreground before starting.
      //
      // This is not defensive coding: against a live daemon, create-then-start
      // fails with `agent_pane_busy`, and the daemon's own `timeout_ms` does
      // not help because the refusal is immediate. See [AgentLauncher].
      await AgentLauncher(client).startWhenReady(
        paneId: paneId,
        name: label,
        kind: _kind ?? '',
      );

      if (!mounted) return;
      ref.invalidate(navTreeProvider);
      await Navigator.of(context).pushReplacement(
        CupertinoPageRoute<void>(
          builder: (_) => TerminalPage(paneId: paneId, title: label),
        ),
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _creating = false;
          _failure = LaunchFailure.from(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(connectionProvider);
    final client = status.value is Online ? (status.value! as Online).client : null;

    if (client != null) {
      // Not awaited: the form renders immediately with what it knows, and fills
      // in as the daemon answers. A blank form that becomes usable beats a
      // spinner that hides the fact that a question is coming.
      unawaited(_load(client));
    }

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        // A form: the bar floats, the list keeps the full height and insets
        // itself, so the first group can still scroll up under the circles.
        obstructs: false,
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          l10n.launchTitle,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
      ),
      child: Builder(
        builder: (context) {
          final insets = MediaQuery.paddingOf(context);
          return ListView(
            padding: EdgeInsets.only(
              top: insets.top,
              bottom: insets.bottom + Space.xxl,
            ),
            children: [
              const SizedBox(height: Space.sm),
            SettingsGroup(
              title: l10n.launchMode,
              rows: [
                SettingsSwitchRow(
                  label: l10n.launchModePane,
                  note: l10n.launchModePaneNote,
                  value: _paneMode,
                  onChanged: (v) {
                    setState(() => _paneMode = v);
                    if (v) unawaited(_loadPanes());
                  },
                ),
              ],
            ),
            if (_paneMode)
              SettingsGroup(
                title: l10n.launchPickPane,
                rows: [
                  Padding(
                    padding: const EdgeInsets.all(Space.md),
                    child: _PaneChoices(
                      candidates: _panes,
                      selected: _paneId,
                      colors: colors,
                      l10n: l10n,
                      onPick: (id) => setState(() => _paneId = id),
                    ),
                  ),
                ],
              )
            else ...[
            SettingsGroup(
              title: l10n.launchWhere,
              rows: [
                SettingsRow(
                  label: l10n.launchDirectory,
                  note: l10n.launchDirectoryNote,
                  expandTrailing: true,
                  trailing: CupertinoTextField(
                    controller: _directory,
                    placeholder: '/Users/you/repo',
                    padding: const EdgeInsets.symmetric(vertical: Space.sm),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _probeRepository(client),
                    style: _fieldStyle(colors.text),
                    placeholderStyle: _fieldStyle(colors.textFaint),
                    decoration: null,
                  ),
                ),
                if (_repository != null)
                  SettingsSwitchRow(
                    label: l10n.launchWorktree,
                    note: l10n.launchWorktreeNote,
                    value: _useWorktree,
                    onChanged: (v) => setState(() => _useWorktree = v),
                  ),
                if (_repository != null && _useWorktree)
                  SettingsRow(
                    label: l10n.launchBranch,
                    note: l10n.launchBranchNote,
                    expandTrailing: true,
                    trailing: CupertinoTextField(
                      controller: _branch,
                      placeholder: 'fix/login',
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      style: _fieldStyle(colors.text),
                      placeholderStyle: _fieldStyle(colors.textFaint),
                      decoration: null,
                    ),
                  ),
              ],
            ),
            if (_repository == null && _directory.text.trim().isNotEmpty)
              SettingsNote(text: l10n.launchNotARepo),
            ],
            SettingsGroup(
              title: l10n.launchAgent,
              rows: [
                Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: _KindGrid(
                    integrations: _integrations,
                    selected: _kind,
                    colors: colors,
                    l10n: l10n,
                    onPick: (target) => setState(() {
                      final previous = suggestAgentName(
                        kind: _kind ?? '',
                        taken: _existingNames(),
                      );
                      _kind = target;
                      // Keep the name in step with the kind, UNLESS the user
                      // has already made it their own. Overwriting a typed name
                      // would silently undo a deliberate choice.
                      if (_name.text == previous) {
                        _name.text = suggestAgentName(
                          kind: target,
                          taken: _existingNames(),
                        );
                      }
                    }),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: l10n.launchName,
              rows: [
                SettingsRow(
                  label: l10n.launchNameLabel,
                  note: l10n.launchNameNote,
                  expandTrailing: true,
                  trailing: CupertinoTextField(
                    controller: _name,
                    placeholder: 'agent',
                    padding: const EdgeInsets.symmetric(vertical: Space.sm),
                    style: _fieldStyle(colors.text),
                    placeholderStyle: _fieldStyle(colors.textFaint),
                    decoration: null,
                  ),
                ),
              ],
            ),
            // THE FAILURE BELONGS NEXT TO THE BUTTON, not at the top of the
            // form. This list scrolls, and on a phone the button is below the
            // fold while the top is not visible — so a note up there would mean
            // the user taps "create", sees nothing happen, and taps again.
            if (_failure != null)
              SettingsNote(text: _failure!.message(l10n), isError: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.lg,
                Space.lg,
                0,
              ),
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: _busy ? null : _create,
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: Space.md),
                  decoration: BoxDecoration(
                    color: _busy ? colors.surfaceRaised : colors.accent,
                    borderRadius: BorderRadius.circular(Radii.uniform),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_busy) ...[
                        CupertinoActivityIndicator(
                          radius: 7,
                          color: colors.textDim,
                        ),
                        const SizedBox(width: Space.sm),
                      ],
                      Text(
                        _creating ? l10n.launchCreating : l10n.launchGo,
                        style: TextStyle(
                          color: _busy ? colors.textDim : colors.ground,
                          fontSize: TextSize.strong,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SettingsNote(text: l10n.launchFooter),
          ],
          );
        },
      ),
    );
  }

  /// Names already in use, so the suggestion is actually free.
  ///
  /// Read (not watched): this only matters at the moment a suggestion is made,
  /// and watching would rebuild the whole form on every board event.
  List<String> _existingNames() =>
      ref.read(boardProvider).value?.rows.map((r) => r.title).toList() ??
      const [];

  TextStyle _fieldStyle(Color color) => TextStyle(
        color: color,
        fontSize: TextSize.body,
        fontFamily: HerdrFonts.mono,
        fontFamilyFallback: HerdrFonts.monoFallback,
      );
}

/// One pane, and what the domain decided about it.
class _PaneCandidate {
  const _PaneCandidate({required this.pane, required this.surface});

  final PaneInfo pane;
  final LaunchSurface surface;

  bool get canLaunch => surface is CanLaunch;
}

/// The panes, with the unusable ones still visible.
///
/// Shown rather than filtered out on purpose: a list that silently omits the
/// pane the user is staring at is a list that looks broken. Each unusable one
/// carries its REASON, which is the whole point of evaluating the surface on
/// the client instead of relaying the daemon's refusal.
class _PaneChoices extends StatelessWidget {
  const _PaneChoices({
    required this.candidates,
    required this.selected,
    required this.colors,
    required this.l10n,
    required this.onPick,
  });

  final List<_PaneCandidate>? candidates;
  final String? selected;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final list = candidates;
    if (list == null) {
      return Text(
        l10n.launchLoadingPanes,
        style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
      );
    }
    if (list.every((c) => !c.canLaunch)) {
      return Text(
        l10n.launchNoLaunchablePanes,
        style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in list)
          GestureDetector(
            onTap: c.canLaunch ? () => onPick(c.pane.paneId) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              child: Row(
                children: [
                  Icon(
                    c.canLaunch && c.pane.paneId == selected
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                    size: 18,
                    color: c.canLaunch
                        ? (c.pane.paneId == selected
                            ? colors.accent
                            : colors.textFaint)
                        : colors.textFaint,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.pane.displayName,
                          style: TextStyle(
                            color: c.canLaunch ? colors.text : colors.textFaint,
                            fontSize: TextSize.note,
                          ),
                        ),
                        Text(
                          _reason(c, l10n),
                          style: TextStyle(
                            color: colors.textFaint,
                            fontSize: TextSize.meta,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _reason(_PaneCandidate c, AppLocalizations l10n) => switch (c.surface) {
        CanLaunch() => c.pane.paneId,
        CannotLaunch(:final reason, :final holder) => switch (reason) {
            LaunchBlock.alreadyAgent => l10n.launchBlockedAlready(holder ?? ''),
            LaunchBlock.busy => l10n.launchBlockedBusy(holder ?? ''),
            LaunchBlock.unknown => l10n.launchBlockedUnknown,
            LaunchBlock.gone => l10n.launchBlockedGone,
          },
      };
}

/// The agent kinds, as a wrapping grid of chips.
///
/// Tapping an unavailable one does nothing and SAYS why: a greyed chip with no
/// explanation is the kind of dead control that makes an app feel broken.
class _KindGrid extends StatelessWidget {
  const _KindGrid({
    required this.integrations,
    required this.selected,
    required this.colors,
    required this.l10n,
    required this.onPick,
  });

  final List<AgentIntegration>? integrations;
  final String? selected;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final list = integrations;
    if (list == null) {
      return Text(
        l10n.launchLoadingAgents,
        style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
      );
    }
    if (list.isEmpty) {
      return Text(
        l10n.launchNoAgents,
        style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final integration in list)
              _KindChip(
                integration: integration,
                isSelected: integration.target == selected,
                colors: colors,
                onTap: integration.available
                    ? () => onPick(integration.target)
                    : null,
              ),
          ],
        ),
        // One line explaining the greyed ones, once, instead of per chip.
        if (list.any((i) => !i.available))
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
              l10n.launchUnavailableNote,
              style: TextStyle(color: colors.textFaint, fontSize: TextSize.meta),
            ),
          ),
      ],
    );
  }
}

/// One agent, as a chip carrying its identity.
///
/// THE ICON IS THE POINT OF THIS WIDGET. This grid is "pick one of seventeen
/// agents", which is the one screen in the app where recognising a brand is the
/// whole task — and it was a wall of identically styled text. A board is a list
/// you scan, so a uniform chip is right there; a picker is a set you choose
/// from, and that is where colour plus a mark earns its space.
///
/// WHY THE SELECTED STATE IS A RING RATHER THAN A FILL. It used to be a solid
/// `accent` pill, which worked while the chip held nothing but text. It does
/// not survive an identity chip inside it: `accent` is violet and so is the
/// catch-all identity, so a selected `omp` chip would carry a violet chip on a
/// violet ground. A ring says "this one is chosen" without owning the fill, and
/// it is already this app's idiom for active — `cardEdgeActive` draws exactly
/// this on a board card.
class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.integration,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  final AgentIntegration integration;
  final bool isSelected;
  final HerdrColors colors;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = enabled ? colors.text : colors.textFaint;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.md, Space.xs),
        decoration: BoxDecoration(
          color: isSelected
              ? colors.accent.withValues(alpha: 0.16)
              : colors.surfaceRaised,
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(
            color: isSelected ? colors.accent : colors.hairlineQuiet,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Dimmed rather than hidden when herdr reports the agent as
            // unavailable: the row is still the agent it says it is, and the
            // footnote under the grid explains the grey in one line.
            Opacity(
              opacity: enabled ? 1 : 0.4,
              child: AgentIcon(agent: integration.target, size: 16),
            ),
            const SizedBox(width: Space.sm),
            Text(
              integration.displayName,
              style: TextStyle(color: fg, fontSize: TextSize.note),
            ),
          ],
        ),
      ),
    );
  }
}

/// What went wrong, in terms the user can act on.
///
/// One class per failure the daemon can actually produce, because they call for
/// different next steps: a path that is not a repository means "turn the
/// worktree switch off", a pane that never became ready means "try again", and
/// an unparseable error is shown verbatim rather than smoothed over.
enum LaunchProblem {
  notARepository,
  agentNotReady,
  nameTaken,
  noPane,
  other,
}

class LaunchFailure {
  const LaunchFailure(this.problem, {this.detail});

  /// Reads the daemon's error code.
  factory LaunchFailure.from(Object error) {
    if (error is _LaunchException) return LaunchFailure(error.problem);
    if (error is AgentLaunchException) {
      return LaunchFailure(
        error.reason == LaunchBlock.gone
            ? LaunchProblem.noPane
            : LaunchProblem.agentNotReady,
      );
    }
    if (error is HerdrApiException) {
      return switch (error.code) {
        'not_git_worktree' => const LaunchFailure(LaunchProblem.notARepository),
        // Both codes mean "the pane cannot take an agent yet", and both are
        // what a live daemon actually answers right after a workspace is made.
        'agent_not_ready' || 'agent_pane_busy' =>
          const LaunchFailure(LaunchProblem.agentNotReady),
        _ => LaunchFailure(LaunchProblem.other, detail: error.message),
      };
    }
    return LaunchFailure(LaunchProblem.other, detail: '$error');
  }

  final LaunchProblem problem;
  final String? detail;

  String message(AppLocalizations l10n) => switch (problem) {
        LaunchProblem.notARepository => l10n.launchFailedRepo,
        LaunchProblem.agentNotReady => l10n.launchFailedNotReady,
        LaunchProblem.nameTaken => l10n.launchFailedName,
        LaunchProblem.noPane => l10n.launchFailedNoPane,
        // The daemon's own words rather than a paraphrase: when we do not know
        // what happened, quoting it is the only honest option.
        LaunchProblem.other => detail == null
            ? l10n.launchFailedGeneric
            : '${l10n.launchFailedGeneric}: $detail',
      };
}

class _LaunchException implements Exception {
  const _LaunchException(this.problem);

  final LaunchProblem problem;
}
