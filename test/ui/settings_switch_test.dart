import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The settings switch.
///
/// Two things are asserted here and both were measured on a device first,
/// because neither is visible in a source diff: that the switch is drawn
/// smaller than Flutter's default, and that making the ROW tappable did not
/// turn a tap on the switch itself into two toggles.
void main() {
  Future<List<bool>> pump(
    WidgetTester tester, {
    bool initial = false,
    bool withNote = true,
  }) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: SettingsGroup(
              rows: [
                SettingsSwitchRow(
                  label: 'Liquid Glass',
                  note: withNote ? 'Transparency on the navigation bars.' : null,
                  value: initial,
                  onChanged: calls.add,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return calls;
  }

  testWidgets('it is drawn smaller than the platform default', (tester) async {
    await pump(tester);
    // Find the scaling Transform rather than "the nearest Transform ancestor":
    // the first ancestor in tree order is not necessarily the one this widget
    // added, and asserting on the wrong node is how a test ends up checking
    // nothing at all.
    // Read the X scale off the matrix rather than `getMaxScaleOnAxis()` —
    // that helper returns the LARGEST of the three axes, and a 2-D scale leaves
    // Z at 1.0, so it reports 1.0 for a widget that is plainly drawn smaller.
    final scales = tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.byType(CupertinoSwitch),
            matching: find.byType(Transform),
          ),
        )
        .map((t) => t.transform.entry(0, 0))
        .toList();
    expect(scales, contains(closeTo(switchScale, 0.001)));

    // And the point of scaling rather than resizing: the space it occupies is
    // unchanged, so nothing about the page reflows. `Transform` paints smaller
    // without claiming less layout — the switch still measures its natural size.
    final natural = tester.getSize(find.byType(CupertinoSwitch));
    expect(natural.width, greaterThan(natural.width * switchScale));
    expect(natural.width * switchScale, lessThan(natural.width));
  });

  testWidgets('tapping the label toggles', (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Liquid Glass'));
    await tester.pump();
    expect(calls, [true]);
  });

  testWidgets('tapping the switch toggles exactly once', (tester) async {
    // The row and the switch are both tap recognizers now. If both fired, the
    // two toggles would cancel out and the switch would appear dead — the
    // failure this test exists to catch.
    final calls = await pump(tester);
    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pump();
    // The switch was OFF, so one toggle reports `true`. Two would report
    // `[true, false]` and leave the switch looking dead.
    expect(calls, [true]);
  });

  testWidgets('tapping the explanation toggles too, across its two lines',
      (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Transparency on the navigation bars.'));
    await tester.pump();
    expect(calls, [true]);
  });

  testWidgets('a switch with no note still toggles from anywhere in the row',
      (tester) async {
    final calls = await pump(tester, withNote: false);
    await tester.tap(find.text('Liquid Glass'));
    await tester.pump();
    expect(calls, [true]);
  });
}
