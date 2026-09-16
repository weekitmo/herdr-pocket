import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/components/menu_popover.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The anchored menu, and the type size it exists to fix.
enum _Action { files, git }

void main() {
  late _Result result;

  setUp(() => result = _Result());

  Future<void> pumpMenu(
    WidgetTester tester, {
    bool themedIcons = true,
    Rect? anchorRect,
    List<HerdrMenuItem<_Action>>? items,
  }) async {
    await tester.pumpWidget(
      HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: Builder(
              builder: (context) => Align(
                alignment: Alignment.topRight,
                child: CupertinoButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result.value = await showHerdrMenu<_Action>(
                      context,
                      themedIcons: themedIcons,
                      anchorRect: anchorRect ??
                          const Rect.fromLTWH(300, 40, 40, 40),
                      items: items ??
                          const [
                            HerdrMenuItem(
                              value: _Action.files,
                              label: '文件',
                              icon: UiIconName.folder,
                              cupertinoIcon: CupertinoIcons.folder,
                            ),
                            HerdrMenuItem(
                              value: _Action.git,
                              label: 'Git 改动',
                              icon: UiIconName.branch,
                              cupertinoIcon: CupertinoIcons.arrow_branch,
                            ),
                          ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('rows are an icon AND a label', (tester) async {
    await pumpMenu(tester);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('Git 改动'), findsOneWidget);
    // One glyph per row, drawn from the set the caller asked for.
    expect(find.byType(UiIcon), findsNWidgets(2));
  });

  testWidgets('the rows use the app type ladder, not Cupertino action sizes',
      (tester) async {
    // The bug this menu was built to fix: every action sheet drew a bare `Text`
    // at Cupertino's ~20-point action style against a 13-point body.
    await pumpMenu(tester);
    for (final label in ['文件', 'Git 改动']) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.fontSize, TextSize.body);
    }
  });

  testWidgets('the system icon set falls back to the platform glyphs',
      (tester) async {
    await pumpMenu(tester, themedIcons: false);
    expect(find.byType(UiIcon), findsNothing);
    expect(find.byIcon(CupertinoIcons.folder), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.arrow_branch), findsOneWidget);
  });

  testWidgets('it hangs below the anchor and inside the right margin',
      (tester) async {
    await pumpMenu(tester);
    final card = tester.getRect(find.text('文件'));
    // Below the anchor's bottom (40 + 40) plus the gap.
    expect(card.top, greaterThan(80));
    // And it is a menu beside the button, not a sheet at the bottom: the whole
    // thing sits in the top third of a 600-point test window.
    expect(tester.getRect(find.text('Git 改动')).bottom, lessThan(300));
  });

  testWidgets('choosing a row returns its value', (tester) async {
    await pumpMenu(tester);
    await tester.tap(find.text('Git 改动'));
    await tester.pumpAndSettle();
    expect(result.value, _Action.git);
  });

  testWidgets('tapping the barrier dismisses with no value', (tester) async {
    await pumpMenu(tester);
    // The barrier sits behind the card; a tap near the bottom of the screen
    // lands on it rather than on a row.
    await tester.tapAt(const Offset(20, 560));
    await tester.pumpAndSettle();
    expect(result.value, isNull);
    expect(find.text('文件'), findsNothing);
  });

  testWidgets('a destructive row is drawn in the failure hue', (tester) async {
    // Delete lives in the hosts menu, and a menu that painted it like every
    // other row would be hiding the one row you should read twice.
    await tester.pumpWidget(
      HerdrTheme(
        colors: HerdrColors.dark,
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: Builder(
              builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showHerdrMenu<_Action>(
                  context,
                  anchorRect: const Rect.fromLTWH(300, 40, 40, 40),
                  items: const [
                    HerdrMenuItem(
                      value: _Action.files,
                      label: 'Delete',
                      icon: UiIconName.folder,
                      destructive: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text('Delete'));
    expect(text.style?.color, HerdrColors.dark.died);
  });

  group('a picker near the bottom of the screen', () {
    // THE BUG THIS PINS. The menu always dropped DOWNWARD from its anchor, which
    // is right for an overflow button in a navbar and wrong for a settings row
    // near the foot of the page: the last option was laid out past the edge of
    // the window and could not be tapped at all. Found on a device, in the
    // three-option dropdown that made it obvious.
    const items = [
      HerdrMenuItem(value: _Action.files, label: 'Default', selected: true),
      HerdrMenuItem(value: _Action.git, label: 'Always on'),
    ];

    testWidgets('flips above its anchor rather than running off the bottom',
        (tester) async {
      // The default test surface is 800x600, so an anchor at y=560 has no room
      // below it.
      await pumpMenu(
        tester,
        anchorRect: const Rect.fromLTWH(500, 560, 0, 24),
        items: items,
      );

      for (final label in ['Default', 'Always on']) {
        final rect = tester.getRect(find.text(label));
        expect(
          rect.bottom,
          lessThanOrEqualTo(600),
          reason: '$label is off the bottom of the screen',
        );
        expect(rect.top, greaterThanOrEqualTo(0));
      }
      // Above the anchor, because below it does not fit.
      expect(
        tester.getRect(find.text('Always on')).bottom,
        lessThanOrEqualTo(560),
      );
    });

    testWidgets('still drops downward when there is room', (tester) async {
      await pumpMenu(
        tester,
        anchorRect: const Rect.fromLTWH(500, 40, 0, 24),
        items: items,
      );

      expect(
        tester.getRect(find.text('Default')).top,
        greaterThanOrEqualTo(64),
        reason: 'flipping a menu that fits is a menu that moves for no reason',
      );
    });

    testWidgets('a tick marks the current choice, and only that one',
        (tester) async {
      await pumpMenu(
        tester,
        anchorRect: const Rect.fromLTWH(500, 40, 0, 24),
        items: items,
      );

      expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
      // No glyph column full of blank boxes: a picker's rows are words.
      expect(find.byType(UiIcon), findsNothing);
    });

    testWidgets('picking one pops it back to the caller', (tester) async {
      await pumpMenu(
        tester,
        anchorRect: const Rect.fromLTWH(500, 40, 0, 24),
        items: items,
      );

      await tester.tap(find.text('Always on'));
      await tester.pumpAndSettle();

      expect(result.value, _Action.git);
    });
  });

  testWidgets('action sheet rows carry the same size', (tester) async {
    // The other half of the fix, asserted here so the two cannot drift: the
    // sheets that stayed sheets got their type size corrected too.
    final label = actionSheetLabel('Edit');
    expect(label.style?.fontSize, TextSize.body);
    expect(
      label.style?.color,
      isNull,
      reason: 'a colour here would override isDestructiveAction',
    );
  });
}

class _Result {
  _Action? value;
}
