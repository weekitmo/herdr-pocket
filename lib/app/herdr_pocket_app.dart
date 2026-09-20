
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/root_shell.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/app_lock.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/host_key_sheet.dart';
import 'package:herdr_pocket/ui/design/safety_inset.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/lock/lock_gate.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_page.dart';

/// The application root.
///
/// This is a [CupertinoApp], NOT a MaterialApp. That is deliberate and it is a
/// hard product constraint: mixing the two drags Material's defaults into every
/// ancestor and the app stops looking like one system. `CupertinoApp` provides
/// everything a MaterialApp would here — Overlay, Navigator, MediaQuery,
/// Directionality, Localizations and DefaultTextStyle — so nothing is lost
/// except Material widgets we do not want. See `test/architecture/
/// no_material_test.dart`, which fails the build if this regresses.
class HerdrPocketApp extends StatelessWidget {
  const HerdrPocketApp({super.key});

  @override
  Widget build(BuildContext context) => const _Root();
}

class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> {
  /// Held here so a notification tap can navigate without a platform callback
  /// reaching into the widget tree.
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    // A notification tap means "show me that agent". Handled here rather than
    // in the callback so it works on a cold start, where the callback can fire
    // before there is anything to navigate with.
    ref.listen(pendingPaneProvider, (_, paneId) {
      if (paneId == null) return;
      final open = ref.read(pendingPaneProvider.notifier).take();
      if (open == null) return;
      _navigator.currentState?.push(
        CupertinoPageRoute<void>(
          builder: (_) => TerminalPage(paneId: open, title: open),
        ),
      );
    });

    return _BrightnessOverride(
      mode: settings.themeMode,
      builder: (context, platformBrightness) {
        final theme = ref.watch(selectedThemeProvider);
        final brightness = theme == null
            ? platformBrightness
            : themeBrightness(theme);
        final colors = resolveColors(
          theme: theme,
          platformBrightness: platformBrightness,
        );
        // A LOCKED APP DOES NOT ASK ABOUT HOST KEYS. The sheet below sits above
        // the navigator — deliberately, so a blocked handshake can be answered
        // from any screen — and that puts it above the lock screen too, which
        // would let somebody approve a machine's key on a phone they cannot
        // open. The question keeps until the app is unlocked.
        final locked = ref.watch(appLockProvider).value?.locked ?? false;

        return HerdrTheme(
          colors: colors,
          child: CupertinoApp(
            navigatorKey: _navigator,
            title: 'herdr pocket',
            debugShowCheckedModeBanner: false,
            // Locale: zh-Hans is the PRIMARY audience, so it is the fallback
            // rather than en. Without this an unsupported system locale would
            // land on English and a Chinese user would see the wrong language
            // on first launch.
            locale: settings.languageCode == null
                ? null
                : Locale(settings.languageCode!),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
            ],
            localeListResolutionCallback: (locales, supported) {
              if (locales == null || locales.isEmpty) {
                return const Locale('zh', 'Hans');
              }
              for (final locale in locales) {
                for (final candidate in supported) {
                  if (candidate.languageCode == locale.languageCode) {
                    return candidate;
                  }
                }
              }
              return const Locale('zh', 'Hans');
            },
            theme: _cupertinoTheme(colors),
            builder: (context, child) {
              // Text scaling is clamped rather than unbounded: the board layout
              // relies on fixed row heights, and an unbounded scale clips it.
              // herdrup sidesteps this by using fixed sizes and ignoring
              // Dynamic Type entirely; clamping keeps the affordance without
              // the breakage.
              // The user's own size setting MULTIPLIES the platform's, rather
              // than replacing it: someone who has already made everything
              // larger in system settings should not have that thrown away by
              // opening this app.
              final scaler = _MultipliedTextScaler(
                MediaQuery.textScalerOf(context)
                    .clamp(minScaleFactor: 0.85, maxScaleFactor: 1.6),
                settings.textScale,
              );
              // The safety margin is folded into `padding`/`viewPadding` HERE,
              // once, rather than taught to every `SafeArea` in the app. Every
              // screen that already respects the system's inset then respects
              // this too — the terminal's key bar, the settings lists, the
              // board's scroll tail — and a new screen cannot forget it.
              //
              // BOTH, and equally: `padding` is `viewPadding` minus the
              // keyboard, so adding to one and not the other would make the
              // two disagree the moment the keyboard opens.
              final safety = safetyInsetFor(context, settings.safetyInset);
              final media = MediaQuery.of(context);
              // IMMERSIVE: the system bars are drawn OVER the page, with no
              // colour of their own and icons that contrast with what is under
              // them. Without this, Android lays a translucent scrim behind the
              // status bar and the top of every screen is a few per cent darker
              // than the page below it — a band that reads as "a title bar" on
              // a design whose whole point is that there is no bar.
              //
              // `AnnotatedRegion` rather than an imperative
              // `SystemChrome.setSystemUIOverlayStyle`: the value then follows
              // the theme like every other colour in the app, including a
              // brightness change from the system.
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: _overlayStyle(colors),
                child: MediaQuery(
                data: media.copyWith(
                  textScaler: scaler,
                  platformBrightness: brightness,
                  padding: media.padding + safety,
                  viewPadding: media.viewPadding + safety,
                ),
                // The host-key sheet sits above EVERYTHING, including pushed
                // routes: the SSH handshake is blocked on its answer, so a
                // sheet the user cannot reach would mean a connection that
                // simply hangs with no explanation.
                // The default text style carries the family, so every `Text`
                // in the app inherits it without each one naming a font. The
                // widgets that DO name one (the terminal) name the same family
                // anyway; this exists so a new label cannot accidentally
                // introduce a second typeface.
                child: DefaultTextStyle.merge(
                  // The FALLBACK is the load-bearing half. Iosevka has no Han
                  // at all, so a Chinese glyph is served by Noto — and Noto
                  // must come BEFORE the platform, whose CJK faces are
                  // proportional and would put every Chinese character off the
                  // grid. A `Text` that names the family but not the fallback
                  // still inherits this one through `TextStyle.merge`.
                  style: const TextStyle(
                    fontFamily: HerdrFonts.app,
                    fontFamilyFallback: HerdrFonts.monoFallback,
                  ),
                  // THREE LAYERS, and the order is the security model:
                  //
                  //   1. the navigator — every screen the app can push;
                  //   2. the host-key sheet — a blocked handshake has to be
                  //      answerable from whatever screen the user is on;
                  //   3. the app lock, ON TOP OF BOTH.
                  //
                  // THE LOCK IS AN OVERLAY RATHER THAN A ROUTE, and that is not
                  // a layout preference. A notification tap or a deep link
                  // pushes a route onto the navigator, and a lock that lives
                  // INSIDE the navigator — as its `home`, which is where this
                  // started — would be covered by whatever the app pushed over
                  // it. Here nothing the app can navigate to is above it, and
                  // the terminal a notification asked for is simply waiting
                  // underneath once the PIN is in.
                  child: Stack(
                    children: [
                      ?child,
                      // Hidden while locked: approving a machine's key on a
                      // phone nobody has opened is exactly the hole the lock is
                      // for. The question waits.
                      if (!locked) const HostKeySheet(),
                      const LockGate(),
                    ],
                  ),
                ),
                ),
              );
            },
            // NOT the lock: it lives in the builder above, over the top of the
            // navigator. See the comment there for why a lock INSIDE the
            // navigator is not a lock.
            home: const RootShell(),
          ),
        );
      },
    );
  }

  /// What the system's own bars may paint, and how their icons read.
  ///
  /// NO COLOUR AT ALL, both bars: the page is the background, and a system bar
  /// that paints one is a frame around the app. The icon brightness is the only
  /// decision left, and it follows the app's ground — light glyphs on a dark
  /// page, dark glyphs on a light one.
  ///
  /// `systemNavigationBarContrastEnforced: false` is the Android 10+ one: by
  /// default the system adds its own translucent background to the navigation
  /// bar when it thinks the app's content is too busy behind it, which is
  /// exactly the band this is here to remove.
  SystemUiOverlayStyle _overlayStyle(HerdrColors colors) {
    final icons = colors.isDark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      statusBarIconBrightness: icons,
      // iOS spells the same question backwards: this is the brightness OF THE
      // BACKGROUND, not of the icons.
      statusBarBrightness: colors.isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: const Color(0x00000000),
      systemNavigationBarDividerColor: const Color(0x00000000),
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// Maps our tokens onto Cupertino's theme. Cupertino owns few enough colours
  /// that this is a complete mapping — everything else reads `HerdrTheme.of`.
  CupertinoThemeData _cupertinoTheme(HerdrColors c) {
    return CupertinoThemeData(
      brightness: c.brightness,
      primaryColor: c.accent,
      scaffoldBackgroundColor: c.ground,
      barBackgroundColor: c.surface,
      primaryContrastingColor: c.surface,
      // Every family here is named explicitly. Cupertino's own text styles do
      // not read `DefaultTextStyle`, so a navigation title left to itself would
      // keep the platform face while the body text switched — the one bug that
      // would make this change look half-applied.
      textTheme: CupertinoTextThemeData(
        primaryColor: c.text,
        textStyle: TextStyle(
          color: c.text,
          fontSize: TextSize.body,
          fontFamily: HerdrFonts.app,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
        navTitleTextStyle: TextStyle(
          color: c.text,
          fontSize: TextSize.title,
          fontWeight: FontWeight.w600,
          fontFamily: HerdrFonts.app,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
        navLargeTitleTextStyle: TextStyle(
          color: c.text,
          fontSize: TextSize.largeTitle,
          fontWeight: FontWeight.w700,
          fontFamily: HerdrFonts.app,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
        navActionTextStyle: TextStyle(
          color: c.accent,
          fontSize: TextSize.title,
          fontFamily: HerdrFonts.app,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
        tabLabelTextStyle: TextStyle(
          color: c.textDim,
          fontSize: TextSize.micro,
          fontFamily: HerdrFonts.app,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
      ),
    );
  }
}

/// Forces `platformBrightness` to the user's choice so Cupertino widgets and
/// our own tokens agree.
///
/// Without this, `CupertinoApp` follows the OS while `HerdrTheme` follows the
/// setting, and a user who picks "Light" on a dark phone gets Cupertino's dark
/// scroll physics and bar colours inside our light colours.
class _BrightnessOverride extends StatelessWidget {
  const _BrightnessOverride({required this.mode, required this.builder});

  final AppThemeMode mode;
  final Widget Function(BuildContext, Brightness) builder;

  @override
  Widget build(BuildContext context) {
    final platform = MediaQuery.platformBrightnessOf(context);
    final resolved = resolveBrightness(mode, platform);
    return builder(context, resolved);
  }
}

/// Multiplies the platform's text scale by the user's in-app preference.
///
/// Flutter has no way to compose two [TextScaler]s, and "replace" would be the
/// wrong composition anyway: someone who has already enlarged everything in
/// system settings should not lose that by opening an app with its own slider.
/// Multiplying keeps both.
class _MultipliedTextScaler extends TextScaler {
  const _MultipliedTextScaler(this._base, this._factor);

  final TextScaler _base;
  final double _factor;

  @override
  double scale(double fontSize) => _base.scale(fontSize) * _factor;

  /// Deprecated on the superclass yet still abstract, so the class cannot be
  /// concrete without it. Text layout on this path goes through [scale].
  @override
  double get textScaleFactor =>
      // The superclass member is itself deprecated, so implementing it means
      // reading it. There is no non-deprecated way to satisfy this interface.
      // ignore: deprecated_member_use
      _base.textScaleFactor * _factor;

  @override
  bool operator ==(Object other) =>
      other is _MultipliedTextScaler &&
      other._base == _base &&
      other._factor == _factor;

  @override
  int get hashCode => Object.hash(_base, _factor);
}
