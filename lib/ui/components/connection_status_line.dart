import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// What to call the connection right now.
///
/// ONE FUNCTION, so the board, the machines list and the navigation bar cannot
/// describe the same dial three different ways. It is a function rather than a
/// widget because the three places want different shapes around the same
/// words: a strip at the top of the board, a status line inside a row, a badge
/// in a title bar.
///
/// ORDER OF PRECEDENCE, and it matters:
///
///   * `loading` beats the last known status. A provider that is rebuilding is
///     dialling, and the stale value it retains is the *previous* answer —
///     showing "connection failed" while a retry is already in flight is how a
///     working retry looks broken.
///   * the stage inside [Connecting] decides the wording, so "connecting" and
///     "verifying" are distinguishable. A terminal that has not heard from the
///     daemon is in a different state from one that has not left the phone.
///   * the number of tries decides whether it reads as "retrying" or as "last
///     chance", because those are different promises.
String connectionStatusLabel(
  AppLocalizations l10n,
  ConnectionStatus? status, {
  bool loading = false,
}) {
  // A dial in flight. The stage is only known once the first attempt has been
  // started; before that the safe reading is "connecting".
  final connecting = switch ((loading, status)) {
    (true, final Connecting c) => c,
    (true, _) => const Connecting(),
    (false, final Connecting c) => c,
    _ => null,
  };
  if (connecting != null) {
    // A RECOVERY IS NOT A FIRST CONNECT. "Connecting…" over a board the user
    // was reading a minute ago reads as if the app had restarted; what they
    // need told is that the link they were using went away and is being put
    // back. The try counter is deliberately not part of it: nobody counts
    // retries they did not ask for.
    if (connecting.afterLoss) return l10n.connectionLostRetrying;
    if (connecting.isLastAttempt && connecting.isRetry) {
      return l10n.connectionStageLastAttempt;
    }
    if (connecting.isRetry) {
      return l10n.connectionRetryAttempt(
        connecting.attempt,
        connectionMaxAttempts,
      );
    }
    return switch (connecting.stage) {
      ConnectStage.dialling => l10n.connectionStageConnecting,
      ConnectStage.verifying => l10n.connectionStageVerifying,
    };
  }

  return switch (status) {
    Online(:final hello) => hello.version,
    ConnectionFailed(afterLoss: true) => l10n.connectionLost,
    ConnectionFailed() => l10n.connectionFailed,
    _ => l10n.connectionStateOffline,
  };
}

/// The one-line reason a failure is worth reading, or null.
///
/// Only the failures a user can act on get a second line, plus one case that is
/// not a fix but is a fact worth knowing: how many times it tried. "Connection
/// failed" after a silent ten seconds and after three visible attempts are the
/// same words for two different experiences, and the user is the one who has to
/// decide whether to try again.
///
/// A LOST CONNECTION COMES FIRST, because it is the one case where the user is
/// looking at the explanation for something they can see: the board is stale,
/// the terminal is frozen, and neither says why.
///
/// A generic exception gets NOTHING. The app saying "something went wrong" in
/// two places is not twice as informative, it is twice as loud.
String? connectionFailureDetail(
  AppLocalizations l10n,
  ConnectionFailed failure,
) {
  if (failure.isHerdrMissing) return l10n.errorHerdrNotFoundBody;
  if (failure.isForwardingRefused) return l10n.errorForwardingRefused;
  if (failure.isSecurityRelevant) return l10n.connectionStateHostKeyChangedBody;
  if (failure.afterLoss) {
    // Whether another round is coming is the difference between "wait" and "it
    // is not coming back on its own", and the rounds are bounded — so the line
    // can honestly say which one this is.
    return failure.willRetry
        ? l10n.connectionLostBody
        : l10n.connectionLostGaveUpBody;
  }
  if (failure.attempts > 1) {
    return l10n.connectionFailedAfterRetries(failure.attempts);
  }
  return null;
}

/// How the connection is going, as a line of text rather than a card.
///
/// WHY NOT A CARD. The board is a list of things that need you, and a failed
/// connection is not one of those — it is the absence of the thing that
/// produces them. Drawn as a card it sat in the same visual register as an
/// agent, took the same space, and pushed the two rows that did exist below the
/// fold; the user's words were "an offline card on the home page". Drawn as a
/// line it reads the way the rest of the app reads while it waits: a ring, a
/// few words, and a tap target if there is something to do about it.
class ConnectionStatusLine extends StatelessWidget {
  const ConnectionStatusLine({
    required this.status,
    required this.colors,
    this.loading = false,
    this.detail,
    this.action,
    super.key,
  });

  final ConnectionStatus? status;
  final HerdrColors colors;

  /// True while the provider is dialling, whatever [status] still says.
  final bool loading;

  /// A second line under the label, when there is one.
  ///
  /// Two kinds of fact arrive here and both are one line long: what to do about
  /// a failure ("install herdr and make sure it is on your PATH"), and which
  /// machine is about to be dialled. A sentence that needs a paragraph is a
  /// sentence that belongs on another screen.
  final String? detail;

  /// The one thing the user can do about the state on this line, if anything.
  ///
  /// A LABEL AND A CALLBACK rather than a `onRetry: VoidCallback?`, because the
  /// same line now carries three different actions depending on where the
  /// connection is: dial a machine that was never dialled, dial it again after
  /// a failure, or go add one. They all live in the same chip because they are
  /// all "the next step", and a caller that had to pick between two callbacks
  /// would be re-deriving the state this widget already has.
  final ({String label, VoidCallback onTap})? action;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dialling = loading || status is Connecting;
    final failure = status is ConnectionFailed ? status! as ConnectionFailed : null;
    final label = connectionStatusLabel(l10n, status, loading: loading);
    final explanation = detail ??
        (failure == null ? null : connectionFailureDetail(l10n, failure));

    final tint = failure != null ? colors.statusTextDied : colors.textDim;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (dialling)
                WorkingRing(color: colors.accent)
              else
                // In the ring's slot, not next to it: the label must not shift
                // sideways the moment a dial stops.
                SizedBox(
                  width: 15,
                  child: Center(
                    child: AgentStatusDot(color: tint, isActive: false),
                  ),
                ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tint,
                    fontSize: TextSize.strong,
                    height: 1.25,
                  ),
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: Space.sm),
                _RetryChip(
                  label: action!.label,
                  colors: colors,
                  onTap: action!.onTap,
                ),
              ],
            ],
          ),
          if (explanation != null) ...[
            const SizedBox(height: Space.xs),
            Padding(
              padding: const EdgeInsets.only(left: 15 + Space.md),
              child: Text(
                explanation,
                style: TextStyle(
                  color: colors.textFaint,
                  fontSize: TextSize.note,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small, quiet way forward.
///
/// A TEXT BUTTON, not a filled one. The board's one filled button is the thing
/// that starts an agent; a connection that is not up yet is a precondition, and
/// dressing it as the page's primary action would put it above the agents it
/// exists to show.
class _RetryChip extends StatelessWidget {
  const _RetryChip({
    required this.label,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final HerdrColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.xs + 1,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: BorderRadius.circular(Radii.uniform),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: colors.accent,
            fontSize: TextSize.note,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
