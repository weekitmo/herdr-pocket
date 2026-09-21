import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The centred wait block, for a screen that has nothing to show yet.
///
/// WHY CENTRED, AND WHY ONLY WHEN THERE IS NOTHING. When a list does have rows,
/// the connection's own state belongs in a LINE above them — see
/// `ConnectionStatusLine` for why it is not a card — and a reconnect over rows
/// must not blank the screen (Phase 26 removed exactly that lie). But a screen
/// with NO rows has nothing for a line to belong to: the line sat alone in the
/// top-left corner of an empty page and read as a stray label rather than as
/// the screen being busy, which is what the user reported about the board. The
/// workspaces page then inherited the same shape from the other end: on a
/// machine that is being read for the first time, or one the user just switched
/// to, "no workspaces" is a claim about the machine and the truth is "we have
/// not asked yet".
///
/// So: nothing to show ⇒ centred, with the step and the machine spelled out.
class LoadingBlock extends StatelessWidget {
  const LoadingBlock({
    required this.title,
    required this.colors,
    this.step,
    this.target,
    super.key,
  });

  /// The state in a few words: "Connecting…", "Retrying 2/3…", "Reading…".
  ///
  /// Built by [connectionStatusLabel] at the call site, so a screen and the
  /// top-right badge cannot describe the same dial differently.
  final String title;

  /// Which part of the wait this is, when the transport has said.
  final String? step;

  /// The machine being waited on, so the screen answers "to where?" as well.
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
