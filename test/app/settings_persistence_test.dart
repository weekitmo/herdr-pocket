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
      'flutter.settings.glassEnabled': true,
      'flutter.settings.notificationsEnabled': false,
      'flutter.settings.autoConnect': true,
      'flutter.settings.textScale': 1.2,
      'flutter.settings.terminalTextScale': 1.4,
      'flutter.settings.keyBarKeys': <String>['esc', 'ctrl'],
      'flutter.settings.iconSet': 'system',
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = launch(prefs).read(settingsProvider);

    expect(settings.themeId, 'nord');
    expect(settings.themeMode, AppThemeMode.light);
    expect(settings.languageCode, 'en');
    expect(settings.glassEnabled, isTrue);
    expect(settings.notificationsEnabled, isFalse);
    expect(settings.autoConnect, isTrue);
    expect(settings.textScale, 1.2);
    expect(settings.terminalTextScale, 1.4);
    expect(settings.keyBarKeys, [SoftKey.esc, SoftKey.ctrl]);
    expect(settings.iconSet, AppIconSet.system);
  });

  test('what one launch writes is what the next launch reads', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    final first = launch(prefs);
    await first.read(settingsProvider.notifier).setThemeId('gruvbox');
    await first.read(settingsProvider.notifier).setGlassEnabled(enabled: true);
    await first.read(settingsProvider.notifier).setKeyBarKeys([SoftKey.esc]);
    await first.read(settingsProvider.notifier).setIconSet(AppIconSet.system);

    // A second launch against the same store — which is what closing and
    // reopening the app does.
    final second = launch(prefs).read(settingsProvider);
    expect(second.themeId, 'gruvbox');
    expect(second.glassEnabled, isTrue);
    expect(second.keyBarKeys, [SoftKey.esc]);
    expect(second.iconSet, AppIconSet.system);

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
    expect(settings.glassEnabled, isFalse);
    expect(settings.autoConnect, isFalse);
    expect(settings.textScale, 1.0);
    expect(settings.keyBarKeys, defaultKeyBar);
    // The themed set is the DELIBERATE default — it was chosen with the
    // monochrome alternative rendered beside it — so an empty store opening on
    // it is correct rather than a fallback nobody thought about.
    expect(settings.iconSet, AppIconSet.themed);
  });
}
