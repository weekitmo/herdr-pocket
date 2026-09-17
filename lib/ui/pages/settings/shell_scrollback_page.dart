import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// How far back an SSH terminal can be scrolled.
///
/// A NUMBER, NOT A STEPPER, and that is the design decision this screen is.
/// The stepper next door exists for text size because that setting has eight
/// sensible values and the user returns to the reset point constantly. A line
/// count is not that: it is an arbitrary number with a wide useful range, and
/// walking from 1000 to 50000 in steps is fifty presses to say one thing.
///
/// So it is a field, with a number pad, and the range enforced where the value
/// is stored rather than where it is typed — [clampScrollbackLines] is one
/// function and the settings notifier is the one caller, so a future screen
/// that sets this directly is as safe as this one.
class ShellScrollbackPage extends ConsumerStatefulWidget {
  const ShellScrollbackPage({super.key});

  @override
  ConsumerState<ShellScrollbackPage> createState() =>
      _ShellScrollbackPageState();
}

class _ShellScrollbackPageState extends ConsumerState<ShellScrollbackPage> {
  late final TextEditingController _controller;
  Timer? _write;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: '${ref.read(settingsProvider).scrollbackLines}',
    )..addListener(_onChanged);
  }

  @override
  void dispose() {
    // Flush before the page goes: a debounced write that never fires is a
    // setting the user watched themselves type and did not get.
    _write?.cancel();
    _controller.removeListener(_onChanged);
    _commit(_controller.text);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _commit(_controller.text);
    });
  }

  /// Writes what can be written, and silently does nothing when the field is
  /// mid-edit.
  ///
  /// NOT AN ERROR, deliberately: a half-typed `100` on the way to `10000` is
  /// not a mistake, and a red sentence that appears while somebody is typing is
  /// the app arguing with them. The footer states the accepted range, and the
  /// field keeps whatever they typed until it parses.
  void _commit(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    unawaited(ref.read(settingsProvider.notifier).setScrollbackLines(parsed));
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: ScrollConfiguration(
        behavior: settingsScrollBehavior(context),
        child: CustomScrollView(
          slivers: [
            HerdrSliverTopBar(
              title: l10n.shellScrollbackTitle,
              leading: HerdrBackButton(label: l10n.navBack),
            ),
            SliverToBoxAdapter(
              // NO GROUP TITLE: the page is already titled, and a card headed
              // with the same words directly under it is the duplication this
              // design system has a rule against.
              child: SettingsGroup(
                rows: [
                  SettingsRow(
                    label: l10n.shellScrollbackLabel,
                    below: _LinesField(controller: _controller),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsNote(
                text: l10n.shellScrollbackFooter(
                  minScrollbackLines,
                  maxScrollbackLines,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The line count itself.
///
/// A NUMBER PAD RATHER THAN THE FULL KEYBOARD, and the input-method rewrites
/// off for the same reason the command field turns them off: this box holds a
/// number, and a "helpful" smart-comma or a suggestion bar over it is noise on
/// a screen with one field.
class _LinesField extends StatelessWidget {
  const _LinesField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    return CupertinoTextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.done,
      placeholder: '$defaultScrollbackLines',
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
