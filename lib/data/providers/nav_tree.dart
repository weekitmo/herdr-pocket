import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';

/// The workspace → tab → pane tree, and the focus actions that move around it.
///
/// RIDES THE BOARD'S EVENT SUBSCRIPTION rather than opening its own. The board
/// already subscribes to every event kind that can change the shape of this
/// tree (`pane.created`, `tab.closed`, `workspace.moved`, …) and already
/// debounces them into one signal per burst, so this provider listens to the
/// board and re-reads. A second `events.subscribe` would cost another SSH
/// channel on a link the terminal is also using, and would have to reimplement
/// the same debounce — for no gain, because the two views are never stale
/// relative to each other if they share one heartbeat.
///
/// The read is three requests (`workspace.list`, `tab.list`, `pane.list`) and
/// only happens while something is actually showing the tree.
class NavTreeNotifier extends AsyncNotifier<WorkspaceTree> {
  @override
  Future<WorkspaceTree> build() async {
    // `listen` rather than `watch`: a rebuild would drop the value back to a
    // loading state, and the tree flashing empty every time an agent prints is
    // exactly the kind of thing that makes an app feel unreliable. The previous
    // tree stays on screen and is replaced when the new one lands.
    ref.listen(boardProvider, (_, _) => unawaited(refresh()));

    final connection = await ref.watch(connectionProvider.future);
    if (connection is! Online) return WorkspaceTree.empty();
    return await connection.client.workspaceTree();
  }

  /// Re-reads without clearing what is already on screen.
  ///
  /// Keeps the last good tree on failure for the same reason the board does: a
  /// machine that briefly cannot answer should not make every workspace vanish.
  Future<void> refresh() async {
    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) return;
    try {
      state = AsyncValue.data(await connection.client.workspaceTree());
    } on Object catch (e, st) {
      if (!state.hasValue) state = AsyncValue.error(e, st);
    }
  }

  /// Moves the daemon's focus, then re-reads so the UI cannot show a stale one.
  ///
  /// Re-reading rather than optimistically flipping the flag: focus is shared
  /// state, the user may have moved it on the desktop at the same moment, and
  /// the flag computed on this device would then be a confident lie. The
  /// `pane.focused` event usually beats the re-read anyway, so the extra read
  /// is mostly free.
  Future<void> focusPane(String paneId) async {
    await _move((client) => client.focusPane(paneId));
  }

  Future<void> focusTab(String tabId) async {
    await _move((client) => client.focusTab(tabId));
  }

  Future<void> focusWorkspace(String workspaceId) async {
    await _move((client) => client.focusWorkspace(workspaceId));
  }

  Future<void> _move(Future<void> Function(HerdrClient) call) async {
    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) return;
    await call(connection.client);
    await refresh();
  }
}

/// The tree, alive only while something is showing it.
///
/// AUTO-DISPOSE IS LOAD-BEARING HERE, not a nicety. Riverpod 3 defaults every
/// provider to `isAutoDispose: false`, and this notifier holds a listener on the
/// board: a permanently-alive tree would re-read `workspace.list`, `tab.list`
/// and `pane.list` — three socket requests — on EVERY board event burst and on
/// every 30-second safety net, forever, including while the user is looking at
/// the board or typing into a terminal. Three extra requests per burst on the
/// same SSH link the terminal is using is exactly how a client makes its own
/// input feel laggy.
///
/// The cost of disposing is one re-read the next time the tree is opened, which
/// on a LAN is a few tens of milliseconds.
final navTreeProvider = AsyncNotifierProvider<NavTreeNotifier, WorkspaceTree>(
  NavTreeNotifier.new,
  isAutoDispose: true,
);
