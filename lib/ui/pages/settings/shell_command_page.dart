import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// What the SSH terminal runs when it opens.
///
/// A SETTING RATHER THAN A CONSTANT, because "a terminal" is two different
/// things on two different machines. On a box with tmux it should attach to a
/// session that outlives the phone — close the app, come back, the scrollback
/// is still there. On a box without tmux the same command is an error message.
/// The app cannot tell which machine it is looking at until it has tried, so
/// the user says.
///
/// BLANK IS A VALID ANSWER and means the login shell. It is stored exactly as
/// typed: trimming on the way in would fight the cursor of somebody halfway
/// through editing a command.
class ShellCommandPage extends ConsumerStatefulWidget {
  const ShellCommandPage({super.key});

  @override
  ConsumerState<ShellCommandPage> createState() => _ShellCommandPageState();
}

class _ShellCommandPageState extends ConsumerState<ShellCommandPage> {
  late final TextEditingController _controller;
  Timer? _write;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(settingsProvider).sessionCommand,
    )..addListener(_onChanged);
  }

  @override
  void dispose() {
    // FLUSH BEFORE THE PAGE GOES, or a debounced write that never fires is a
    // setting the user watched themselves type and did not get.
    _write?.cancel();
    _controller.removeListener(_onChanged);
    final text = _controller.text;
    if (text != ref.read(settingsProvider).sessionCommand) {
      unawaited(ref.read(settingsProvider.notifier).setSessionCommand(text));
    }
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Debounced, because this writes to disk and the value is only meaningful
    // once the user stops typing. A write per keystroke is work nobody asked
    // for, on the one screen where typing is the whole interaction.
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      unawaited(
        ref.read(settingsProvider.notifier).setSessionCommand(_controller.text),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(settingsProvider.select((s) => s.sessionCommand));

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: ScrollConfiguration(
        behavior: settingsScrollBehavior(context),
        child: CustomScrollView(
          slivers: [
            HerdrSliverTopBar(
              title: l10n.shellCommandTitle,
              leading: HerdrBackButton(label: l10n.navBack),
            ),
            SliverToBoxAdapter(
              // NO GROUP TITLE: the page is already titled, and a card headed
              // with the same words directly under it is the duplication this
              // design system has a rule against.
              child: SettingsGroup(
                rows: [
                  SettingsRow(
                    label: l10n.shellCommandLabel,
                    // `below` rather than `trailing`: a command is longer than
                    // the space a trailing control gets, and a field that
                    // shrink-wrapped beside its label would show four
                    // characters of `tmux new -A -s herdr-pocket`.
                    below: _CommandField(controller: _controller),
                  ),
                  // The way back exists only when there is something to go back
                  // from. A row offering to restore the default while the
                  // default is already in the field is a button that does
                  // nothing, and this screen has a rule about those.
                  if (current != defaultSessionCommand)
                    _RestoreRow(
                      colors: colors,
                      label: l10n.shellCommandRestore,
                      onTap: () => unawaited(_restoreDefault()),
                    ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsNote(text: l10n.shellCommandFooter),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restoreDefault() async {
    _write?.cancel();
    _controller.text = defaultSessionCommand;
    await ref
        .read(settingsProvider.notifier)
        .setSessionCommand(defaultSessionCommand);
  }
}

/// "Put the default back", as a row rather than a switch.
///
/// NOT A SWITCH. A switch has two positions and this has one action: turning it
/// OFF would have to mean something, and every meaning available ("keeps the
/// custom command", "does nothing") is worse than not showing the control at
/// all. The design system calls that out — a control that does not do what its
/// shape promises — so this is a plain row with an obvious tap target.
class _RestoreRow extends StatelessWidget {
  const _RestoreRow({
    required this.colors,
    required this.label,
    required this.onTap,
  });

  final HerdrColors colors;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SettingsRow(
        label: label,
        labelColor: colors.accent,
        trailing: Icon(
          CupertinoIcons.arrow_counterclockwise,
          size: 16,
          color: colors.accent,
        ),
      ),
    );
  }
}

/// The command itself.
///
/// THE INPUT-METHOD REWRITES ARE OFF, and that is the whole reason this is a
/// widget instead of a one-line `CupertinoTextField` in the row. A smart quote
/// or a smart dash in a shell command is not a typo — it is a different
/// command, or a syntax error on a line the user cannot see, and it arrives
/// silently. The same four switches the credential fields use, for the same
/// reason.
///
/// The style is written out in full because `CupertinoTextField` hands it
/// straight to `EditableText` rather than merging it with the ambient
/// `DefaultTextStyle`: a field carrying only a `fontSize` loses the CJK
/// fallback, and every Chinese character in it renders as a box.
class _CommandField extends StatelessWidget {
  const _CommandField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoTextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      keyboardType: TextInputType.text,
      textInputAction: TextInputAction.done,
      placeholder: l10n.shellCommandPlaceholder,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: Border.all(color: colors.hairline),
      ),
      style: TextStyle(
        color: colors.text,
        fontSize: TextSize.body,
        fontFamily: HerdrFonts.mono,
        fontFamilyFallback: HerdrFonts.monoFallback,
      ),
    );
  }
}
