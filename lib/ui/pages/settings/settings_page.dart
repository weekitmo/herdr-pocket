import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/local/download_target.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/data/update/update_controller.dart';
import 'package:herdr_pocket/domain/theme/theme_definition.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/components/menu_popover.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/theme_swatch.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/components/update_sheet.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:herdr_pocket/ui/pages/lock/pin_setup_page.dart';
import 'package:herdr_pocket/ui/pages/settings/icons_page.dart';
import 'package:herdr_pocket/ui/pages/settings/key_bar_page.dart';
import 'package:herdr_pocket/ui/pages/settings/shell_command_page.dart';
import 'package:herdr_pocket/ui/pages/settings/shell_scrollback_page.dart';
import 'package:herdr_pocket/ui/pages/settings/theme_page.dart';

/// The sentinel standing for "follow the system" in the language picker.
const _kSystem = '__system__';

/// Appearance, behaviour, type size, about.
///
/// SHAPED LIKE iOS SETTINGS, and the first version was not. It stacked a label
/// above its control and gave every setting its own paragraph, which produced
/// rows about 200 logical pixels tall with no rules between them: "Notifications
/// + explanation + Connect on launch + explanation" read as one undifferentiated
/// block, and the section header "Text size" sat directly above a row labelled
/// "Text size".
///
/// So the four rules this file now follows, all of them the platform's rather
/// than this app's invention:
///
///   1. ONE ROW PER SETTING, label left and control right, in the same line.
///   2. A HAIRLINE BETWEEN ROWS, inset from the left so the card reads as a
///      list rather than a paragraph. The inset is the point: a rule that spans
///      the full card draws a box, a rule that starts where the text starts
///      draws a list.
///   3. EXPLANATION IS A SECOND LINE OF ITS OWN ROW, smaller and fainter, never
///      a separate paragraph floating between rows. Where it belongs is
///      unambiguous because the rule closes it.
///   4. GROUP FOOTNOTES SIT BELOW THE CARD, at the same left inset as the card's
///      text, and never inside it.
///
/// Every control writes through to storage immediately — there is no Save
/// button. A settings screen with one is a settings screen where the user has
/// to guess whether a change took effect, and these are all reversible in one
/// tap.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    // The lock's own state, WATCHED: the two switches below are drawn from it,
    // so turning the lock on has to redraw this page.
    final lock = ref.watch(appLockProvider).value ?? const AppLockState();
    final biometrics = ref.watch(biometricAvailableProvider).value ?? false;

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: ScrollConfiguration(
        behavior: settingsScrollBehavior(context),
        child: CustomScrollView(
          slivers: [
            // NOT A PUSHED PAGE: the settings root is one of the dock's three
            // destinations, so it has no way back and no actions of its own.
            HerdrSliverTopBar(title: l10n.settingsTitle),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsAppearance,
                rows: [
                  // Hidden while a scheme is selected, and that is not a
                  // layout trick: a scheme decides its own mode, so leaving
                  // this row visible would be offering a control that does
                  // nothing. It comes back the moment the built-in palette
                  // does, which is the only state where it means anything.
                  if (settings.themeId == null)
                    _Segmented<AppThemeMode>(
                      label: l10n.settingsTheme,
                      colors: colors,
                      options: [
                        (AppThemeMode.system, l10n.settingsThemeSystem),
                        (AppThemeMode.light, l10n.settingsThemeLight),
                        (AppThemeMode.dark, l10n.settingsThemeDark),
                      ],
                      value: settings.themeMode,
                      onChanged: notifier.setThemeMode,
                    ),
                  // Sits with light/dark because that is what it actually is:
                  // a theme carries its own mode, so these two rows are one
                  // decision split across two screens, and the swatch is what
                  // keeps them from looking unrelated.
                  _ThemeRow(
                    label: l10n.settingsColourScheme,
                    colors: colors,
                    theme: ref.watch(selectedThemeProvider),
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const ThemePage(),
                      ),
                    ),
                  ),
                  // Next to the colour scheme on purpose: this is the same
                  // question from the other side — a scheme decides what the
                  // icons are coloured WITH, and this decides whether they are
                  // allowed to be coloured at all.
                  _Segmented<AppIconSet>(
                    label: l10n.settingsIcons,
                    colors: colors,
                    options: [
                      (AppIconSet.system, l10n.settingsIconsSystem),
                      (AppIconSet.themed, l10n.settingsIconsThemed),
                    ],
                    value: settings.iconSet,
                    onChanged: notifier.setIconSet,
                  ),
                  _Segmented<String>(
                    label: l10n.settingsLanguage,
                    colors: colors,
                    options: [
                      (_kSystem, l10n.settingsLanguageSystem),
                      ('zh', '中文'),
                      ('en', 'EN'),
                    ],
                    value: settings.languageCode ?? _kSystem,
                    onChanged: (v) =>
                        notifier.setLanguage(v == _kSystem ? null : v),
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsBehaviour,
                // Grouped together because they are the same kind of decision —
                // what the app does on its own — rather than because they are
                // both switches. The previous version filed the auto-connect
                // switch under "Appearance", which is simply not what it is.
                //
                // NO EXPLANATION UNDER ANY OF THEM, and that is the rule now:
                // a screen of switches each carrying a sentence is a screen
                // nobody reads. A row whose label does not say what it does is
                // a labelling problem, not a documentation one.
                rows: [
                  SettingsSwitchRow(
                    label: l10n.settingsGlass,
                    value: settings.glassEnabled,
                    onChanged: (v) => notifier.setGlassEnabled(enabled: v),
                  ),
                  SettingsSwitchRow(
                    label: l10n.settingsNotifications,
                    value: settings.notificationsEnabled,
                    onChanged: (v) =>
                        notifier.setNotificationsEnabled(enabled: v),
                  ),
                  // THE KEEP-ALIVE ROW ONLY EXISTS WHERE IT CAN DO SOMETHING.
                  // Its mechanism is an Android foreground service, and iOS has
                  // no equivalent — so on iOS this row would be a switch that
                  // writes a preference and changes nothing, which is the app
                  // lying about the user's own phone. The setting stays in the
                  // store either way, so a preference set on Android is not lost
                  // if the same profile is restored elsewhere.
                  if (ref.watch(processKeeperProvider).isSupported)
                    SettingsSwitchRow(
                      label: l10n.settingsKeepAlive,
                      // The one row in this group that carries a note, and it
                      // earns it: the cost of this switch is a persistent
                      // notification, and a switch that spends something the
                      // label does not name is a switch nobody can decide about.
                      note: l10n.settingsKeepAliveNote,
                      value: settings.keepAlive,
                      onChanged: (v) => notifier.setKeepAlive(enabled: v),
                    ),
                  SettingsSwitchRow(
                    label: l10n.settingsAutoConnect,
                    value: settings.autoConnect,
                    onChanged: (v) => notifier.setAutoConnect(enabled: v),
                  ),
                  // THREE STATES, NOT A SWITCH, and that is the point of the
                  // row. "Keep clear of the gesture bar" has a right answer the
                  // app can usually work out for itself — so the useful control
                  // is "trust that, or overrule it", and a switch cannot say
                  // the first half.
                  _SafetyMarginRow(
                    colors: colors,
                    value: settings.safetyInset,
                    onChanged: notifier.setSafetyInset,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsSecurity,
                rows: [
                  SettingsSwitchRow(
                    label: l10n.settingsAppLock,
                    // The one row in this group that carries a note, and it
                    // earns it: the switch spends something the label does not
                    // name — a PIN on every cold start, and the five minutes of
                    // grace that come with it.
                    note: l10n.settingsAppLockNote,
                    value: lock.pinSet,
                    onChanged: (on) => on
                        ? _openPinSetup(context, PinSetupMode.create)
                        : unawaited(_confirmRemoveLock(context)),
                  ),
                  SettingsSwitchRow(
                    label: l10n.settingsAppLockBiometrics,
                    value: lock.biometricsEnabled,
                    // DISABLED, WITH THE REASON, rather than hidden: the row is
                    // where the user learns that the fingerprint needs a PIN
                    // first — and that a phone without a sensor cannot offer it
                    // at all.
                    enabled: lock.pinSet && biometrics,
                    note: !lock.pinSet
                        ? l10n.settingsAppLockNeedsPin
                        : (biometrics
                              ? null
                              : l10n.settingsAppLockNoBiometrics),
                    onChanged: (on) => unawaited(
                      ref
                          .read(appLockProvider.notifier)
                          .setBiometricsEnabled(enabled: on),
                    ),
                  ),
                  if (lock.pinSet)
                    // A GestureDetector around the row rather than a tap
                    // handler on it: `SettingsRow` draws, it does not act —
                    // see `_ThemeRow` above, which opens the picker the same
                    // way.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openPinSetup(context, PinSetupMode.change),
                      child: SettingsRow(
                        label: l10n.settingsAppLockChangePin,
                        trailing: Icon(
                          CupertinoIcons.chevron_forward,
                          size: 14,
                          color: colors.textFaint,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsTransferTitle,
                rows: [
                  SettingsSwitchRow(
                    label: l10n.settingsTransferEnabled,
                    value: settings.fileTransferEnabled,
                    onChanged: (v) =>
                        notifier.setFileTransferEnabled(enabled: v),
                  ),
                  // THE FOLDER ROW ONLY EXISTS WHEN THE SWITCH IS ON, and that
                  // is the point of the switch: asking for a directory is a
                  // system permission prompt, and a permission prompt nobody
                  // asked for is the thing this setting exists to avoid.
                  if (settings.fileTransferEnabled)
                    _DownloadDirectoryRow(
                      colors: colors,
                      uri: settings.downloadDirUri,
                      label: settings.downloadDirLabel,
                    ),
                ],
              ),
            ),

            if (settings.fileTransferEnabled)
              SliverToBoxAdapter(
                child: SettingsNote(text: l10n.settingsTransferEnabledFooter),
              ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsTextSize,
                rows: [
                  _Stepper(
                    label: l10n.settingsTextSizeApp,
                    colors: colors,
                    value: settings.textScale,
                    min: 0.85,
                    max: 1.4,
                    step: 0.05,
                    onChanged: notifier.setTextScale,
                  ),
                  _Stepper(
                    label: l10n.settingsTerminalFontSize,
                    colors: colors,
                    value: settings.terminalTextScale,
                    min: 0.8,
                    max: 1.8,
                    step: 0.1,
                    onChanged: notifier.setTerminalTextScale,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                // NO HEADING — the row names itself and counts itself, and a
                // heading reading "Key bar" directly above a row reading "Key
                // bar" is the duplication this design system has a rule
                // against (it is the same mistake the first version of this
                // screen made with "Text size" over "Text size").
                rows: [
                  // The chat window belongs with the key bar rather than in a
                  // group of its own: they are the two halves of one question —
                  // what the strip above the keyboard is made of — and a turn
                  // that arrives here is a turn about typing.
                  SettingsSwitchRow(
                    label: l10n.settingsComposer,
                    note: l10n.settingsComposerNote,
                    value: settings.composerEnabled,
                    onChanged: (v) =>
                        notifier.setComposerEnabled(enabled: v),
                  ),
                  _Disclosure(
                    label: l10n.settingsKeys,
                    colors: colors,
                    value: l10n.settingsKeysCount(settings.keyBarKeys.length),
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const KeyBarPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              // The SSH terminal's command is its own card rather than a row in
              // the key-bar group above: that group is about what the strip
              // above the keyboard is made of, and this is about what the
              // terminal RUNS. Two questions, and a card that answers both is
              // how a heading ends up lying about one of them.
              child: SettingsGroup(
                rows: [
                  _Disclosure(
                    label: l10n.shellCommandLabel,
                    colors: colors,
                    // A PHRASE, NEVER THE COMMAND. The default is a shell
                    // snippet and a custom one can be any length at all; a
                    // settings row is built on the assumption that a value is
                    // short, and bending that assumption cost every other row on
                    // this page its alignment. The row says what the setting
                    // DOES; the page behind it shows the command, which is also
                    // the only place anyone would change it.
                    value: settings.sessionCommand == defaultSessionCommand
                        ? l10n.shellCommandDefaultValue
                        : l10n.shellCommandCustom,
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const ShellCommandPage(),
                      ),
                    ),
                  ),
                  // Both rows name the SSH terminal in their own labels rather
                  // than sitting under a heading that says so: the heading rule
                  // (no card titled with the words of the row beneath it) cuts
                  // both ways, and a card headed "SSH terminal" over a row
                  // reading "terminal command" is the same duplication.
                  _Disclosure(
                    label: l10n.shellScrollbackTitle,
                    colors: colors,
                    value: l10n.shellScrollbackLines(settings.scrollbackLines),
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const ShellScrollbackPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // A comparison, not a setting, and it will be deleted the moment
            // the question is answered. Untitled rather than filed under a
            // neighbouring heading: a card that answers a different question
            // than the heading above it is how "KEY BAR" ends up sitting over
            // a row about icons.
            SliverToBoxAdapter(
              child: SettingsGroup(
                rows: [
                  _Disclosure(
                    label: l10n.iconsTitle,
                    colors: colors,
                    value: '',
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const IconsPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsUpdates,
                rows: [
                  // The row carries the CURRENT ANSWER, not just a verb. A row
                  // that says only "Check for updates" tells the user nothing
                  // until they press it, and pressing it is exactly the thing
                  // they were trying to avoid.
                  _CheckUpdateRow(colors: colors),
                  SettingsSwitchRow(
                    label: l10n.settingsAutoUpdate,
                    value: settings.autoUpdateCheck,
                    onChanged: (v) => notifier.setAutoUpdateCheck(enabled: v),
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                title: l10n.settingsAbout,
                rows: [
                  _Value(
                    label: l10n.settingsAppVersion,
                    colors: colors,
                    value: switch (ref.watch(packageInfoProvider).value) {
                      final info? => '${info.version} (${info.buildNumber})',
                      _ => '—',
                    },
                  ),
                  // The daemon's version and the machine it is on. More useful in
                  // this app than the app's own build number, and it is the pair
                  // anyone would ask for when a pane misbehaves.
                  _Value(
                    label: l10n.settingsDaemon,
                    colors: colors,
                    mono: true,
                    value: switch (ref.watch(connectionProvider).value) {
                      Online(:final hello) =>
                        'herdr ${hello.version} · ${_shortHost(ref)}',
                      _ => l10n.connectionStateOffline,
                    },
                  ),
                ],
              ),
            ),

            // The socket path is a long machine string, so it goes where long
            // machine strings go — under the card at the footnote inset, rather
            // than squeezed into the value column where it wraps mid-token.
            //
            // WRAPPED IN A SLIVER, and that is not ceremony: `slivers:` accepts
            // slivers ONLY. A box widget placed here reaches `RenderViewport`
            // as a child it cannot lay out, and the failure surfaces as a
            // framework assertion about the element tree rather than as
            // anything mentioning this line. It only fires once the app is
            // CONNECTED, because that is when there is a socket path to show —
            // so it survived every offline run and every test this page had,
            // which was none.
            if (ref.watch(connectionProvider).value
                case Online(:final socketPath) when socketPath.isNotEmpty)
              SliverToBoxAdapter(child: SettingsNote(text: socketPath)),

            // Room for the floating dock, which is drawn over this page by the
            // shell above. Taken from the dock's own constant so the two cannot
            // drift.
            SliverToBoxAdapter(
              child: SizedBox(height: HerdrDock.reserveOf(context)),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortHost(WidgetRef ref) {
    final host = ref.watch(currentHostProvider);
    return host == null ? '—' : '${host.host}:${host.port}';
  }

  /// Opens the screen that asks for four digits.
  ///
  /// [PinSetupMode.create] is the switch being turned on; the other two both
  /// begin by proving the current PIN — see [PinSetupPage] for why a lock that
  /// can be switched off by whoever is holding the phone is not a lock.
  void _openPinSetup(BuildContext context, PinSetupMode mode) {
    unawaited(HapticFeedback.selectionClick());
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => PinSetupPage(mode: mode)),
    );
  }

  /// Asks before turning the lock off, then asks for the PIN.
  ///
  /// TWO STEPS ON PURPOSE. The dialog explains what is about to be lost — a
  /// switch that flips silently is a switch nobody trusts — and the PIN screen
  /// after it is the part that matters: without it, this row is a way for
  /// somebody holding an unlocked phone to remove the lock and keep it.
  Future<void> _confirmRemoveLock(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.lockRemoveTitle),
        content: Text(l10n.lockRemoveBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: actionSheetLabel(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: actionSheetLabel(l10n.lockRemoveAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    _openPinSetup(context, PinSetupMode.remove);
  }
}

/// A row that opens another screen, with the current state on the right.
///
/// The iOS disclosure idiom, and the value is what makes it worth having: a row
/// that says only "Key bar" tells you nothing about what is behind it, while
/// "Key bar — 13 keys" answers the question without a tap.
/// The colour-scheme row: what is selected, as a picture.
///
/// The swatch is the point of the row. A scheme's name is not a colour, so a
/// row reading "Catppuccin Mocha" tells you nothing until you have opened the
/// picker and come back — which is a round trip to learn something this row
/// could have said in the space it was already using.
class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.label,
    required this.colors,
    required this.theme,
    required this.onTap,
  });

  final String label;
  final HerdrColors colors;
  final ThemeDefinition? theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = theme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SettingsRow(
        label: label,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current == null)
              ThemeSwatch.builtIn(edge: colors.hairline)
            else
              ThemeSwatch.fromPalette(current.palette, edge: colors.hairline),
            const SizedBox(width: Space.sm),
            Text(
              current?.name ?? l10n.themesBuiltIn,
              style: TextStyle(color: colors.textFaint, fontSize: TextSize.note),
            ),
            const SizedBox(width: Space.xs),
            Icon(
              CupertinoIcons.chevron_forward,
              size: 15,
              color: colors.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「检查更新」, carrying the answer the last check produced.
///
/// A ROW THAT IS AN ACTION AND A RESULT, which is unusual on this screen and
/// deliberate: every other row here changes a setting, while this one does
/// something and reports what came of it. The value on the right IS the report,
/// because a row reading only "检查更新" tells the user nothing until they press
/// it — and pressing it is the thing they were trying to avoid.
class _CheckUpdateRow extends ConsumerWidget {
  const _CheckUpdateRow({required this.colors});

  final HerdrColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(updateControllerProvider);
    final latest = status.latest;
    final current = ref.watch(appVersionProvider);
    // The comparison is made HERE rather than trusted from the state, so a
    // version remembered from a previous launch stops being news the moment the
    // app is updated — which is exactly what would otherwise leave "有新版本
    // 0.2.0" sitting under a 0.2.0 build.
    final newer = (current != null && latest != null && latest.isNewerThan(current))
        ? latest
        : null;

    final value = switch (status.phase) {
      UpdateChecking() => l10n.updateRowChecking,
      // Before the failure cases: a download that failed still has something to
      // announce, and "有新版本" is more useful than "上次检查失败" — the latter is
      // about the attempt, this one about the thing.
      _ when newer != null => l10n.updateRowAvailable(newer.toString()),
      UpdateFailed() => l10n.updateRowFailed,
      UpdateIdle() =>
        status.checkedAt == null ? l10n.updateRowNever : l10n.updateRowUpToDate,
      _ => l10n.updateRowUpToDate,
    };

    return _Disclosure(
      label: l10n.settingsCheckUpdate,
      colors: colors,
      value: value,
      valueTint: newer == null ? null : colors.accent,
      onTap: () => showUpdateSheet(context),
    );
  }
}

/// Picks how the app decides whether to keep clear of the system's edge
/// gestures.
///
/// A DROPDOWN, not a switch and not a segmented control. A switch would force
/// the question into yes/no when the real default is "let the app work it out";
/// a segmented control would put four words on one line and break the row shape
/// every other setting uses. A dropdown says "this row has a value, tap to
/// change it" — the same shape as the colour-scheme row directly above it, one
/// level down.
class _SafetyMarginRow extends StatelessWidget {
  const _SafetyMarginRow({
    required this.colors,
    required this.value,
    required this.onChanged,
  });

  final HerdrColors colors;
  final SafetyInsetMode value;
  final ValueChanged<SafetyInsetMode> onChanged;

  static String _label(AppLocalizations l10n, SafetyInsetMode mode) =>
      switch (mode) {
        SafetyInsetMode.auto => l10n.safetyDefault,
        SafetyInsetMode.alwaysOn => l10n.safetyOn,
        SafetyInsetMode.alwaysOff => l10n.safetyOff,
      };

  /// The hook a device check uses, per option.
  ///
  /// The row and the menu items show the SAME three words, so a check that
  /// addressed them by label had two candidates for the second tap, a coin flip
  /// that passes most of the time.
  static String _id(SafetyInsetMode mode) => switch (mode) {
        SafetyInsetMode.auto => UiId.safetyDefault,
        SafetyInsetMode.alwaysOn => UiId.safetyAlwaysOn,
        SafetyInsetMode.alwaysOff => UiId.safetyAlwaysOff,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Builder(
      // The menu is positioned from a rect measured BEFORE any await, which is
      // why this takes a builder context rather than the page's — see
      // `menuAnchorRect`.
      builder: (rowContext) => Semantics(
        identifier: UiId.safetyMargin,
        button: true,
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          final picked = await showHerdrMenu<SafetyInsetMode>(
            rowContext,
            anchorRect: menuAnchorRect(rowContext),
            items: [
              for (final mode in SafetyInsetMode.values)
                HerdrMenuItem(
                  value: mode,
                  label: _label(l10n, mode),
                  selected: mode == value,
                  identifier: _id(mode),
                ),
            ],
          );
          if (picked == null || picked == value) return;
          unawaited(HapticFeedback.selectionClick());
          onChanged(picked);
        },
        child: SettingsRow(
          label: l10n.settingsSafety,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _label(l10n, value),
                style: TextStyle(color: colors.textFaint, fontSize: TextSize.note),
              ),
              const SizedBox(width: Space.xs),
              Icon(
                CupertinoIcons.chevron_down,
                size: 13,
                color: colors.textFaint,
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.label,
    required this.colors,
    required this.value,
    required this.onTap,
    this.valueTint,
  });

  final String label;
  final HerdrColors colors;
  final String value;
  final VoidCallback onTap;

  /// Overrides the value's colour when the row has something to announce.
  ///
  /// ACCENT ONLY — never one of the four status colours. Those mean "what an
  /// agent is doing", and a settings row borrowing one would be the same
  /// mistake the switch's active colour made once already.
  final Color? valueTint;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SettingsRow(
        label: label,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: TextStyle(
                color: valueTint ?? colors.textFaint,
                fontSize: TextSize.note,
              ),
            ),
            const SizedBox(width: Space.xs),
            Icon(
              CupertinoIcons.chevron_forward,
              size: 15,
              color: colors.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// A segmented choice, sized to its content and sitting on the label's line.
class _Segmented<T extends Object> extends StatelessWidget {
  const _Segmented({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  final String label;
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      label: label,
      trailing: CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        backgroundColor: colors.surfaceRaised,
        thumbColor: colors.surface,
        // Compact on purpose: a full-width segmented control in a settings list
        // is a control that has swallowed its own row, and three of them stacked
        // is most of the page.
        children: {
          for (final (optionValue, optionLabel) in options)
            optionValue: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 5,
                horizontal: Space.sm,
              ),
              child: Text(
                optionLabel,
                style: TextStyle(
                  color: colors.text,
                  fontSize: TextSize.note,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        },
        onValueChanged: (v) {
          // The control reports `T?`; a null here would mean no selection, which
          // cannot happen for a group with a value — ignore it rather than
          // assert and take the page down.
          if (v != null) {
            unawaited(HapticFeedback.selectionClick());
            onChanged(v);
          }
        },
      ),
    );
  }
}

/// A read-only row: a name and what it is set to.
class _Value extends StatelessWidget {
  const _Value({
    required this.label,
    required this.value,
    required this.colors,
    this.mono = false,
  });

  final String label;
  final String value;
  final HerdrColors colors;

  /// Machine voice for machine facts — a version and a socket path are things
  /// the user compares against a terminal, not prose.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      label: label,
      trailing: Text(
        value,
        textAlign: TextAlign.right,
        style: TextStyle(
          color: colors.textDim,
          fontSize: mono ? TextSize.meta : TextSize.body,
          fontFamily: mono ? HerdrFonts.mono : null,
          height: 1.3,
        ),
      ),
    );
  }
}

/// A size, changed in steps.
///
/// WHY NOT A SLIDER. A slider answers "roughly how much" on a scale where the
/// exact value does not matter, and it costs a full row of vertical space to
/// do it. This is the opposite kind of setting: there are eight sensible values
/// on the whole range, they are named by percentages the user repeats to
/// themselves ("a bit bigger than normal"), and the reset point — 100% — is
/// something people go back to. A continuous control makes all three of those
/// harder: it cannot land on 100% by itself, it shows a fraction of a pixel of
/// travel per step, and it takes 40% of the card to do it in.
///
/// The stepper also matches the row shape every other setting uses: label on
/// the left, control on the right, one line.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.colors,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    // Rounded to the step's own precision so a value that arrived from storage
    // as 1.0000000001 still reads as 100%, and so stepping from it is exact
    // rather than drifting a hundredth every press.
    final steps = ((max - min) / step).round();
    final index = ((value - min) / step).round().clamp(0, steps);
    final current = min + index * step;

    void go(int delta) {
      final next = (index + delta).clamp(0, steps);
      if (next == index) return;
      unawaited(HapticFeedback.selectionClick());
      onChanged(min + next * step);
    }

    return SettingsRow(
      label: label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            icon: CupertinoIcons.minus,
            colors: colors,
            enabled: index > 0,
            onPressed: () => go(-1),
          ),
          SizedBox(
            // Fixed width, tabular figures: without both, "100%" and "85%" make
            // the two buttons jump sideways as the number changes width.
            width: 54,
            child: Text(
              '${(current * 100).round()}%',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: TextSize.strong,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _StepButton(
            icon: CupertinoIcons.plus,
            colors: colors,
            enabled: index < steps,
            onPressed: () => go(1),
          ),
        ],
      ),
    );
  }
}

/// A round, unlabelled step button.
///
/// Disabled at the ends rather than hidden: a control that disappears at the
/// limit makes the limit look like a bug, and the row's width would change
/// under the user's thumb as they reach it.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.colors,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final HerdrColors colors;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: Container(
          width: _stepButtonSize,
          height: _stepButtonSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceRaised,
            borderRadius: BorderRadius.circular(Radii.uniform),
          ),
          child: Icon(
            icon,
            size: 15,
            color: enabled ? colors.accent : colors.textFaint,
          ),
        ),
      ),
    );
  }
}

/// The tap target. 32 is the smallest that still clears the 44-point guideline
/// once the row's own vertical padding is counted, and it keeps the row the same
/// height as every other one on the screen.
const double _stepButtonSize = 32;

/// The row that picks and shows the phone folder downloads land in.
///
/// A stateful row rather than three lines in the list, because it owns one
/// asynchronous question the rest of the page does not have: whether the stored
/// grant is STILL VALID. Android keeps a tree permission across restarts, but
/// the user can delete the folder or revoke it in system settings, and a row
/// that keeps saying `Download/Herdr` while every download fails is worse than
/// one that admits it needs picking again.
class _DownloadDirectoryRow extends ConsumerStatefulWidget {
  const _DownloadDirectoryRow({
    required this.colors,
    required this.uri,
    required this.label,
  });

  final HerdrColors colors;
  final String? uri;
  final String? label;

  @override
  ConsumerState<_DownloadDirectoryRow> createState() =>
      _DownloadDirectoryRowState();
}

class _DownloadDirectoryRowState extends ConsumerState<_DownloadDirectoryRow> {
  /// Null while unknown, then whether the stored grant still works.
  bool? _valid;

  /// Non-null on a platform that HANDS THE APP A FOLDER rather than asking for
  /// one. When it is set there is nothing to pick, so the row stops being a
  /// control and becomes a statement — see the build method and
  /// `local/apple_download_target.dart`.
  GrantedDirectory? _implicit;

  /// True while the system picker is open, so a fast double tap cannot open two.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void didUpdateWidget(_DownloadDirectoryRow old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) unawaited(_check());
  }

  Future<void> _check() async {
    final target = ref.read(downloadTargetProvider);
    if (target == null) {
      if (mounted) setState(() => _valid = null);
      return;
    }
    // ASKED BEFORE THE STORED URI. On Android this is null and the row behaves
    // exactly as it did; on iOS it is the app's own folder, and the stored uri
    // (which a fresh install does not have) is beside the point.
    final implicit = await target.defaultDirectory();
    final uri = implicit?.uri ?? widget.uri;
    if (uri == null || uri.isEmpty) {
      if (mounted) {
        setState(() {
          _implicit = implicit;
          _valid = null;
        });
      }
      return;
    }
    final ok = await target.hasAccess(uri);
    if (mounted) {
      setState(() {
        _implicit = implicit;
        _valid = ok;
      });
    }
  }

  Future<void> _pick() async {
    if (_picking) return;
    final target = ref.read(downloadTargetProvider);
    if (target == null) return;

    setState(() => _picking = true);
    try {
      final picked = await target.pick();
      // Null is a cancellation, which is an answer: the row keeps showing
      // whatever it showed before and nothing is reported as a failure.
      if (picked == null) return;
      await ref.read(settingsProvider.notifier).setDownloadDirectory(
            uri: picked.uri,
            label: picked.label,
          );
      if (mounted) setState(() => _valid = true);
    } on LocalWriteException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.settingsDownloadDir),
          content: Text(e.detail ?? l10n.errorGeneric),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.actionClose),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = widget.colors;
    final hasLabel = (widget.label ?? '').isNotEmpty;
    // THE PLATFORM'S OWN FOLDER, IF IT HAS ONE, WINS OVER THE STORED ONE. On iOS
    // there is nothing to choose, so `settingsDownloadDirLabel` is either empty
    // (fresh install) or a copy of this name from a previous launch.
    final implicit = _implicit;
    final revoked = _valid == false && implicit == null;

    final text = implicit?.label ??
        (revoked
            ? l10n.settingsDownloadDirUnset
            : (hasLabel ? widget.label! : l10n.settingsDownloadDirUnset));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // A FOLDER THE PLATFORM HANDS OVER IS NOT A CONTROL. The chevron and the
      // tap both promise a system sheet, and on iOS there is no sheet to open —
      // tapping would do nothing visible, which reads as a broken row rather
      // than as a folder the app already has.
      onTap: implicit != null ? null : () => unawaited(_pick()),
      child: SettingsRow(
        label: l10n.settingsDownloadDir,
        // TWO LINES, because a granted folder should say so and a revoked one
        // has to say something the user can act on — and "未选择" would be a
        // lie once a folder HAS been chosen but lost its permission.
        //
        // The iOS note answers the only question that row leaves open, which is
        // WHERE this folder is: the app's own container is not a place a user
        // can picture, and the Files path is. It is not a revocation warning —
        // nothing there can be revoked.
        note: implicit != null
            ? l10n.settingsDownloadDirAppleNote
            : (revoked ? l10n.settingsDownloadDirRevoked : null),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: TextStyle(
                color: revoked ? colors.statusTextDied : colors.textDim,
                fontSize: TextSize.body,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
            if (implicit == null) ...[
              const SizedBox(width: Space.xs),
              Icon(
                CupertinoIcons.chevron_forward,
                size: 14,
                color: colors.textFaint,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
