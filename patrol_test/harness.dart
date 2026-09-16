// Shared scaffolding for the on-device tests.
//
// NOT A TEST FILE, and the name says so: `patrol_cli` collects only
// `*_test.dart` from `patrol_test/`, so this file is compiled into the app but
// never run on its own. (Rename it and it would be discovered as a suite with no
// tests in it, which Patrol reports as a run that tested nothing.)
//
// ## Why boot the app from the test rather than let `main()` run
//
// Under Patrol the app's entrypoint for a test run is the *test file*, not
// `lib/main.dart` — that is how the Dart test process and the JUnit runner end
// up in the same APK. So the things `main()` does have to be done here instead,
// and doing them here is not a workaround: it is what makes the override visible
// in the test.
//
// What is deliberately NOT reproduced is `SystemChrome
// .setEnabledSystemUIMode(edgeToEdge)` — it changes how the system bars paint,
// which is a thing to look at rather than a thing to assert, and issuing it from
// test code would leave the device in a mode the test cannot undo.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/herdr_pocket_app.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pumps the real application widget tree, with real plugins and real storage.
///
/// [SharedPreferences] comes back empty unless something has already written to
/// it, and the native side clears the app's data between tests (see
/// `testInstrumentationRunnerArguments["clearPackageData"]` in
/// `android/app/build.gradle.kts`), so every test starts on a fresh install:
/// no machines, no credentials, `autoConnect` off.
Future<void> launchApp(PatrolIntegrationTester $) async {
  final prefs = await SharedPreferences.getInstance();
  await $.pumpWidgetAndSettle(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const HerdrPocketApp(),
    ),
  );
}

/// The dock's item for [view].
///
/// Addressed by [UiId] rather than by its visible label: the label is
/// translated, so a test built on it only works in one language.
PatrolFinder dockItem(PatrolIntegrationTester $, RootView view) {
  final id = switch (view) {
    RootView.board => UiId.dockBoard,
    RootView.workspaces => UiId.dockWorkspaces,
    RootView.settings => UiId.dockSettings,
  };
  return $(find.bySemanticsIdentifier(id));
}
