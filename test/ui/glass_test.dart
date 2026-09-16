import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/design/glass.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Smoke tests for the glass material.
///
/// Glass is the one piece of the design system whose failure mode is a RUNTIME
/// crash rather than an ugly screen: `BackdropFilter` needs a compositing layer
/// and `ImageFilter.compose` needs a valid matrix, and both throw rather than
/// degrade. It is also behind a setting, which means a broken path could sit
/// unnoticed until a user turns it on — so it is worth a test even though there
/// is nothing visual to assert here.
void main() {
  Widget host(Widget child) => CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(child: child),
        ),
      );

  group('HerdrGlass', () {
    testWidgets('builds and paints with a backdrop filter', (tester) async {
      await tester.pumpWidget(
        host(
          const HerdrGlass(
            colors: HerdrColors.dark,
            child: SizedBox(width: 200, height: 60),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(HerdrGlass), findsOneWidget);
      // The filter is what makes it glass rather than a translucent panel.
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('disabled means NO backdrop filter at all', (tester) async {
      await tester.pumpWidget(
        host(
          const HerdrGlass(
            colors: HerdrColors.dark,
            enabled: false,
            child: SizedBox(width: 200, height: 60),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // This is the Android baseline. If the filter were still constructed the
      // device would pay for a blur it was never asked to draw.
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('works in light and dark', (tester) async {
      for (final colors in [HerdrColors.dark, HerdrColors.light]) {
        await tester.pumpWidget(
          host(
            HerdrGlass(
              colors: colors,
              child: const SizedBox(width: 100, height: 40),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'failed for $colors');
      }
    });

    testWidgets('extreme saturation values stay inside the blur pipeline',
        (tester) async {
      // The saturation matrix is built by hand; a NaN or an out-of-range
      // coefficient would not fail at construction, only when painted.
      for (final s in [0.0, 1.0, 2.5, 5.0]) {
        await tester.pumpWidget(
          host(
            HerdrGlass(
              colors: HerdrColors.dark,
              saturation: s,
              child: const SizedBox(width: 50, height: 20),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'failed at s=$s');
      }
    });
  });

  group('GlassEdge', () {
    testWidgets('is a solid hairline, not a gradient', (tester) async {
      await tester.pumpWidget(
        host(const GlassEdge(colors: HerdrColors.dark)),
      );
      expect(tester.takeException(), isNull);
      // "No gradients" is a project rule that came from the user. This asserts
      // the edge honours it, because a specular highlight is the most tempting
      // place to make an exception.
      final box = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(GlassEdge),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(box.color, HerdrColors.dark.hairline);
    });
  });
}
