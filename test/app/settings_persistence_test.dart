import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every setting this app writes must survive a restart.
///
/// THIS FILE EXISTS BECAUSE NONE OF THEM DID. `SettingsNotifier` had a
/// `hydrate(prefs)` method with a doc comment promising it ran "once during
/// bootstrap"; nothing called it, so the app wrote settings forever and read
/// them never. The symptom is the worst kind: the switch flips, the theme
/// applies, the text resizes — everything works until you close the app, and
/// then the app quietly opens on defaults. All the writes were right. There
/// was simply no read, and no test asked for one.
///
/// So the two tests below are the two halves that were missing: the app opens
/// on what was stored, and what the app stores is there for the next launch.
void main() {
  /// A container standing in for one app launch: `main()` awaits
  /// `SharedPreferences.getInstance()` and injects it, and this is that.
  ProviderContainer launch(SharedPreferences prefs) =>
      ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);

  test('the app opens on what was stored, not on defaults', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // Deliberately the non-default value for every setting, so a field that
      // silently falls back to its default fails rather than passing.
      'flutter.settings.themeId': 'nord',
      'flutter.settings.themeMode': 'light',
      'flutter.settings.languageCode': 'en',
      'flutter.settings.glassEnabled': false,
      'flutter.settings.notificationsEnabled': false,
      'flutter.settings.autoConnect': true,
      'flutter.settings.textScale': 1.2,
      'flutter.settings.terminalTextScale': 1.4,
      'flutter.settings.keyBarKeys': <String>['esc', 'ctrl'],
      'flutter.settings.iconSet': 'system',
      'flutter.settings.autoUpdateCheck': false,
      'flutter.settings.sessionCommand': 'zsh -l',
      'flutter.settings.scrollbackLines': 12345,
      'flutter.settings.ledgerEnabled': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = launch(prefs).read(settingsProvider);

    expect(settings.themeId, 'nord');
    expect(settings.themeMode, AppThemeMode.light);
    expect(settings.languageCode, 'en');
    // BOTH OF THESE ARE `false` ON DISK AND `true` BY DEFAULT, which is the
    // only shape that tests the thing that actually matters here: a default is
    // not a value that overwrites a choice. See `SettingsState.glassEnabled`.
    expect(settings.glassEnabled, isFalse);
    expect(settings.notificationsEnabled, isFalse);
    expect(settings.autoConnect, isTrue);
    expect(settings.textScale, 1.2);
    expect(settings.terminalTextScale, 1.4);
    expect(settings.keyBarKeys, [SoftKey.esc, SoftKey.ctrl]);
    expect(settings.iconSet, AppIconSet.system);
    expect(settings.autoUpdateCheck, isFalse);
    expect(settings.sessionCommand, 'zsh -l');
    expect(settings.scrollbackLines, 12345);
    expect(settings.ledgerEnabled, isTrue);
  });

  test('what one launch writes is what the next launch reads', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    final first = launch(prefs);
    await first.read(settingsProvider.notifier).setThemeId('gruvbox');
    // Written as `false` — the opposite of the default — so this test proves a
    // stored choice wins over the default rather than agreeing with it.
    await first.read(settingsProvider.notifier).setGlassEnabled(enabled: false);
    await first.read(settingsProvider.notifier).setKeyBarKeys([SoftKey.esc]);
    await first.read(settingsProvider.notifier).setIconSet(AppIconSet.system);
    await first.read(settingsProvider.notifier).setAutoUpdateCheck(enabled: false);
    await first.read(settingsProvider.notifier).setSessionCommand('fish -l');
    await first.read(settingsProvider.notifier).setScrollbackLines(20000);
    await first.read(settingsProvider.notifier).setLedgerEnabled(enabled: true);

    // A second launch against the same store — which is what closing and
    // reopening the app does.
    final second = launch(prefs).read(settingsProvider);
    expect(second.themeId, 'gruvbox');
    expect(second.glassEnabled, isFalse);
    expect(second.keyBarKeys, [SoftKey.esc]);
    expect(second.iconSet, AppIconSet.system);
    expect(second.autoUpdateCheck, isFalse);
    expect(second.sessionCommand, 'fish -l');
    expect(second.scrollbackLines, 20000);
    expect(second.ledgerEnabled, isTrue);

    // And clearing goes all the way back to the built-in palette rather than
    // leaving a stale id that no longer exists.
    await first.read(settingsProvider.notifier).setThemeId(null);
    expect(launch(prefs).read(settingsProvider).themeId, isNull);
  });

  test('an empty store opens on the documented defaults', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = launch(await SharedPreferences.getInstance()).read(settingsProvider);
    expect(settings, isA<SettingsState>());
    // Nord, not the built-in: the app ships twelve schemes and the built-in is
    // the one nobody picked. See `defaultThemeId`.
    expect(settings.themeId, defaultThemeId);
    expect(settings.themeMode, AppThemeMode.system);
    // Glass is ON by default: a design nobody sees until they find a switch is
    // not the design, and this app's material is the point of it.
    expect(settings.glassEnabled, isTrue);
    expect(settings.autoConnect, isFalse);
    // The beta ledger is OFF out of the box: it reads another program's private
    // files, so it is the one screen whose failures the user should opt into.
    expect(settings.ledgerEnabled, isFalse);
    expect(settings.textScale, 1.0);
    expect(settings.keyBarKeys, defaultKeyBar);
    // The themed set is the DELIBERATE default — it was chosen with the
    // monochrome alternative rendered beside it — so an empty store opening on
    // it is correct rather than a fallback nobody thought about.
    expect(settings.iconSet, AppIconSet.themed);
    // And this one is ON by default: one bounded request per launch, silent on
    // failure, so the app cannot sit three releases behind.
    expect(settings.autoUpdateCheck, isTrue);
    // The chat window is ON by default: it is the answer to the thing this app
    // is for, and a feature nobody can find is a feature nobody has.
    expect(settings.composerEnabled, isTrue);
    // And the shell command defaults to attach-or-create: a phone terminal
    // that loses its session every time you close the app is one you stop
    // reaching for.
    expect(settings.sessionCommand, defaultSessionCommand);
    // Ten thousand lines: long enough to be worth scrolling, small enough
    // that a session does not hold a phone's worth of cells for nothing.
    expect(settings.scrollbackLines, defaultScrollbackLines);
  });

  test('turning the chat window off survives a relaunch', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final first = launch(await SharedPreferences.getInstance());
    await first.read(settingsProvider.notifier).setComposerEnabled(enabled: false);

    final second = launch(await SharedPreferences.getInstance()).read(settingsProvider);
    expect(second.composerEnabled, isFalse);
  });

  test('the scrollback depth is clamped wherever it comes from', () async {
    // A NUMBER STORED BY A BUILD THAT ALLOWED A DIFFERENT RANGE is the case
    // this guards: the setting is a memory bound as well as a reading distance,
    // so a value from disk is not automatically a value that is safe to honour.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.settings.scrollbackLines': 9999999,
    });
    final stored = launch(await SharedPreferences.getInstance());
    expect(stored.read(settingsProvider).scrollbackLines, maxScrollbackLines);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = await SharedPreferences.getInstance();
    final live = launch(store);

    // And the same on the way in, because a terminal with no history cannot be
    // scrolled at all — the gesture that reveals it would look broken.
    await live.read(settingsProvider.notifier).setScrollbackLines(0);
    expect(live.read(settingsProvider).scrollbackLines, minScrollbackLines);

    await live.read(settingsProvider.notifier).setScrollbackLines(9999999);
    expect(live.read(settingsProvider).scrollbackLines, maxScrollbackLines);

    // CLAMPED ON THE WAY TO DISK TOO, read back the way a relaunch would: a
    // store that kept the number that was refused would hand it back next time.
    expect(launch(store).read(settingsProvider).scrollbackLines, maxScrollbackLines);
  });
}
