import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/update/update_controller.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/dock.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/board/board_page.dart';
import 'package:herdr_pocket/ui/pages/settings/settings_page.dart';
import 'package:herdr_pocket/ui/pages/workspaces/workspaces_page.dart';

/// The two screens the dock switches between, over one floating bar.
///
/// WHY A SHELL RATHER THAN TABS IN THE NAV BAR. The board and the tree are
/// peers — neither is "inside" the other — so making one a push from the other
/// would put a lie in the back stack: leaving the tree would return you to the
/// board rather than out of the screen you were on, and the two would end up
/// nested arbitrarily deep depending on how you got there.
///
/// The dock floats OVER both pages rather than sitting in a Column beside them.
/// A bar in a Column steals height from the list and pushes the scroll view up,
/// which is visible as a jump the moment the user switches roots. Floating means
/// each page keeps its own full height and its own scroll position, and the only
/// thing the pages have to know about is how much room to leave at the bottom.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  RootView _current = RootView.board;

  @override
  void initState() {
    super.initState();
    // THE LAUNCH CHECK, and the only place it can live.
    //
    // Below `CupertinoApp` (so there is an `Overlay` to toast into — the app
    // root is above it and would find none), once per process (this state is
    // created once), and after the first frame (so a check that fails instantly
    // does not delay the board by a network round trip).
    //
    // SILENT ON FAILURE, ALWAYS. The user did not ask for this request; it is a
    // setting they turned on. A toast saying "could not check for updates"
    // would be the app reporting a background chore as if it were news. Only a
    // find is worth speaking about, and even then it is one line that expires.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!ref.read(settingsProvider).autoUpdateCheck) return;

      final outcome =
          await ref.read(updateControllerProvider.notifier).check();
      if (!mounted || outcome != UpdateCheckOutcome.available) return;
      final latest = ref.read(updateControllerProvider).latest;
      if (latest == null) return;
      showHerdrToast(context, AppLocalizations.of(context).updateToast(latest.toString()));
    });
  }

  /// Reconciles the background keep-alive service with the connection.
  ///
  /// WHY IT LIVES HERE. The decision is about connection state (see
  /// [keepAliveWanted]) and the mechanism is a Kotlin foreground service, but
  /// the notification's sentence is USER-FACING and therefore localized — and
  /// this widget is the one place that is both below `CupertinoApp` (so
  /// `AppLocalizations` is available) and alive exactly once per process.
  ///
  /// SILENT ON FAILURE, ALWAYS. A phone that will not start a foreground
  /// service — the notification permission denied, an OEM that blocks
  /// background starts — leaves the app working exactly as it did before this
  /// feature: connected in the foreground, recovered on resume. Nothing here
  /// is worth a toast.
  ///
  /// ⚠️ [enabled] AND [sessionOpen] ARE PARAMETERS, NOT READS. Both of them are
  /// watched by `build` before it calls this, and that is what makes the
  /// switch work: a `ref.read` here would be a read with no subscription, so
  /// flipping the setting would change nothing at all until the next reconnect.
  /// Found on the phone — the switch went off and the notification stayed
  /// there, which is the exact failure mode a settings row must never have.
  void _watchKeepAlive(
    AppLocalizations l10n, {
    required bool enabled,
    required bool sessionOpen,
  }) {
    final controller = ref.read(keepAliveControllerProvider);
    final host = ref.read(currentHostProvider);

    void sync(ConnectionStatus? status) {
      unawaited(
        controller.sync(
          enabled: enabled,
          status: status,
          sessionOpen: sessionOpen,
          title: l10n.appTitle,
          text: host == null
              ? l10n.keepAliveNotificationBodyNoHost
              : l10n.keepAliveNotificationBody(host.label),
        ),
      );
    }

    ref.listen<AsyncValue<ConnectionStatus>>(connectionProvider, (_, next) {
      sync(next.value);
    });
    // Once for the value that is already there: a listener only fires on
    // CHANGE, and this widget can be built while a connection is already up
    // (a hot restart, a theme change rebuilding the shell).
    sync(ref.read(connectionProvider).value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final glass = ref.watch(settingsProvider.select((s) => s.glassEnabled));

    // BOTH of these are WATCHED, and both have to be: the setting is what the
    // user flips, and the holders are what a page adds when it opens its own
    // SSH session. Either changing re-runs this build and re-reconciles the
    // service — a read inside `_watchKeepAlive` would leave the switch dead.
    _watchKeepAlive(
      l10n,
      enabled: ref.watch(settingsProvider.select((s) => s.keepAlive)),
      sessionOpen: ref.watch(keepAliveHoldersProvider).isNotEmpty,
    );

    final labels = <RootView, String>{
      RootView.board: l10n.navBoard,
      RootView.workspaces: l10n.navWorkspaces,
      RootView.settings: l10n.navSettings,
    };

    return Stack(
      children: [
        // Keyed by root so the outgoing page is torn down and its provider
        // subscriptions are released: leaving the tree on screen behind the
        // board would keep three socket reads per event burst running for a
        // view nobody is looking at.
        AnimatedSwitcher(
          duration: Motion.press,
          child: switch (_current) {
            RootView.board => const BoardPage(key: ValueKey('board')),
            RootView.workspaces => const WorkspacesPage(
                key: ValueKey('workspaces'),
              ),
            RootView.settings => const SettingsPage(key: ValueKey('settings')),
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: HerdrDock(
            views: RootView.values,
            selected: _current,
            labels: labels,
            glass: glass,
            onSelect: (view) {
              if (view == _current) return;
              // A dock that only moves pixels is a dock you press twice to be
              // sure. The tick is the acknowledgement.
              unawaited(HapticFeedback.selectionClick());
              setState(() => _current = view);
            },
          ),
        ),
      ],
    );
  }
}
