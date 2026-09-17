import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which theme the user asked for.
enum AppThemeMode { system, light, dark }

/// How the app decides whether to keep clear of the system's edge gestures.
///
/// THE PROBLEM THIS EXISTS FOR. Android's gesture navigation puts a swipe band
/// along the bottom edge — a horizontal bar you drag sideways to switch apps.
/// Simple press-drag-release gestures that START inside that band are consumed
/// by the system and never reach the app (Flutter's own words, in
/// `MediaQueryData.systemGestureInsets`). So a row of controls sitting in the
/// band does not merely risk a mis-tap: the app may never see the gesture at
/// all, and the user sees a button that "does not work".
///
/// [auto] is the honest default: read the platform's own report. [alwaysOn] and
/// [alwaysOff] exist because that report is not trustworthy on every OEM
/// build, and a safety margin that cannot be overridden is worse than no
/// margin when it is wrong.
enum SafetyInsetMode {
  /// Trust [MediaQueryData.systemGestureInsets] — on when the platform says an
  /// edge is reserved, off when it says nothing is.
  auto,

  /// Keep the margin whatever the platform reports.
  alwaysOn,

  /// Keep no margin, whatever the platform reports.
  alwaysOff,
}

/// Whether to keep the margin, given the mode and what the platform said.
///
/// Pure and separate from the widget that reads `MediaQuery`, because this is
/// the decision the setting is FOR and it should be assertable without a
/// binding.
bool shouldKeepSafetyInset(
  SafetyInsetMode mode, {
  required bool systemGestures,
}) =>
    switch (mode) {
      SafetyInsetMode.auto => systemGestures,
      SafetyInsetMode.alwaysOn => true,
      SafetyInsetMode.alwaysOff => false,
    };

/// Which icon set the chrome is drawn with.
/// TWO SETS, AND THE DIFFERENCE IS NOT DECORATION. The platform's own glyphs
/// are monochrome by construction, which is what this app's colour rules ask
/// for almost everywhere. The alternative is a set whose colours can be taken
/// from the active scheme, which is the only way an icon can be more than one
/// tone without introducing a hue the palette does not have.
///
/// The comparison that decided it is still on screen: Settings -> "Icons, three
/// ways" draws both, plus the third option (the set's own fixed palette) that
/// was rejected for arguing with all twelve schemes.
enum AppIconSet {
  /// `CupertinoIcons` — one tint, no colour, exactly what shipped before.
  system,

  /// The themed set, every colour taken from the active colour scheme.
  themed,
}

/// The colour scheme a fresh install opens on.
///
/// NORD, and it is a product decision rather than a leftover: the app ships a
/// gallery of twelve schemes and the built-in palette is the one nobody chose
/// — it is what this project happened to start with. Opening on a scheme the
/// user can name makes the terminal look like a terminal on first launch, and
/// "Herdr Pocket 默认" is still one tap away in the picker.
const String defaultThemeId = 'nord';

/// What is stored when the user picks the BUILT-IN palette on purpose.
///
/// A sentinel rather than removing the key, because "never chose" and "chose
/// the built-in" have to be different records: if choosing the built-in meant
/// deleting the key, the next launch would fall back to [defaultThemeId] and
/// silently overrule the user. That is the same class of bug as
/// `SettingsState.autoConnect` being ignored — a preference that survives only
/// until the process restarts.
const String builtInThemeId = '__builtin__';

/// The user's appearance and language choices.
///
/// Deliberately hand-rolled rather than generated: these are three scalars, and
/// a codegen round-trip for three scalars buys nothing but a build step.
class SettingsState {
  const SettingsState({
    this.themeMode = AppThemeMode.system,
    this.languageCode,
    this.glassEnabled = false,
    this.notificationsEnabled = true,
    this.autoConnect = false,
    this.textScale = 1.0,
    this.terminalTextScale = 1.0,
    this.keyBarKeys = defaultKeyBar,
    this.themeId = defaultThemeId,
    this.iconSet = AppIconSet.themed,
    this.safetyInset = SafetyInsetMode.auto,
    this.fileTransferEnabled = false,
    this.composerEnabled = true,
    this.downloadDirUri,
    this.downloadDirLabel,
    this.autoUpdateCheck = false,
  });

  final AppThemeMode themeMode;

  /// null means "follow the system locale".
  final String? languageCode;

  /// Liquid Glass on chrome. Defaults OFF: the target device is a 2018
  /// mid-ranger, and whip measured native blur causing tab-switch stalls on
  /// Android. Glass is an upgrade, not the baseline (ADR-006).
  final bool glassEnabled;

  /// Whether a waiting agent raises a notification. On by default: the whole
  /// point of the app is not having to watch the board, and permission is asked
  /// separately at startup rather than being implied by this flag.
  final bool notificationsEnabled;

  /// Whether the app dials the machine on launch.
  ///
  /// OFF, and that is the point rather than a default nobody thought about.
  /// Opening an app is not a request to open a network connection: it used to
  /// dial before the user had chosen anything, which meant an SSH handshake
  /// (and, with password auth, a connection the user did not ask for) at the
  /// moment they were only looking at a list. Asking first also makes the
  /// first screen honest — "not connected" is a state, not a failure.
  final bool autoConnect;

  final double textScale;
  final double terminalTextScale;

  /// The colour scheme the user picked, or null for the app's own design.
  ///
  /// Null means the BUILT-IN palette, which is now a choice rather than the
  /// default — see [defaultThemeId]. Selecting a scheme also decides
  /// light-vs-dark: the scheme's author already answered that question, and
  /// pairing a dark scheme with a light chrome is a combination nobody
  /// designed.
  final String? themeId;

  /// Which glyphs the dock, the terminal's toolbar and the machine entry use.
  ///
  /// DEFAULTS TO [AppIconSet.themed]: it was chosen deliberately, with the
  /// monochrome alternative rendered beside it, so shipping the other one would
  /// be ignoring the decision. Switching back is one row in Settings.
  final AppIconSet iconSet;

  /// How much room the app keeps clear of the system's own edge gestures.
  ///
  /// Defaults to [SafetyInsetMode.auto] — the app should not spend a user's
  /// pixels on a guess about their phone.
  final SafetyInsetMode safetyInset;

  /// Whether the file browser may move files to and from the phone.
  ///
  /// OFF by default, and not out of caution: turning it on is what makes the
  /// app ask for a folder, and a folder nobody asked to grant is a permission
  /// prompt with no context. The setting exists because the answer to "may this
  /// app write files on my phone" belongs to the user and not to a first run.
  final bool fileTransferEnabled;

  /// The folder the user granted, as an Android SAF tree URI.
  ///
  /// A URI rather than a path, because on Android 10+ a path is not a thing the
  /// app is allowed to write to. Null until a folder is chosen.
  final String? downloadDirUri;

  /// How that folder is shown to the user, e.g. `Download/Herdr Pocket`.
  ///
  /// Stored rather than derived at paint time: turning a SAF URI back into a
  /// readable name needs a platform call, and a settings row must not block on
  /// one.
  final String? downloadDirLabel;

  /// Whether the app asks GitHub for a newer version on launch.
  ///
  /// OFF, and the reason is the same one [autoConnect] carries: opening an app
  /// is not a request to make a network connection. It is also the difference
  /// between an app that is quiet on a phone in a pocket and one that lights up
  /// a radio every time it is tapped. The manual「检查更新」row is right there.
  ///
  /// When it IS on, the check is one request per launch, silent on failure, and
  /// a single toast when there is something new — never a dialog.
  final bool autoUpdateCheck;

  /// Which keys the terminal's key bar offers, in the order it offers them.
  ///
  /// Stored as [SoftKey]s rather than ids here and as ids on disk, so the
  /// catalogue can grow — and a key can be renamed — without a stored
  /// preference turning into a crash or a silently missing button.
  final List<SoftKey> keyBarKeys;

  /// Whether the terminal offers its chat window.
  ///
  /// ON by default, because it is the answer to the thing this app is for: a
  /// message typed on a phone over a link that drops characters. Off is for
  /// someone who wants the key bar and nothing else above it — the composer
  /// takes a strip of a small screen, and that is a real cost on a 2018 phone.
  /// Switching it off HIDES the button rather than disabling it: an affordance
  /// that is permanently unavailable is a worse answer than one that is absent.
  final bool composerEnabled;

  SettingsState copyWith({
    AppThemeMode? themeMode,
    String? languageCode,
    bool clearLanguage = false,
    bool? glassEnabled,
    bool? notificationsEnabled,
    bool? autoConnect,
    double? textScale,
    double? terminalTextScale,
    List<SoftKey>? keyBarKeys,
    String? themeId,
    bool clearTheme = false,
    AppIconSet? iconSet,
    SafetyInsetMode? safetyInset,
    bool? fileTransferEnabled,
    String? downloadDirUri,
    String? downloadDirLabel,
    bool clearDownloadDir = false,
    bool? autoUpdateCheck,
    bool? composerEnabled,
  }) {
    return SettingsState(
      themeMode: themeMode ?? this.themeMode,
      languageCode: clearLanguage ? null : (languageCode ?? this.languageCode),
      glassEnabled: glassEnabled ?? this.glassEnabled,
      notificationsEnabled:
          notificationsEnabled ?? this.notificationsEnabled,
      autoConnect: autoConnect ?? this.autoConnect,
      textScale: textScale ?? this.textScale,
      terminalTextScale: terminalTextScale ?? this.terminalTextScale,
      keyBarKeys: keyBarKeys ?? this.keyBarKeys,
      themeId: clearTheme ? null : (themeId ?? this.themeId),
      iconSet: iconSet ?? this.iconSet,
      safetyInset: safetyInset ?? this.safetyInset,
      fileTransferEnabled: fileTransferEnabled ?? this.fileTransferEnabled,
      composerEnabled: composerEnabled ?? this.composerEnabled,
      // Both or neither: a label without a URI names a folder the app cannot
      // write to, and a URI without a label is a row full of percent-escapes.
      downloadDirUri:
          clearDownloadDir ? null : (downloadDirUri ?? this.downloadDirUri),
      downloadDirLabel:
          clearDownloadDir ? null : (downloadDirLabel ?? this.downloadDirLabel),
      autoUpdateCheck: autoUpdateCheck ?? this.autoUpdateCheck,
    );
  }
}

/// Reads and writes the three persisted appearance scalars.
///
/// Kept synchronous-after-load so the first frame can already be correct; a
/// flash of the wrong theme on launch is the kind of thing that reads as
/// "cheap" and costs nothing to avoid.
class SettingsNotifier extends Notifier<SettingsState> {
  static const _kTheme = 'settings.themeMode';
  static const _kLanguage = 'settings.languageCode';
  static const _kGlass = 'settings.glassEnabled';
  static const _kNotifications = 'settings.notificationsEnabled';
  static const _kAutoConnect = 'settings.autoConnect';
  static const _kTextScale = 'settings.textScale';
  static const _kTerminalTextScale = 'settings.terminalTextScale';
  static const _kKeyBar = 'settings.keyBarKeys';
  static const _kPalette = 'settings.themeId';
  static const _kIconSet = 'settings.iconSet';
  static const _kSafetyInset = 'settings.safetyInset';
  static const _kFileTransfer = 'settings.fileTransferEnabled';
  static const _kComposer = 'settings.composerEnabled';
  static const _kDownloadDirUri = 'settings.downloadDirUri';
  static const _kDownloadDirLabel = 'settings.downloadDirLabel';
  static const _kAutoUpdate = 'settings.autoUpdateCheck';

  /// Opens on the stored settings, read SYNCHRONOUSLY.
  ///
  /// THIS IS WHERE THE SAVED STATE IS READ, and it used to be nowhere. There
  /// was a `hydrate(prefs)` method here that a doc comment claimed was "called
  /// once during bootstrap" — and nothing called it, so every setting this app
  /// ever wrote was written and then never read back. Turning on Liquid Glass,
  /// picking a colour scheme, resizing the text: all of it survived exactly
  /// until the next launch. The writes were fine; there was no read.
  ///
  /// The read can be synchronous because `main()` awaits
  /// [SharedPreferences.getInstance] before `runApp` and injects it, which is
  /// the whole reason that override exists. Doing it here rather than in
  /// bootstrap also means there is no window in which the app is running with
  /// default settings — the first frame is already the user's own.
  @override
  SettingsState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return SettingsState(
      themeMode: _themeFrom(prefs.getString(_kTheme)),
      languageCode: prefs.getString(_kLanguage),
      glassEnabled: prefs.getBool(_kGlass) ?? false,
      notificationsEnabled: prefs.getBool(_kNotifications) ?? true,
      autoConnect: prefs.getBool(_kAutoConnect) ?? false,
      textScale: prefs.getDouble(_kTextScale) ?? 1.0,
      terminalTextScale: prefs.getDouble(_kTerminalTextScale) ?? 1.0,
      keyBarKeys: _keysFrom(prefs.getStringList(_kKeyBar)),
      themeId: _themeIdFrom(prefs.getString(_kPalette)),
      iconSet: _iconSetFrom(prefs.getString(_kIconSet)),
      safetyInset: _safetyInsetFrom(prefs.getString(_kSafetyInset)),
      fileTransferEnabled: prefs.getBool(_kFileTransfer) ?? false,
      composerEnabled: prefs.getBool(_kComposer) ?? true,
      downloadDirUri: prefs.getString(_kDownloadDirUri),
      downloadDirLabel: prefs.getString(_kDownloadDirLabel),
      autoUpdateCheck: prefs.getBool(_kAutoUpdate) ?? false,
    );
  }

  /// Picks a colour scheme, or clears back to the built-in palette.
  ///
  /// BOTH OUTCOMES ARE STORED — one as an id, the other as [builtInThemeId].
  /// An absent key no longer means "the built-in"; it means "this question was
  /// never answered", and that has to keep resolving to [defaultThemeId] or a
  /// fresh install would open on the built-in palette it did not choose.
  Future<void> setThemeId(String? id) async {
    final next = (id == null || id.isEmpty) ? null : id;
    state = next == null
        ? state.copyWith(clearTheme: true)
        : state.copyWith(themeId: next);
    await _prefs.setString(_kPalette, next ?? builtInThemeId);
  }

  /// Reads the stored scheme, distinguishing "chose the built-in" from "never
  /// chose anything".
  static String? _themeIdFrom(String? raw) {
    if (raw == null || raw.isEmpty) return defaultThemeId;
    if (raw == builtInThemeId) return null;
    return raw;
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final prefs = _prefs;
    await prefs.setString(_kTheme, mode.name);
  }

  Future<void> setLanguage(String? code) async {
    state = code == null
        ? state.copyWith(clearLanguage: true)
        : state.copyWith(languageCode: code);
    final prefs = _prefs;
    if (code == null) {
      await prefs.remove(_kLanguage);
    } else {
      await prefs.setString(_kLanguage, code);
    }
  }

  Future<void> setGlassEnabled({required bool enabled}) async {
    state = state.copyWith(glassEnabled: enabled);
    final prefs = _prefs;
    await prefs.setBool(_kGlass, enabled);
  }

  Future<void> setNotificationsEnabled({required bool enabled}) async {
    state = state.copyWith(notificationsEnabled: enabled);
    final prefs = _prefs;
    await prefs.setBool(_kNotifications, enabled);
  }

  Future<void> setAutoConnect({required bool enabled}) async {
    state = state.copyWith(autoConnect: enabled);
    final prefs = _prefs;
    await prefs.setBool(_kAutoConnect, enabled);
  }

  Future<void> setFileTransferEnabled({required bool enabled}) async {
    state = state.copyWith(fileTransferEnabled: enabled);
    final prefs = _prefs;
    await prefs.setBool(_kFileTransfer, enabled);
  }

  Future<void> setComposerEnabled({required bool enabled}) async {
    state = state.copyWith(composerEnabled: enabled);
    await _prefs.setBool(_kComposer, enabled);
  }

  Future<void> setAutoUpdateCheck({required bool enabled}) async {
    state = state.copyWith(autoUpdateCheck: enabled);
    await _prefs.setBool(_kAutoUpdate, enabled);
  }

  /// Records the folder the user granted, or clears it.
  ///
  /// The URI is the grant: it is what
  /// `ContentResolver.persistedUriPermissions` is checked against on the next
  /// launch, so losing it means the user picks the folder again. It is stored
  /// in plain preferences rather than secure storage deliberately — it is not a
  /// secret, and a token that a wipe would drop must not be one.
  Future<void> setDownloadDirectory({
    required String? uri,
    required String? label,
  }) async {
    state = uri == null
        ? state.copyWith(clearDownloadDir: true)
        : state.copyWith(downloadDirUri: uri, downloadDirLabel: label);
    final prefs = _prefs;
    if (uri == null) {
      await prefs.remove(_kDownloadDirUri);
      await prefs.remove(_kDownloadDirLabel);
    } else {
      await prefs.setString(_kDownloadDirUri, uri);
      await prefs.setString(_kDownloadDirLabel, label ?? '');
    }
  }

  Future<void> setTextScale(double scale) async {
    state = state.copyWith(textScale: scale);
    final prefs = _prefs;
    await prefs.setDouble(_kTextScale, scale);
  }

  Future<void> setTerminalTextScale(double scale) async {
    state = state.copyWith(terminalTextScale: scale);
    final prefs = _prefs;
    await prefs.setDouble(_kTerminalTextScale, scale);
  }

  Future<void> setKeyBarKeys(List<SoftKey> keys) async {
    state = state.copyWith(keyBarKeys: List.unmodifiable(keys));
    final prefs = _prefs;
    await prefs.setStringList(_kKeyBar, [for (final k in keys) k.id]);
  }

  /// Returns the stored list, or the default when nothing was ever stored.
  ///
  /// An explicitly EMPTY list is honoured rather than treated as "unset": a
  /// user who turned every key off meant it, and silently restoring the default
  /// bar is the app overruling them. Unknown ids are dropped instead of
  /// throwing — the catalogue is allowed to lose a key between releases, and a
  /// preference file that outlives a key should degrade, not break.
  static List<SoftKey> _keysFrom(List<String>? ids) {
    if (ids == null) return defaultKeyBar;
    final byId = {for (final k in SoftKey.values) k.id: k};
    return [for (final id in ids) ?byId[id]];
  }

  /// The store injected by `main()`.
  ///
  /// Not `SharedPreferences.getInstance()`: that returns a *new* load of the
  /// same file, and writing through it while the injected instance caches
  /// another copy is how a setting ends up saved and not observed.
  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  /// Picks the icon set.
  Future<void> setIconSet(AppIconSet value) async {
    state = state.copyWith(iconSet: value);
    final prefs = _prefs;
    await prefs.setString(_kIconSet, value.name);
  }

  /// Picks how the safety margin is decided.
  Future<void> setSafetyInset(SafetyInsetMode value) async {
    state = state.copyWith(safetyInset: value);
    await _prefs.setString(_kSafetyInset, value.name);
  }

  /// An unreadable or absent value means the deliberate default, not `system`.
  ///
  /// `switch` with a named fallback rather than `values.byName`: a stored id
  /// from a build that had a third option must degrade to the current choice,
  /// not crash on the first frame.
  static AppIconSet _iconSetFrom(String? raw) =>
      raw == AppIconSet.system.name ? AppIconSet.system : AppIconSet.themed;

  /// An unreadable or absent value lands on [SafetyInsetMode.auto] — the same
  /// named fallback the icon set uses, and for the same reason: a value stored
  /// by a build that had a fourth option must degrade, not crash.
  static SafetyInsetMode _safetyInsetFrom(String? raw) => switch (raw) {
        'alwaysOn' => SafetyInsetMode.alwaysOn,
        'alwaysOff' => SafetyInsetMode.alwaysOff,
        _ => SafetyInsetMode.auto,
      };

  static AppThemeMode _themeFrom(String? raw) => switch (raw) {
        'light' => AppThemeMode.light,
        'dark' => AppThemeMode.dark,
        _ => AppThemeMode.system,
      };
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, SettingsState>(SettingsNotifier.new);

/// Resolves the effective brightness from the setting plus the platform.
Brightness resolveBrightness(AppThemeMode mode, Brightness platform) {
  return switch (mode) {
    AppThemeMode.light => Brightness.light,
    AppThemeMode.dark => Brightness.dark,
    AppThemeMode.system => platform,
  };
}
