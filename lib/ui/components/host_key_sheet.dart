import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/host_store.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Asks the user about a host key the SSH handshake just presented.
///
/// Renders on top of whatever is showing, because the handshake is BLOCKED on
/// the answer: without a sheet there is no way to finish connecting, and the
/// connection would simply time out with no explanation.
///
/// The two cases are deliberately not styled the same. A first connection is a
/// routine question and reads as one. A key that CHANGED is a security event —
/// it is either a rebuilt machine or an interception, and the only honest thing
/// to do is say so in the strongest terms the design allows and make the safe
/// answer the easy one.
class HostKeySheet extends ConsumerWidget {
  const HostKeySheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(hostKeyApprovalProvider);
    final colors = HerdrTheme.of(context);

    if (pending == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final changed = pending.previous != null;
    final accent = changed ? colors.died : colors.waiting;

    void answer(HostKeyDecision decision) {
      ref.read(hostKeyApprovalProvider.notifier).resolve(decision);

      // Answering "yes" has to actually get you connected.
      //
      // In the happy path the SSH handshake is BLOCKED on this answer, so
      // resolving it lets the attempt that asked the question continue and
      // nothing more is needed. But that is not always the path taken: a
      // retry replaces a pending question (see [HostKeyApprovalNotifier]), and
      // an attempt can also fail — a server-side penalty, a dropped socket —
      // while the sheet is open. In those cases the handshake that asked is
      // already gone, the answer resolves a question nobody is waiting on, and
      // the user is left staring at "unreachable" having just been told their
      // machine is trusted. That is a dead end with no next step.
      //
      // So: if the connection is not up, ask for another attempt. Guarded on
      // the status rather than fired unconditionally, because dialling over a
      // live connection would tear it down to rebuild it identically.
      if (decision == HostKeyDecision.reject) return;
      final status = ref.read(connectionProvider).value;
      if (status is Online) return;
      ref.read(connectionProvider.notifier).connect();
    }

    return ColoredBox(
      color: colors.groundDeep.withValues(alpha: 0.55),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              border: Border.all(color: colors.hairline),
            ),
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        changed
                            ? l10n.hostKeyChangedTitle
                            : l10n.hostKeyNewTitle,
                        style: TextStyle(
                          color: changed ? colors.statusTextDied : colors.text,
                          fontSize: TextSize.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                Text(
                  changed ? l10n.hostKeyChangedBody : l10n.hostKeyNewBody,
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: TextSize.note,
                    height: 1.42,
                  ),
                ),
                const SizedBox(height: Space.lg),
                _Field(
                  label: '${pending.prompt.host}:${pending.prompt.port}',
                  value: pending.prompt.keyType,
                  colors: colors,
                ),
                const SizedBox(height: Space.sm),
                _Field(
                  label: l10n.hostKeyFingerprint,
                  value: pending.prompt.fingerprint,
                  colors: colors,
                  monospace: true,
                ),
                // On a changed key the old fingerprint must be visible next to
                // the new one: "it changed" without showing what it changed
                // from gives the user nothing to check against.
                if (changed && pending.previous != null) ...[
                  const SizedBox(height: Space.sm),
                  _Field(
                    label: l10n.hostKeyPreviously,
                    value: pending.previous!.fingerprint,
                    colors: colors,
                    monospace: true,
                    muted: true,
                  ),
                ],
                const SizedBox(height: Space.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _Button(
                      label: l10n.hostKeyReject,
                      colors: colors,
                      onPressed: () => answer(HostKeyDecision.reject),
                    ),
                    const SizedBox(width: Space.sm),
                    _Button(
                      label: l10n.hostKeyApproveOnce,
                      colors: colors,
                      onPressed: () => answer(HostKeyDecision.approveOnce),
                    ),
                    const SizedBox(width: Space.sm),
                    _Button(
                      label: l10n.hostKeyApproveAndRemember,
                      colors: colors,
                      // Refusing is the default for a changed key, so approving
                      // is the one action that has to be deliberate.
                      emphasis: changed ? _Emphasis.warning : _Emphasis.normal,
                      onPressed: () =>
                          answer(HostKeyDecision.approveAndRemember),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    required this.colors,
    this.monospace = false,
    this.muted = false,
  });

  final String label;
  final String value;
  final HerdrColors colors;
  final bool monospace;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.textFaint,
            fontSize: TextSize.micro,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        // Plain Text, not SelectableText: the latter lives in
        // package:flutter/material.dart, and pulling it in would break the
        // no-Material rule for a nice-to-have. A fingerprint is compared by
        // eye against another screen anyway, which is the point of showing it.
        Text(
          value,
          style: TextStyle(
            color: muted ? colors.textDim : colors.text,
            // A fingerprint is meant to be compared character by character
            // against another screen, so it gets a face where every glyph has
            // the same width and the eye can line them up.
            fontFamily: monospace ? HerdrFonts.mono : null,
            fontSize: monospace ? TextSize.meta : TextSize.body,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

enum _Emphasis { normal, warning }

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.colors,
    required this.onPressed,
    this.emphasis = _Emphasis.normal,
  });

  final String label;
  final HerdrColors colors;
  final VoidCallback onPressed;
  final _Emphasis emphasis;

  @override
  Widget build(BuildContext context) {
    final warning = emphasis == _Emphasis.warning;
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      color: warning ? colors.died : colors.surfaceRaised,
      borderRadius: BorderRadius.circular(Radii.uniform),
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          color: warning ? const Color(0xFFFFFFFF) : colors.text,
          fontSize: TextSize.body,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
