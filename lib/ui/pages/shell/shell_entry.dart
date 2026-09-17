import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/connection_status_line.dart';
import 'package:herdr_pocket/ui/components/herdr_sheet.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/shell/shell_page.dart';

/// The way into an SSH terminal, and the question it asks first.
///
/// WHY A BUTTON RATHER THAN A TAB. The board is already scoped to one machine,
/// and the terminal is scoped the same way — but the machine you want a shell
/// on is often NOT the machine the board is pointed at. That is the whole use
/// case this feature exists for: the box whose herdr is broken, the box with no
/// herdr at all, the box you are about to install something on. A tab would
/// have answered "the current machine"; the button can ask.
///
/// WHY NOT A `+`. A plus on a board of agents reads as "add an agent", and the
/// user would tap it expecting a form. The glyph is a terminal prompt, and the
/// sheet that follows names the machine, so the button never has to carry the
/// whole sentence.
class ShellEntryButton extends ConsumerWidget {
  const ShellEntryButton({super.key});

  /// The square the button occupies.
  ///
  /// 52 rather than the platform's 56: this floats over a board whose cards are
  /// the content, and every point it takes is a point of the list it covers.
  static const double size = 52;

  /// How much room the button needs that the dock does not already reserve.
  ///
  /// The board's list reserves [HerdrDock.reserveOf] for the dock; the button
  /// floats ABOVE that band, so the list has to leave this much more or the last
  /// card ends up underneath it. Both numbers are read from here rather than
  /// written into the page, because a hard-coded height in the page is exactly
  /// how the last card gets covered on one screen and not another.
  static double bandOf(BuildContext context) => size + Space.md;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final themed =
        ref.watch(settingsProvider.select((s) => s.iconSet)) ==
            AppIconSet.themed;

    return Semantics(
      button: true,
      label: l10n.shellOpen,
      child: GestureDetector(
        onTap: () {
          unawaited(HapticFeedback.mediumImpact());
          unawaited(showShellPicker(context, ref));
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            shape: BoxShape.circle,
            boxShadow: Elevation.card(colors),
          ),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: themed
                  ? UiIcon(
                      UiIconName.shell,
                      size: 26,
                      variant: UiIconVariant.themed,
                      background: colors.surface,
                    )
                  : Icon(
                      // The `>_` prompt, as close as the platform set gets.
                      CupertinoIcons.chevron_left_slash_chevron_right,
                      size: 24,
                      color: colors.text,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks which machine to open a terminal on, then opens it.
///
/// ALWAYS ASKS, even with one machine saved. The picker is where the connection
/// state is visible before you commit to a full-screen terminal, and a sheet
/// that sometimes appears and sometimes does not is a sheet the user cannot
/// learn.
Future<void> showShellPicker(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final colors = HerdrTheme.of(context);
  final hosts = ref.read(hostListProvider);
  final current = ref.read(currentHostProvider);

  final picked = await showHerdrSheet<HostProfile>(
    context: context,
    title: l10n.shellPickMachine,
    builder: (context, scroll) {
      if (hosts.isEmpty) {
        return ListView(
          controller: scroll,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.md,
                Space.lg,
                Space.xl,
              ),
              child: Text(
                l10n.shellNoMachines,
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: TextSize.body,
                  height: 1.5,
                ),
              ),
            ),
          ],
        );
      }

      return ListView.builder(
        controller: scroll,
        itemCount: hosts.length,
        itemBuilder: (context, index) {
          final host = hosts[index];
          // The state shown is the CURRENT dial's, because that is the only one
          // the app actually has: one machine is dialled at a time. Showing
          // every other machine as merely "saved" is the honest answer — this
          // sheet cannot know whether they are up without dialling them, and
          // pretending otherwise would be a lie the user acts on.
          final isCurrent = host.id == current?.id;
          final status = isCurrent
              ? ref.watch(connectionProvider).value
              : null;
          final loading = isCurrent && ref.watch(connectionProvider).isLoading;

          return _MachineRow(
            profile: host,
            subtitle: connectionStatusLabel(
              l10n,
              status,
              loading: loading,
            ),
            isCurrent: isCurrent,
            colors: colors,
            onTap: () => Navigator.of(context).pop(host),
          );
        },
      );
    },
  );

  if (picked == null || !context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute<void>(builder: (_) => ShellPage(profile: picked)),
  );
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({
    required this.profile,
    required this.subtitle,
    required this.isCurrent,
    required this.colors,
    required this.onTap,
  });

  final HostProfile profile;
  final String subtitle;
  final bool isCurrent;
  final HerdrColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: TextSize.strong,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textDim,
                      fontSize: TextSize.meta,
                    ),
                  ),
                ],
              ),
            ),
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(left: Space.sm),
                child: Icon(
                  CupertinoIcons.checkmark_alt,
                  size: 18,
                  color: colors.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
