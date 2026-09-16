import 'dart:async';
import 'dart:math' as math;

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/refresh/refresh_style.dart';
import 'package:herdr_pocket/ui/components/refresh/herdr_refresh.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Pulling down, and what shows up.
///
/// The deck's arithmetic is tested in test/domain/refresh_style_test.dart. What
/// is left — and what only a widget test can answer — is that a real drag
/// reaches the deck at all, EXACTLY ONCE per pull, and that the animation is on
/// screen while the finger is down.
///
/// Everything here drives the gesture by hand (`startGesture` + `moveBy`) rather
/// than with `tester.drag`, because the interesting moment is the middle of the
/// pull, not the end of it.
void main() {
  late RefreshStyleDeck deck;

  setUp(() => deck = RefreshStyleDeck(random: math.Random(3)));

  Future<void> pumpRefreshable(
    WidgetTester tester, {
    Future<void> Function()? onRefresh,
  }) async {
    await tester.pumpWidget(
      HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          home: EasyRefresh(
            header: HerdrRefreshHeader(deck: deck),
            onRefresh: onRefresh ?? () async {},
            // A CustomScrollView WITH a HeaderLocator, because that is the
            // arrangement the pages use: the locator is a PLACE, and a header
            // positioned at `IndicatorPosition.locator` without one is a header
            // that never builds — which is exactly how this test first failed.
            child: CustomScrollView(
              slivers: [
                const HeaderLocator.sliver(),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => SizedBox(
                      height: 40,
                      child: Text('row $i'),
                    ),
                    childCount: 30,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  int paints() => find.byType(CustomPaint).evaluate().length;

  /// Drags the list down and holds, so the indicator is on screen.
  Future<TestGesture> pullAndHold(WidgetTester tester, {double by = 160}) async {
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(CustomScrollView)));
    await gesture.moveBy(Offset(0, by));
    await tester.pump();
    return gesture;
  }

  /// Lets the gesture go and lets the spring finish.
  ///
  /// Not `pumpAndSettle`: the styles keep an animation running for as long as
  /// the refresh is on screen, so a settled tree is not something this widget
  /// has. Bounded pumps answer the same question.
  Future<void> release(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    // LONG ENOUGH FOR THE WHOLE LIFECYCLE, not just the spring. EasyRefresh
    // runs the task, shows the result for `processedDuration`, then animates the
    // panel away — and that last step is a `Timer`, so stopping short of it
    // fails the test with "a Timer is still pending after the widget tree was
    // disposed", which reads like a leak in the app and is a short pump here.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  testWidgets('the deck is untouched until the page is actually pulled',
      (tester) async {
    await pumpRefreshable(tester);

    expect(
      deck.last,
      isNull,
      reason: 'a style is chosen by a pull, not by opening the screen',
    );
  });

  testWidgets('a pull takes ONE style off the deck', (tester) async {
    await pumpRefreshable(tester);

    final gesture = await pullAndHold(tester);
    final first = deck.last;
    expect(first, isNotNull);

    // The framework redraws per pixel of the gesture, so a style chosen per
    // rebuild is a style that changes under the finger.
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(deck.last, first, reason: 'a pull picks once, not once per frame');

    await release(tester, gesture);
  });

  testWidgets('the next pull plays a different one', (tester) async {
    await pumpRefreshable(tester);

    final first = await pullAndHold(tester);
    final firstStyle = deck.last;
    await release(tester, first);

    final second = await pullAndHold(tester);
    final secondStyle = deck.last;
    await release(tester, second);

    expect(secondStyle, isNotNull);
    expect(secondStyle, isNot(firstStyle));
  });

  testWidgets('the animation is on screen while the finger is down',
      (tester) async {
    await pumpRefreshable(tester);
    final atRest = paints();

    final gesture = await pullAndHold(tester);

    // Which of the three is the deck's business; that SOMETHING paints is this
    // widget's. Counting painters rather than naming them keeps the test from
    // having to know which style the deck dealt.
    expect(paints(), greaterThan(atRest));

    await release(tester, gesture);
  });

  testWidgets('a refresh that is still running keeps the animation up',
      (tester) async {
    final gate = Completer<void>();
    await pumpRefreshable(tester, onRefresh: () => gate.future);
    final atRest = paints();

    final gesture = await pullAndHold(tester, by: 260);
    await release(tester, gesture);

    expect(
      paints(),
      greaterThan(atRest),
      reason: 'a refresh that finished in the frame it started is a refresh '
          'nobody saw happen',
    );

    gate.complete();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  });
}
