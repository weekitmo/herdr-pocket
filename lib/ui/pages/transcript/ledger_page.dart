import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/ledger.dart';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/data/transcripts/transcript_locator.dart';
import 'package:herdr_pocket/domain/transcript/ledger_stats.dart';
import 'package:herdr_pocket/domain/transcript/ledger_text.dart';
import 'package:herdr_pocket/domain/transcript/session_ledger.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/loading_block.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// What an agent session actually did: the turns, the tools, the tokens.
///
/// WHY IT EXISTS: the terminal shows what the agent wrote, and a tool call that
/// took forty seconds and failed looks like one line among two hundred. This
/// reads the agent's own record instead — the file it writes next to the work —
/// and answers the questions a phone is good at: what did it run, how long did
/// that take, how often did it fail, what did it cost.
///
/// WHY IT IS NOT THE TERMINAL REPLACED: every number here is derived from a
/// file the agent keeps for itself, in a format nobody promised us. It is a
/// second lens on the same pane (the terminal stays one tap away, and the
/// screen says when it could not read the record rather than showing an empty
/// one). `TODO.md` T1-1 builds the chat view on the same parser.
class LedgerPage extends ConsumerStatefulWidget {
  const LedgerPage({
    required this.agentId,
    required this.cwd,
    this.paneId,
    this.pid,
    super.key,
  });

  /// The agent as `agent.list` names it — `pi`, `codex`.
  final String agentId;

  /// The pane's working directory, which is what the file is found by.
  final String cwd;

  /// Kept for the header and for a future "open the terminal" action.
  final String? paneId;

  /// The agent's process, when the caller already knows it. Its open file is
  /// better evidence than the newest file in a directory.
  final int? pid;

  @override
  ConsumerState<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends ConsumerState<LedgerPage> {
  _LedgerView _view = const _LedgerLoading();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _view = const _LedgerLoading());
    final loader = ref.read(ledgerLoaderProvider);
    if (loader == null) {
      if (mounted) setState(() => _view = const _LedgerUnreachable());
      return;
    }

    LocatedTranscript located;
    try {
      located = await loader(
        agentId: widget.agentId,
        cwd: widget.cwd,
        pid: widget.pid,
      );
    } on Object {
      // A last-resort net, not a classification. It used to fall through to
      // "no session found", which is a different claim from "we could not read
      // it" — and that is exactly how a crash in the parser reached a phone as
      // an empty directory. Parsing never throws by contract; when something
      // else does, the screen says so.
      located = const UnreadableTranscript();
    }

    if (!mounted) return;
    setState(() {
      _view = switch (located) {
        UnsupportedAgent() => const _LedgerUnreadable(),
        UnreadableTranscript() => const _LedgerUnreadable(),
        NoTranscript() => const _LedgerEmpty(),
        FoundTranscript(:final parse, :final location, :final truncated) =>
          switch (parse) {
            UnusableTranscript() => const _LedgerUnreadable(),
            ParsedTranscript(:final session) => _LedgerLoaded(
              session: session,
              location: location,
              truncated: truncated,
            ),
          },
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        // The list keeps the full height and makes room for the bar with its own
        // top padding, so a long turn slides under the circles.
        obstructs: false,
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          widget.agentId.isEmpty ? l10n.ledgerTitle : widget.agentId,
          style: const TextStyle(fontSize: TextSize.strong),
        ),
        actions: [
          HerdrBarButton(
            label: l10n.ledgerReload,
            onPressed: () => unawaited(_load()),
            child: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ),
      child: switch (_view) {
        _LedgerLoading() => Padding(
          padding: const EdgeInsets.only(top: Space.xxxl * 2),
          child: LoadingBlock(
            title: l10n.ledgerLoading,
            target: widget.cwd,
            colors: colors,
          ),
        ),
        _LedgerUnreachable() => _Message(
          icon: CupertinoIcons.wifi_slash,
          title: l10n.ledgerUnreachable,
          body: widget.cwd,
          colors: colors,
        ),
        _LedgerUnreadable() => _Message(
          icon: CupertinoIcons.doc_text,
          title: l10n.ledgerUnreadable,
          body: widget.agentId,
          colors: colors,
        ),
        _LedgerEmpty() => _Message(
          icon: CupertinoIcons.tray,
          title: l10n.ledgerEmpty,
          body: widget.cwd,
          colors: colors,
        ),
        _LedgerLoaded(
          :final session,
          :final location,
          :final truncated,
        ) =>
          _LedgerBody(
            session: session,
            location: location,
            truncated: truncated,
            onRefresh: _load,
          ),
      },
    );
  }
}

// --- The loaded screen -----------------------------------------------------

class _LedgerBody extends StatelessWidget {
  const _LedgerBody({
    required this.session,
    required this.location,
    required this.truncated,
    required this.onRefresh,
  });

  final LedgerSession session;
  final TranscriptLocation location;
  final bool truncated;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final summary = summarize(
      session.turns,
      reported: session.reportedUsage,
    );
    final tools = toolStats(session.turns);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      // A cut-off ledger is a ledger that scrolls under the bar, which is what
      // the obstructs: false above is for.
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + Space.xxxl,
        left: Space.lg,
        right: Space.lg,
        bottom: Space.xxxl,
      ),
      children: [
        _SummaryCard(
          session: session,
          summary: summary,
          location: location,
          truncated: truncated,
          colors: colors,
        ),
        if (tools.isNotEmpty) ...[
          const SizedBox(height: Space.sm),
          _ToolTable(rows: tools, colors: colors),
        ],
        const SizedBox(height: Space.sm),
        if (session.turns.isEmpty)
          // A session with nothing in it is common — an agent that opens one
          // every time it runs leaves these behind — and an empty list says
          // "loading" or "broken" rather than "there is nothing yet".
          Padding(
            padding: const EdgeInsets.only(top: Space.xxl),
            child: Text(
              l10n.ledgerNoTurns,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: TextSize.note, color: colors.textFaint),
            ),
          )
        else
          for (final turn in session.turns)
            _TurnCard(turn: turn, colors: colors, l10n: l10n),
      ],
    );
  }
}

/// The session at a glance: what model, how much work, how much it read.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.session,
    required this.summary,
    required this.location,
    required this.truncated,
    required this.colors,
  });

  final LedgerSession session;
  final LedgerSummary summary;
  final TranscriptLocation location;
  final bool truncated;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final usage = summary.usage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          rows: [
            if (session.model case final model?)
              _Fact(
                label: l10n.ledgerModel,
                value: model,
                mono: true,
                colors: colors,
              ),
            if (session.cwd case final cwd?)
              _Fact(
                label: l10n.ledgerDirectory,
                value: cwd,
                mono: true,
                colors: colors,
              ),
            _Fact(
              label: l10n.ledgerTurns,
              value: '${summary.turns}',
              colors: colors,
            ),
            _Fact(
              label: l10n.ledgerToolCalls,
              value: [
                l10n.ledgerCallsCount(summary.toolCalls),
                if (summary.toolFailures > 0)
                  l10n.ledgerFailuresCount(summary.toolFailures),
                if (summary.openCalls > 0)
                  l10n.ledgerOpenCount(summary.openCalls),
              ].join(' · '),
              colors: colors,
            ),
            if (summary.toolBusy > Duration.zero)
              _Fact(
                label: l10n.ledgerToolTime,
                value: formatDuration(summary.toolBusy),
                mono: true,
                colors: colors,
              ),
            if (usage != null)
              _Fact(
                label: l10n.ledgerTokens,
                value: [
                  if (usage.input case final v?) '${compactCount(v)} ${l10n.ledgerTokenIn}',
                  if (usage.output case final v?) '${compactCount(v)} ${l10n.ledgerTokenOut}',
                  if (usage.cacheRead case final v?) '${compactCount(v)} ${l10n.ledgerTokenCache}',
                ].join(' · '),
                mono: true,
                colors: colors,
              ),
            if (summary.contextWindow case final window?)
              _Fact(
                label: l10n.ledgerContextWindow,
                value: compactCount(window),
                mono: true,
                colors: colors,
              ),
            if (usage?.cost case final cost?)
              _Fact(
                label: l10n.ledgerCost,
                value: '\$${cost.toStringAsFixed(2)}',
                mono: true,
                colors: colors,
              ),
          ],
        ),
        // What the reader has to know about this reading, in one line, under
        // the card rather than inside it: these are notes about the record, not
        // facts from it.
        if (_notes(l10n).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
              top: Space.sm,
              left: Space.xs,
              right: Space.xs,
            ),
            child: Text(
              _notes(l10n).join(' · '),
              style: TextStyle(
                fontSize: TextSize.micro,
                color: colors.textFaint,
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }

  List<String> _notes(AppLocalizations l10n) => [
    if (location.isGuess) l10n.ledgerGuessed,
    if (truncated) l10n.ledgerTailOnly,
    if (session.skippedLines > 0) l10n.ledgerSkipped(session.skippedLines),
  ];
}

/// One label/value row inside a summary card.
///
/// The value is the flexible half: a path or a model name is long, and a card
/// that wraps its label to give a path room is harder to scan than one that
/// lets the path be cut.
class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    required this.colors,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: TextSize.body, color: colors.textDim),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TextSize.note,
                color: colors.text,
                fontFamily: mono ? HerdrFonts.mono : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every tool the session ran, busiest first.
class _ToolTable extends StatelessWidget {
  const _ToolTable({required this.rows, required this.colors});

  final List<ToolStat> rows;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: Space.lg,
            right: Space.lg,
            bottom: Space.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.ledgerTools,
                  style: TextStyle(
                    fontSize: TextSize.meta,
                    color: colors.textFaint,
                  ),
                ),
              ),
              _Column(l10n.ledgerFailuresShort, colors: colors, narrow: true),
              _Column(l10n.ledgerToolCount, colors: colors),
              _Column(l10n.ledgerToolMedian, colors: colors),
              _Column(l10n.ledgerToolTimeShort, colors: colors, wide: true),
            ],
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(Radii.uniform),
            boxShadow: Elevation.card(colors),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: Space.lg),
                    child: SizedBox(
                      height: 1,
                      width: double.infinity,
                      child: ColoredBox(color: colors.hairlineQuiet),
                    ),
                  ),
                _ToolRow(row: rows[i], colors: colors),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Column extends StatelessWidget {
  const _Column(
    this.text, {
    required this.colors,
    this.wide = false,
    this.narrow = false,
    this.valueColor,
  });

  final String text;
  final HerdrColors colors;
  final bool wide;
  final bool narrow;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: wide ? 56 : (narrow ? 26 : 40),
      child: Text(
        text,
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: TextSize.micro,
          color: valueColor ?? colors.textFaint,
        ),
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.row, required this.colors});

  final ToolStat row;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TextSize.note,
                fontFamily: HerdrFonts.mono,
                color: colors.text,
              ),
            ),
          ),
          // Its own column, with its own header. The first version put the
          // failure count in front of the call count, which read as a fourth
          // number that had drifted one column to the left — the table looked
          // broken precisely on the rows that mattered.
          _Column(
            row.failures == 0 ? '' : '${row.failures}',
            colors: colors,
            narrow: true,
            valueColor: colors.died,
          ),
          _Column(
            '${row.count}',
            colors: colors,
          ),
          _Column(
            row.measured == 0 ? '—' : formatDuration(row.median),
            colors: colors,
          ),
          _Column(
            row.measured == 0 ? '—' : formatDuration(row.total),
            colors: colors,
            wide: true,
          ),
        ],
      ),
    );
  }
}

/// One turn: what was asked, and everything the agent did about it.
class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.turn, required this.colors, required this.l10n});

  final LedgerTurn turn;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: Space.lg,
              right: Space.lg,
              bottom: Space.sm,
            ),
            child: Row(
              children: [
                Text(
                  l10n.ledgerTurnLabel(turn.index),
                  style: TextStyle(
                    fontSize: TextSize.meta,
                    color: colors.textFaint,
                  ),
                ),
                if (turn.startedAt case final at?) ...[
                  const SizedBox(width: Space.sm),
                  Text(
                    formatClock(at),
                    style: TextStyle(
                      fontSize: TextSize.meta,
                      fontFamily: HerdrFonts.mono,
                      color: colors.textFaint,
                    ),
                  ),
                ],
                const Spacer(),
                // Flexible, because this line shares a row with the clock and
                // a long turn (a million-token context) is wider than a phone.
                // The session card above carries the full breakdown including
                // the cache; the per-turn line stays short enough to fit.
                if (turn.usage case final usage? when !usage.isEmpty)
                  Flexible(
                    child: Text(
                      _usageLine(usage, l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: TextSize.micro,
                        fontFamily: HerdrFonts.mono,
                        color: colors.textFaint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              boxShadow: Elevation.card(colors),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (turn.prompt case final prompt?)
                  _ExpandableText(
                    text: prompt,
                    label: l10n.ledgerYou,
                    colors: colors,
                    color: colors.text,
                    collapsedLines: 4,
                  ),
                for (final item in turn.items)
                  _ItemBlock(item: item, colors: colors, l10n: l10n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `↳ 该回合 N token` — the figure belongs to the inference, not to any one
  /// tool call inside it, which is why it sits on the turn and nowhere else.
  static String _usageLine(TokenUsage usage, AppLocalizations l10n) {
    final parts = <String>[
      if (usage.input case final v?) '${compactCount(v)} ${l10n.ledgerTokenIn}',
      if (usage.output case final v?) '${compactCount(v)} ${l10n.ledgerTokenOut}',
    ];
    return parts.join(' · ');
  }
}

/// One entry in a turn, drawn according to what it is.
class _ItemBlock extends StatelessWidget {
  const _ItemBlock({
    required this.item,
    required this.colors,
    required this.l10n,
  });

  final LedgerItem item;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      // The assistant's words get a label for the same reason the prompt has
      // one: without it the answer reads as more of the question. The dsh
      // transcripts made this obvious — there the two sit in one card with
      // nothing between them.
      LedgerText(:final text) => _ExpandableText(
        text: text,
        label: l10n.ledgerAssistant,
        colors: colors,
        color: colors.text,
      ),
      LedgerNote(:final text) => _ExpandableText(
        text: text,
        colors: colors,
        color: colors.textDim,
      ),
      LedgerThinking(:final text) => _Collapsible(
        colors: colors,
        label: l10n.ledgerThinking,
        detail: l10n.ledgerChars(text.length),
        body: text,
        shaded: true,
        icon: CupertinoIcons.eye_slash,
      ),
      final LedgerToolCall call => _ToolCallBlock(
        call: call,
        colors: colors,
        l10n: l10n,
      ),
    };
  }
}

/// A block of text that can be read in full.
///
/// The ledger's first version capped messages at six lines with an ellipsis and
/// no way past it, which on a real dsh turn meant the answer was cut off after
/// its first heading — the screen looked like the agent had said nothing more.
/// Whether the cap is even reached is measured rather than guessed: a
/// `TextPainter` knows, and a character count does not.
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({
    required this.text,
    required this.colors,
    required this.color,
    this.label,
    this.collapsedLines = 6,
  });

  final String text;
  final String? label;
  final HerdrColors colors;
  final Color color;
  final int collapsedLines;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: TextSize.note,
      color: widget.color,
      height: 1.35,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.collapsedLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final clipped = painter.didExceedMaxLines;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: clipped ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.sm,
              Space.lg,
              Space.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.label case final label?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: TextSize.micro,
                        color: widget.colors.textFaint,
                      ),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        widget.text,
                        maxLines: _open ? null : widget.collapsedLines,
                        overflow: _open
                            ? TextOverflow.clip
                            : TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    if (clipped)
                      Padding(
                        padding: const EdgeInsets.only(left: Space.sm),
                        child: Icon(
                          _open
                              ? CupertinoIcons.chevron_up
                              : CupertinoIcons.chevron_down,
                          size: 12,
                          color: widget.colors.textFaint,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A tool call: one line, expansions behind a tap.
///
/// The row is the part a person scans — name, how long, whether it failed, the
/// first few characters of what it was asked — and the arguments and output are
/// behind a tap because they are hundreds of lines long and identical in shape
/// from one call to the next.
class _ToolCallBlock extends StatelessWidget {
  const _ToolCallBlock({
    required this.call,
    required this.colors,
    required this.l10n,
  });

  final LedgerToolCall call;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final failed = call.isError == true;
    final preview = oneLinePreview(call.arguments);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
      child: _Collapsible(
        label: call.name,
        icon: failed
            ? CupertinoIcons.exclamationmark_triangle
            : CupertinoIcons.wrench,
        labelColor: failed ? colors.died : colors.text,
        detail: [
          if (preview.isNotEmpty) preview,
        ].join(' '),
        trailing: call.duration == null
            ? l10n.ledgerNoResult
            : formatDuration(call.duration!),
        trailingColor: failed ? colors.died : colors.textDim,
        body: [
          if (call.arguments.isNotEmpty) call.arguments,
          ?call.result,
        ].join('\n\n'),
        colors: colors,
      ),
    );
  }
}

/// A row that expands on tap.
///
/// The expanded body is a monospace block inside a scroll view rather than a
/// page of its own: reading a tool's output while keeping the rest of the turn
/// on screen is the whole reason for expanding it here.
class _Collapsible extends StatefulWidget {
  const _Collapsible({
    required this.label,
    required this.detail,
    required this.body,
    required this.colors,
    this.icon,
    this.trailing,
    this.trailingColor,
    this.labelColor,
    this.shaded = false,
  });

  final String label;
  final String detail;
  final String body;
  final HerdrColors colors;
  final IconData? icon;
  final String? trailing;
  final Color? trailingColor;
  final Color? labelColor;
  final bool shaded;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.body.isEmpty ? null : () => setState(() => _open = !_open),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.shaded ? Space.md : 0,
              vertical: Space.sm,
            ),
            child: Row(
              children: [
                if (widget.icon case final icon)
                  Icon(
                    icon,
                    size: 13,
                    color: widget.labelColor ?? colors.textDim,
                  ),
                if (widget.icon != null) const SizedBox(width: Space.sm),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: TextSize.note,
                    fontFamily: HerdrFonts.mono,
                    color: widget.labelColor ?? colors.text,
                  ),
                ),
                if (widget.detail.isNotEmpty) ...[
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      widget.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TextSize.micro,
                        fontFamily: HerdrFonts.mono,
                        color: colors.textFaint,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (widget.trailing case final trailing?) ...[
                  Text(
                    trailing,
                    style: TextStyle(
                      fontSize: TextSize.micro,
                      fontFamily: HerdrFonts.mono,
                      color: widget.trailingColor ?? colors.textFaint,
                    ),
                  ),
                  const SizedBox(width: Space.xs),
                ],
                if (widget.body.isNotEmpty)
                  Icon(
                    _open
                        ? CupertinoIcons.chevron_down
                        : CupertinoIcons.chevron_right,
                    size: 12,
                    color: colors.textFaint,
                  ),
              ],
            ),
          ),
          if (_open && widget.body.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: Space.sm),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: colors.groundDeep,
                borderRadius: BorderRadius.circular(Radii.uniform - 4),
              ),
              child: Text(
                trimResult(widget.body),
                style: TextStyle(
                  fontSize: TextSize.meta,
                  fontFamily: HerdrFonts.mono,
                  color: colors.textDim,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The states where there is nothing to show, each with its own reason.
///
/// They are separate classes rather than one sentence, because "the machine has
/// no session for this directory" and "this build cannot read that agent" call
/// for different next steps, and one vague message would fit neither.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.colors,
  });

  final IconData icon;
  final String title;
  final String body;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: colors.textFaint),
            const SizedBox(height: Space.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: TextSize.note, color: colors.textDim),
            ),
            const SizedBox(height: Space.sm),
            Text(
              body,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
                color: colors.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- View state ------------------------------------------------------------

sealed class _LedgerView {
  const _LedgerView();
}

class _LedgerLoading extends _LedgerView {
  const _LedgerLoading();
}

class _LedgerLoaded extends _LedgerView {
  const _LedgerLoaded({
    required this.session,
    required this.location,
    required this.truncated,
  });

  final LedgerSession session;
  final TranscriptLocation location;
  final bool truncated;
}

class _LedgerUnreachable extends _LedgerView {
  const _LedgerUnreachable();
}

class _LedgerUnreadable extends _LedgerView {
  const _LedgerUnreadable();
}

class _LedgerEmpty extends _LedgerView {
  const _LedgerEmpty();
}
