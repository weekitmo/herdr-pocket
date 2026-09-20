import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/connection_status_line.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The board's loading state, in the middle of the screen.
///
/// WHY CENTRED, AND WHY ONLY HERE. The connection's status is normally a LINE
/// at the top of the board — see [ConnectionStatusLine] for why it is not a
/// card — and that is the right shape when there is a board underneath it to
/// belong to: a reconnect over cached rows must not blank the screen (Phase 26
/// removed exactly that lie). But the FIRST dial has no rows to belong to. The
/// line then sat alone in the top-left corner of an empty page, which is what
/// the user reported: it read as a stray label rather than as the screen being
/// busy, and it never said which part of the wait they were in.
///
/// So: nothing to show ⇒ centred, with the step spelled out. Something to show
/// ⇒ the line, unchanged.
class BoardLoading extends StatelessWidget {
  const BoardLoading({
    required this.title,
    required this.colors,
    this.step,
    this.target,
    super.key,
  });

  /// The state in a few words: "Connecting…", "Retrying 2/3…".
  ///
  /// Built by [connectionStatusLabel] at the call site, so this screen and the
  /// top-right badge cannot describe the same dial differently.
  final String title;

  /// Which part of the wait this is, when the transport has said.
  final String? step;

  /// The machine being dialled, so the screen answers "to where?" as well.
  final String? target;

  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The app's own spinner rather than a package's: the same one the
            // SSH shell shows while it is opening, for the same kind of wait.
            CupertinoActivityIndicator(radius: 14, color: colors.accent),
            const SizedBox(height: Space.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: TextSize.title,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            if (step != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                step!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: TextSize.strong,
                  height: 1.3,
                ),
              ),
            ],
            if (target != null) ...[
              const SizedBox(height: Space.xs),
              Text(
                target!,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textFaint,
                  fontSize: TextSize.meta,
                  fontFamily: HerdrFonts.mono,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The step the centred block should name for [status], if any.
///
/// A free function rather than logic inside the widget so the board page's
/// decision (is this dial worth the centred block?) and the widget's wording
/// come from the same reading of the same state.
String? boardLoadingStep(AppLocalizations l10n, ConnectionStatus? status) {
  if (status is! Connecting) return null;
  return connectionStageStep(l10n, status.stage);
}
