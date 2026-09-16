import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/root_shell.dart';
import 'package:herdr_pocket/data/providers/app_info.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:herdr_pocket/ui/pages/settings/settings_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The contract between the app and the scripts that drive it.
///
/// `tool/device_check.sh` reaches into the running app through
/// `uiautomator dump`, which can only address what the semantics tree exposes.
/// [UiId] exists to make that address stable — and an identifier that is not
/// actually attached to a node, or that two nodes share, is worse than none at
/// all: the check still runs, still finds *something*, and verifies the wrong
/// thing.
///
/// So this file asserts what the script depends on:
///
///   1. every id is ON SCREEN where the script expects it;
///   2. it is UNIQUE — `find.bySemanticsIdentifier` returning two nodes is the
///      ambiguity that label addressing had;
///   3. it survives being a control: the node is a button, and carries the
///      readable label too, because an identifier nobody can read is not an
///      accessibility improvement.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectionProvider.overrideWith(_OfflineConnection.new),
          packageInfoProvider.overrideWith((ref) async => _packageInfo),
        ],
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
            home: SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  /// Scrolls the row into view — the ids below the fold are off-stage, and the
  /// default finders skip those.
  Future<void> reveal(WidgetTester tester, String text) async {
    await tester.dragUntilVisible(
      find.text(text),
      find.byType(CustomScrollView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the safety row is addressable by id', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, 'Safety margin');

    final finder = find.bySemanticsIdentifier(UiId.safetyMargin);
    expect(
      finder,
      findsOneWidget,
      reason: 'the device check taps this by id; two matches is the ambiguity '
          'that label addressing had, and none means the id is not attached',
    );

    final node = tester.getSemantics(finder);
    expect(node.identifier, UiId.safetyMargin);
    expect(
      node.label,
      contains('Safety margin'),
      reason: 'an id on an unlabelled node is untargetable by a screen reader',
    );
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'the check taps it, so it has to be tappable',
    );
  });

  testWidgets('every option in the picker is addressable, and distinct',
      (tester) async {
    await pumpSettings(tester);
    await reveal(tester, 'Safety margin');

    await tester.tap(find.bySemanticsIdentifier(UiId.safetyMargin));
    await tester.pumpAndSettle();

    for (final id in [
      UiId.safetyDefault,
      UiId.safetyAlwaysOn,
      UiId.safetyAlwaysOff,
    ]) {
      expect(
        find.bySemanticsIdentifier(id),
        findsOneWidget,
        reason: '$id is not on screen, or is not unique',
      );
    }
  });

  testWidgets('the row and the option it duplicates are told apart',
      (tester) async {
    // THE CASE THAT BROKE THE SCRIPT. Set the value to 强制开启 and the row says
    // it too; a label-addressed check then has two candidates for its second
    // tap and picks whichever the tree lists first. The ids are the whole
    // reason that stops being a coin flip.
    await pumpSettings(tester);
    await reveal(tester, 'Safety margin');

    await tester.tap(find.bySemanticsIdentifier(UiId.safetyMargin));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsIdentifier(UiId.safetyAlwaysOn));
    await tester.pumpAndSettle();

    // Both now read "Always on".
    expect(find.text('Always on'), findsWidgets);
    expect(find.bySemanticsIdentifier(UiId.safetyMargin), findsOneWidget);
  });

  group('the dock', _dockTests);
}

/// The dock is on every screen, so its ids are the ones every check passes
/// through — and the ones where a `Semantics` wrapper is most tempting to write
/// wrong.
void _dockTests() {
  testWidgets('every dock destination is one usable node', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectionProvider.overrideWith(_OfflineConnection.new),
          packageInfoProvider.overrideWith((ref) async => _packageInfo),
        ],
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
            // The SHELL, not a page: the dock belongs to the shell, and a test
            // that pumps the board and looks for the dock finds nothing.
            home: RootShell(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final id in [UiId.dockBoard, UiId.dockWorkspaces, UiId.dockSettings]) {
      final finder = find.bySemanticsIdentifier(id);
      expect(finder, findsOneWidget, reason: '$id is missing or duplicated');

      final node = tester.getSemantics(finder);
      final data = node.getSemanticsData();

      // A `Semantics` node that carries the id but not the action is a button
      // nobody can press. It happens whenever the wrapper goes around a widget
      // that is already a semantics boundary — a CupertinoButton keeps its own
      // node and its own tap, and the wrapper's node is left inert with the
      // right coordinates and no way to activate it.
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: '$id has no tap action: the wrapper is not the button',
      );
      expect(data.flagsCollection.isButton, isTrue);

      // And the label must not be doubled. Without `excludeSemantics` the
      // visible Text merges in on top of the label the wrapper set, and the
      // node reads "Board\nBoard".
      expect(
        node.label,
        isNot(contains('\n')),
        reason: '$id repeats its own label: $node.label',
      );
      expect(node.label, isNotEmpty);
    }
  });
}

class _OfflineConnection extends ConnectionNotifier {
  @override
  Future<ConnectionStatus> build() async => const Disconnected();
}

final _packageInfo = PackageInfo(
  appName: 'Herdr Pocket',
  packageName: 'dev.herdr.herdr_pocket',
  version: '1.0.0',
  buildNumber: '1',
);
