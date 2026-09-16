import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:patrol/patrol.dart';

import 'harness.dart';

/// Smoke tests, on a real device.
///
/// ```sh
/// patrol test -d <device>          # every file under patrol_test/
/// ```
///
/// ## What these are for, and what they deliberately are not
///
/// They answer ONE question: **does it come up, and can you get where you are
/// going without it falling over?** A plugin that throws during engine setup, a
/// missing asset, a font that does not load, a page that blows up on its first
/// frame — on a phone that is a crash, and it is the class of failure no unit
/// test can see. That is what a smoke test is for.
///
/// They assert STRUCTURE — launched, dock present, page opened — and never a
/// word, a colour, a size or a pixel. Labels get reworded, palettes get
/// retuned, spacing gets adjusted; all of that is a judgement call made by
/// looking at it. A suite that hard-codes those turns every design tweak into a
/// test edit, which is how a suite ends up being deleted instead of trusted.
///
/// NOT IN CI, on purpose: booting an emulator and building the test APK costs
/// about ten minutes, which is more than most changes are worth. Run it by hand
/// before touching the app shell, the plugin set, or the fonts.
void main() {
  patrolTest('cold start: it comes up, and nothing throws', ($) async {
    await launchApp($);

    // The whole assertion. `takeException` returns anything the framework
    // caught while building and laying out the first frames — a failed asset
    // load, a plugin that was never registered, an overflow.
    expect($.tester.takeException(), isNull);
    expect($(HerdrDock), findsOneWidget);
  });

  patrolTest('every root opens, and none of them throws', ($) async {
    await launchApp($);

    for (final view in RootView.values) {
      await dockItem($, view).tap();
      await $.pumpAndSettle();

      expect(
        $.tester.takeException(),
        isNull,
        reason: 'the ${view.name} page threw while opening',
      );
      // The shell is still standing: a page that crashed would take the dock
      // with it.
      expect($(HerdrDock), findsOneWidget);
    }
  });

  patrolTest('the first-run path opens: board → machines → add a machine',
      ($) async {
    await launchApp($);

    // Without a machine the app does nothing at all, so this is the one flow a
    // new user has to be able to complete. Only the OPENING is asserted here —
    // filling the form in and saving it needs a real host and a real
    // credential, which is a different kind of test.
    await $(find.bySemanticsIdentifier(UiId.openMachines)).tap();
    await $.pumpAndSettle();
    expect($.tester.takeException(), isNull);

    await $(find.bySemanticsIdentifier(UiId.addMachine)).tap();
    await $.pumpAndSettle();

    expect($.tester.takeException(), isNull);
    expect(
      find.byType(CupertinoTextField),
      findsWidgets,
      reason: 'the add-machine sheet opened with no fields in it',
    );
  });
}
