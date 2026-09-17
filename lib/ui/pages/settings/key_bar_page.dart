import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Chooses which keys the terminal's key bar offers.
///
/// WHY THIS IS A LIST OF TICKS RATHER THAN A DRAG-TO-REORDER BAR. The bar is a
/// horizontal scroller: what matters is which keys are ON it, and the catalogue
/// is longer than the bar will ever be. Order is the catalogue's business —
/// escape and the arrows first because those are what you reach for under
/// pressure — and letting the user shuffle it would mean a bar whose first
/// screenful is different on every phone, which is the opposite of what muscle
/// memory wants from a control you press without looking.
///
/// Ticks rather than switches because this is CHOOSING FROM A SET, not turning
/// independent things on. A column of switches implies every row is its own
/// feature; a column of ticks reads as one list with a subset selected, which
/// is what it is.
class KeyBarPage extends ConsumerWidget {
  const KeyBarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final chosen = ref.watch(settingsProvider.select((s) => s.keyBarKeys));
    final notifier = ref.read(settingsProvider.notifier);
    final selected = chosen.toSet();

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: ScrollConfiguration(
        behavior: settingsScrollBehavior(context),
        child: CustomScrollView(
          slivers: [
            HerdrSliverTopBar(
              title: l10n.keysTitle,
              leading: HerdrBackButton(label: l10n.navBack),
            ),

            SliverToBoxAdapter(
              // NO GROUP TITLE. The page is already titled "Key bar"; a card
              // headed "KEY BAR" directly under it is the exact duplication
              // this design system has a rule against — and the rule exists
              // because the first version of the settings screen had a section
              // header reading "Text size" sitting above a row reading "Text
              // size".
              child: SettingsGroup(
                rows: [
                  for (final key in keyBarCatalogue)
                    _KeyChoice(
                      softKey: key,
                      colors: colors,
                      selected: selected.contains(key),
                      // Sends the whole list back, so the stored order is the
                      // catalogue's order no matter how the user got there.
                      onToggle: () => notifier.setKeyBarKeys([
                        for (final k in keyBarCatalogue)
                          if (k == key ? !selected.contains(k) : selected.contains(k)) k,
                      ]),
                    ),
                ],
              ),
            ),

            // The note is not decoration. A sticky modifier is the one part of
            // this that cannot be guessed from looking at it: pressing Ctrl and
            // seeing nothing happen reads as a broken button unless somebody
            // says that it is waiting.
            SliverToBoxAdapter(child: SettingsNote(text: l10n.keysFooter)),

            SliverToBoxAdapter(
              child: SettingsGroup(
                rows: [
                  _ActionRow(
                    label: l10n.keysReset,
                    colors: colors,
                    onTap: () => notifier.setKeyBarKeys(defaultKeyBar),
                  ),
                ],
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: Space.xl)),
          ],
        ),
      ),
    );
  }
}

/// The line under a key's own label.
///
/// TWO LINES, ONE JOB. The first line is what the button on the bar will say, so
/// that the row and the button can be matched up; the second is what it means,
/// because `pgup` is not a word anybody says out loud and `C-c` is not a word at
/// all. For the five ready-made control codes the second line LEADS with the
/// keys spelled the way a keyboard is labelled — `Ctrl+C` — because the bar's
/// compact `C-c` is only readable to somebody who already knows the notation,
/// and the label is not going to change: it is the standard spelling, and it is
/// half the width on a bar that scrolls sideways on a phone.
String _noteFor(SoftKey key, AppLocalizations l10n) => switch (key.kind) {
  KeyKind.modifier => '${key.description} · ${l10n.keysModifier}',
  KeyKind.action => '${key.description} · ${l10n.keysCopyHint}',
  KeyKind.literal => key.combination == null
      ? key.description
      : '${key.combination} · ${key.description}',
};

/// One key, with a tick when the bar shows it.
class _KeyChoice extends StatelessWidget {
  const _KeyChoice({
    required this.softKey,
    required this.colors,
    required this.selected,
    required this.onToggle,
  });

  final SoftKey softKey;
  final HerdrColors colors;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final key = softKey;
    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: SettingsRow(
        // The key's own label first: it is what the button on the bar will say,
        // and matching them is the whole point of this screen. The full name is
        // the note because `pgup` is not a word anybody says out loud.
        label: key.label,
        note: _noteFor(key, l10n),
        labelColor: selected ? colors.text : colors.textDim,
        trailing: Icon(
          selected ? CupertinoIcons.check_mark_circled_solid : CupertinoIcons.circle,
          size: 20,
          // The app's one interactive tint, the same one the glass switch
          // already uses. A tick is a control state, not a status, so none of
          // the four status hues belong here.
          color: selected ? colors.accent : colors.hairline,
        ),
      ),
    );
  }
}

/// A row that does something rather than holding a value.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
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
      child: SettingsRow(
        label: label,
        labelColor: colors.accent,
        trailing: Icon(
          CupertinoIcons.arrow_counterclockwise,
          size: 18,
          color: colors.accent,
        ),
      ),
    );
  }
}
