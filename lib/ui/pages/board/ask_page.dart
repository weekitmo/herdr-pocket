import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/agent_ask.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/agent/agent_question.dart';
import 'package:herdr_pocket/domain/agent/agent_reply.dart';
import 'package:herdr_pocket/domain/agent/reply_guard.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';

/// Answering an agent without going into its terminal.
///
/// WHY THIS EXISTS: the board can say "this agent needs you" but it cannot say
/// WHAT it wants, and that gap is the one thing a phone is genuinely better at
/// than a desktop — you are away from the machine, the agent is stuck, and the
/// answer is one tap.
///
/// WHY IT IS CAREFUL: pressing a key here is the most consequential thing the
/// app does, on the least trustworthy input there is — a screen someone read a
/// moment ago. So every send re-reads first, and the page is built so that the
/// honest outcome ("I could not tell what it is asking") is a first-class
/// result with a single useful action, not an error state.
class AskPage extends ConsumerStatefulWidget {
  const AskPage({required this.row, super.key});

  /// The board row as it was when this page was opened. It is the "before"
  /// snapshot the re-read is compared against.
  final AgentRow row;

  @override
  ConsumerState<AskPage> createState() => _AskPageState();
}

class _AskPageState extends ConsumerState<AskPage> {
  final _composer = TextEditingController();

  /// The client the cached read belongs to.
  HerdrClient? _owner;
  Future<AgentAsk>? _load;
  AskOutcome? _outcome;
  bool _busy = false;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  /// The read for [client], started at most once per client.
  ///
  /// Loading happens HERE rather than in `initState`, and that is not a style
  /// choice: the connection provider is asynchronous, so on the first frame
  /// there is no client yet. A page that captured "no client" at that instant
  /// would report a connection error on a perfectly good connection — which is
  /// exactly what the first version of this page did, caught by its own test.
  ///
  /// Client identity, not a boolean, decides whether the cached read is still
  /// valid: after a reconnect the old read belongs to a link that is gone.
  Future<AgentAsk> _futureFor(HerdrClient client) {
    if (!identical(_owner, client) || _load == null) {
      _owner = client;
      _outcome = null;
      _load = AskController(client).load(widget.row);
    }
    return _load!;
  }

  /// Re-reads the screen (the retry button, and after a failed connection).
  void _reread() {
    final client = _owner;
    if (client == null) {
      ref.invalidate(connectionProvider);
      return;
    }
    setState(() {
      _outcome = null;
      _load = AskController(client).load(widget.row);
    });
  }

  Future<void> _send(Future<AskOutcome> Function(AskController c) action) async {
    final client = _owner;
    if (client == null || _busy) return;

    setState(() => _busy = true);
    final outcome = await action(AskController(client));
    if (!mounted) return;

    setState(() {
      _busy = false;
      _outcome = outcome;
    });

    // The board is the thing that knows what happened next, so a successful
    // send refreshes it rather than reporting success on its own authority.
    if (outcome is AskAccepted) unawaited(ref.read(boardProvider.notifier).refresh());
  }

  void _openTerminal() {
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute<void>(
        builder: (_) => TerminalPage(
          paneId: widget.row.info.paneId,
          title: widget.row.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    final status = ref.watch(connectionProvider);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        // The bar obstructs: this page is a conversation plus a composer, and a
        // composer sliding under the buttons would put a control the user is
        // typing into behind the chrome.
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          widget.row.title,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
      ),
      child: SafeArea(
        child: switch (status.value) {
          // No client yet: a spinner while connecting, and an honest sentence
          // once we know there is nothing to connect to. Neither is an error —
          // the agent is still waiting either way.
          final Online online => FutureBuilder<AgentAsk>(
              future: _futureFor(online.client),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _Centered(
                    colors: colors,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CupertinoActivityIndicator(radius: 9),
                        const SizedBox(height: Space.md),
                        Text(
                          l10n.askLoading,
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: TextSize.note,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return _Centered(
                    colors: colors,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.askFailedTitle,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: TextSize.title,
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        Text(
                          '${snapshot.error}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: TextSize.note,
                          ),
                        ),
                        const SizedBox(height: Space.lg),
                        _Button(
                          label: l10n.askRetry,
                          colors: colors,
                          onTap: _reread,
                        ),
                        const SizedBox(height: Space.sm),
                        _Button(
                          label: l10n.askOpenTerminal,
                          colors: colors,
                          onTap: _openTerminal,
                        ),
                      ],
                    ),
                  );
                }

                return _body(context, snapshot.data!, colors, l10n);
              },
            ),
          _ => _Centered(
              colors: colors,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status.isLoading)
                    const CupertinoActivityIndicator(radius: 9)
                  else
                    Text(
                      l10n.askFailedTitle,
                      style: TextStyle(color: colors.text, fontSize: TextSize.title),
                    ),
                  const SizedBox(height: Space.lg),
                  _Button(
                    label: l10n.askRetry,
                    colors: colors,
                    onTap: _reread,
                  ),
                ],
              ),
            ),
        },
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AgentAsk ask,
    HerdrColors colors,
    AppLocalizations l10n,
  ) {
    final question = ask.question;
    final typedOnly = isPromptBlocked(
      inputPending: ask.row.info.inputPending,
      status: ask.row.status,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xxl),
      children: [
        if (_outcome != null) ...[
          _OutcomeBanner(outcome: _outcome!, colors: colors, l10n: l10n),
          const SizedBox(height: Space.lg),
        ],

        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.waiting,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              l10n.askTitle,
              style: TextStyle(color: colors.waiting, fontSize: TextSize.note),
            ),
          ],
        ),
        const SizedBox(height: Space.md),

        // The question, when we understood it. Missing is not an error: plenty
        // of prompts are not shaped like questions, and the raw screen below
        // still answers the user's actual question ("what does it want?").
        if (question.summary != null)
          _Card(
            colors: colors,
            child: Text(
              question.summary!,
              style: TextStyle(
                color: colors.text,
                fontSize: TextSize.body,
                height: 1.4,
              ),
            ),
          ),

        if (question.options.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          for (final option in question.options) ...[
            _OptionRow(
              option: option,
              colors: colors,
              enabled: !_busy,
              onTap: () => _send(
                (c) => c.answerOption(before: ask.row, option: option),
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
        ],

        if (question.confidence == QuestionConfidence.none) ...[
          const SizedBox(height: Space.sm),
          Text(
            l10n.askUnclearNote,
            style: TextStyle(color: colors.textDim, fontSize: TextSize.note, height: 1.4),
          ),
        ],

        if (ask.truncated) ...[
          const SizedBox(height: Space.sm),
          Text(
            l10n.askTruncatedNote,
            style: TextStyle(color: colors.textFaint, fontSize: TextSize.meta, height: 1.35),
          ),
        ],

        // Free text. Always available: it is the only way to answer a question
        // whose options we could not read.
        const SizedBox(height: Space.lg),
        _Composer(
          controller: _composer,
          colors: colors,
          l10n: l10n,
          typedOnly: typedOnly,
          enabled: !_busy,
          onSubmit: () {
            final text = _composer.text;
            unawaited(
              _send((c) => c.answerText(before: ask.row, text: text)).then((_) {
                if (mounted && _outcome is AskAccepted) _composer.clear();
              }),
            );
          },
        ),

        if (typedOnly) ...[
          const SizedBox(height: Space.sm),
          Text(
            l10n.askTypedNote,
            style: TextStyle(color: colors.textFaint, fontSize: TextSize.meta, height: 1.35),
          ),
        ],

        if (question.rawLines.isNotEmpty) ...[
          const SizedBox(height: Space.xl),
          Text(
            l10n.askItsScreen,
            style: TextStyle(color: colors.textDim, fontSize: TextSize.note),
          ),
          const SizedBox(height: Space.sm),
          _Card(
            colors: colors,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                question.rawLines.join('\n'),
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: TextSize.meta,
                  height: 1.35,
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
              ),
            ),
          ),
        ],

        const SizedBox(height: Space.xl),
        _Button(
          label: l10n.askOpenTerminal,
          colors: colors,
          onTap: _openTerminal,
        ),
        const SizedBox(height: Space.md),
        Text(
          l10n.askFooter,
          style: TextStyle(color: colors.textFaint, fontSize: TextSize.meta, height: 1.35),
        ),
      ],
    );
  }
}

/// One answer the agent offers.
///
/// The option the TUI has highlighted is drawn as the filled one, because that
/// is also the one a bare Enter would pick — showing it differently is the
/// cheapest way to make "what happens if I just press Enter" visible.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.colors,
    required this.enabled,
    required this.onTap,
  });

  final AgentOption option;
  final HerdrColors colors;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = option.isCursor;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: enabled ? onTap : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.md,
        ),
        decoration: BoxDecoration(
          color: primary ? colors.accent : colors.surface,
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(
            color: primary ? colors.accent : colors.hairline,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              alignment: Alignment.center,
              child: Text(
                option.key,
                style: TextStyle(
                  color: primary ? colors.ground : colors.textFaint,
                  fontSize: TextSize.note,
                ),
              ),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                option.label,
                style: TextStyle(
                  color: primary ? colors.ground : colors.text,
                  fontSize: TextSize.body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The free-text field, plus the send button whose LABEL states the truth about
/// what sending will do.
///
/// "Send" and "Type only" are different promises and the button says which one
/// it is making, because the consequence differs: one submits, one cannot.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.colors,
    required this.l10n,
    required this.typedOnly,
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final bool typedOnly;
  final bool enabled;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(Radii.uniform),
            border: Border.all(color: colors.hairline),
          ),
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: CupertinoTextField(
            controller: controller,
            enabled: enabled,
            maxLines: 4,
            minLines: 1,
            padding: const EdgeInsets.symmetric(vertical: Space.md),
            placeholder: l10n.askSend,
            style: TextStyle(
              color: colors.text,
              fontSize: TextSize.body,
              fontFamily: HerdrFonts.mono,
              fontFamilyFallback: HerdrFonts.monoFallback,
            ),
            placeholderStyle: TextStyle(
              color: colors.textFaint,
              fontSize: TextSize.body,
              fontFamily: HerdrFonts.mono,
              fontFamilyFallback: HerdrFonts.monoFallback,
            ),
            decoration: null,
          ),
        ),
        const SizedBox(height: Space.sm),
        _Button(
          label: typedOnly ? l10n.askSendTyped : l10n.askSend,
          colors: colors,
          filled: true,
          onTap: enabled ? onSubmit : null,
        ),
      ],
    );
  }
}

/// A flat button in this app's own idiom.
class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.colors,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final HerdrColors colors;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        decoration: BoxDecoration(
          color: filled ? colors.accent : colors.surface,
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(color: filled ? colors.accent : colors.hairline),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: filled ? colors.ground : colors.text,
            fontSize: TextSize.strong,
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.colors, required this.child});

  final HerdrColors colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: Border.all(color: colors.hairlineQuiet),
      ),
      child: child,
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.colors, required this.child});

  final HerdrColors colors;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Center(child: child),
      );
}

/// What happened, in the daemon's own terms.
///
/// Every branch here is a different TRUTH, and none of them says "sent" unless
/// the daemon took the input: a stale reading, a refusal and a daemon error are
/// three separate sentences because they call for three different actions.
class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({
    required this.outcome,
    required this.colors,
    required this.l10n,
  });

  final AskOutcome outcome;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final (text, tone, isError) = switch (outcome) {
      AskAccepted() => (l10n.askSent, colors.done, false),
      AskStale(safety: ReplySafety.gone) => (l10n.askStaleGone, colors.died, true),
      AskStale() => (l10n.askStaleChanged, colors.waiting, true),
      AskRefused(reason: ReplyRefusal.empty) => (l10n.askRefusedEmpty, colors.waiting, true),
      AskRefused() => (l10n.askRefusedMultiline, colors.waiting, true),
      AskFailed(code: 'agent_blocked') => (l10n.askFailedBlocked, colors.waiting, true),
      AskFailed() => (l10n.askSendFailed, colors.died, true),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(color: tone, fontSize: TextSize.body),
          ),
          if (!isError) ...[
            const SizedBox(height: Space.xs),
            Text(
              l10n.askSentNote,
              style: TextStyle(color: colors.textDim, fontSize: TextSize.meta, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}
