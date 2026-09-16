import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/design/safety_inset.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The safety margin, and why it is not simply `SafeArea`.
///
/// THE PROBLEM. Android's gesture navigation owns a swipe band along the bottom
/// edge; a press-drag-release that starts inside it is consumed by the system
/// and never reaches the app. A control sitting in that band is therefore not
/// merely at risk of a mis-tap — the user's gesture may not arrive at all, and
/// the control looks broken.
///
/// SO THERE ARE TWO HALVES, and they fail differently:
///
///   1. the decision — trust the platform, or overrule it (three states, and
///      the third exists because the platform's report is not trustworthy on
///      every OEM build);
///   2. the arithmetic — the chrome that is positioned off the WINDOW edge has
///      to clear the inset, not just the two screens that happen to use
///      `SafeArea`.
void main() {
  group('the decision', () {
    test('auto follows the platform', () {
      expect(
        shouldKeepSafetyInset(
          SafetyInsetMode.auto,
          systemGestures: true,
        ),
        isTrue,
      );
      expect(
        shouldKeepSafetyInset(
          SafetyInsetMode.auto,
          systemGestures: false,
        ),
        isFalse,
        reason: 'three-button navigation has no swipe band, so there is nothing '
            'to keep clear of and the margin would just be spent pixels',
      );
    });

    test('the overrides overrule the platform in both directions', () {
      // The whole reason the setting exists: when the platform is wrong, the
      // user has to be able to say so — in EITHER direction. A margin that can
      // only be forced on is a margin nobody can turn off on the device where
      // it is unnecessary.
      expect(
        shouldKeepSafetyInset(
          SafetyInsetMode.alwaysOn,
          systemGestures: false,
        ),
        isTrue,
      );
      expect(
        shouldKeepSafetyInset(
          SafetyInsetMode.alwaysOff,
          systemGestures: true,
        ),
        isFalse,
      );
    });

    test('an unreadable stored value falls back to auto', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.settings.safetyInset': 'sometimes',
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(settingsProvider).safetyInset,
        SafetyInsetMode.auto,
        reason: 'a value written by a build with a fourth option must degrade, '
            'not crash the first frame',
      );
    });

    test('the choice survives a restart', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final first = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(first.dispose);

      expect(
        first.read(settingsProvider).safetyInset,
        SafetyInsetMode.auto,
        reason: 'the app should not spend pixels on a guess by default',
      );

      await first
          .read(settingsProvider.notifier)
          .setSafetyInset(SafetyInsetMode.alwaysOn);

      final second = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(second.dispose);
      expect(second.read(settingsProvider).safetyInset, SafetyInsetMode.alwaysOn);
    });
  });

  group('the margin', () {
    const gesturing = MediaQueryData(
      size: Size(400, 800),
      padding: EdgeInsets.only(bottom: 24),
      systemGestureInsets: EdgeInsets.only(bottom: 24),
    );
    const buttons = MediaQueryData(
      size: Size(400, 800),
      padding: EdgeInsets.only(bottom: 48),
      systemGestureInsets: EdgeInsets.zero,
    );

    Future<EdgeInsets> resolve(WidgetTester tester, MediaQueryData media,
        SafetyInsetMode mode) async {
      late EdgeInsets result;
      await tester.pumpWidget(
        MediaQuery(
          data: media,
          child: Builder(
            builder: (context) {
              result = safetyInsetFor(context, mode);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('auto keeps nothing on a three-button device', (tester) async {
      expect(await resolve(tester, buttons, SafetyInsetMode.auto), EdgeInsets.zero);
    });

    testWidgets('auto keeps a margin where the platform owns the edge',
        (tester) async {
      final inset = await resolve(tester, gesturing, SafetyInsetMode.auto);
      expect(inset.bottom, kSafetyInset);
      // Bottom only. The left and right edges also carry system gestures, but
      // spending width on them would shrink the terminal grid — a real cost,
      // for a risk the user did not report.
      expect(inset.left, 0);
      expect(inset.right, 0);
      expect(inset.top, 0);
    });

    testWidgets('always on keeps a margin even where the platform is silent',
        (tester) async {
      expect(
        (await resolve(tester, buttons, SafetyInsetMode.alwaysOn)).bottom,
        kSafetyInset,
      );
    });

    testWidgets('always off drops it even where the platform owns the edge',
        (tester) async {
      expect(
        await resolve(tester, gesturing, SafetyInsetMode.alwaysOff),
        EdgeInsets.zero,
      );
    });
  });

  group('the dock', () {
    Future<void> pumpDock(WidgetTester tester, EdgeInsets padding) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: MediaQuery(
            data: MediaQueryData(size: const Size(400, 800), padding: padding),
            child: const HerdrTheme(
              colors: HerdrColors.dark,
              child: CupertinoApp(
                localizationsDelegates: [
                  AppLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                ],
                supportedLocales: AppLocalizations.supportedLocales,
                locale: Locale('en'),
                home: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: HerdrDock(
                        views: RootView.values,
                        selected: RootView.board,
                        glass: false,
                        onSelect: _ignore,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('clears the system inset, not just its own margin',
        (tester) async {
      await pumpDock(tester, const EdgeInsets.only(bottom: 48));

      final dock = tester.getRect(find.byType(HerdrDock));
      final gap = 800 - dock.bottom;
      expect(
        gap,
        greaterThanOrEqualTo(48 + HerdrDock.bottomMargin),
        reason: 'the dock is positioned off the WINDOW edge, and on an '
            'edge-to-edge device that edge is under the navigation bar',
      );
    });

    testWidgets('a page reserves exactly the room the dock takes',
        (tester) async {
      await pumpDock(tester, const EdgeInsets.only(bottom: 48));
      final context = tester.element(find.byType(HerdrDock));

      // The reserve has to move with the dock or the last row of a list ends up
      // behind it — and it is only ever visible on a device where the window is
      // edge-to-edge, which is exactly the bug that ships.
      expect(HerdrDock.reserveOf(context), HerdrDock.reserve + 48);
    });
  });
}

void _ignore(RootView _) {}
