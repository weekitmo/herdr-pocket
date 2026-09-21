import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';

/// The tree one machine last reported, kept OUTSIDE the provider that read it.
///
/// WHY NOT A FIELD ON THE NOTIFIER, the way the board keeps its board: this
/// provider is auto-disposing on purpose (see [navTreeProvider]), so the
/// notifier — and anything it holds — dies with the workspaces page. The next
/// page open is exactly when the memory is needed. On a link that dropped, the
/// re-read answers nothing for as long as the dial takes, and the page falls
/// back to "no workspaces", which is not an answer — it is a lie about the
/// user's machine. Reported from the phone, 2026-09-21: 「切换 nav tab 或者从
/// 另外的页面回来时，原本的列表就不见了」.
///
/// KEYED BY MACHINE, for the same reason the board's cache is: a tree belongs
/// to the daemon that reported it, and the previous host's workspaces would
/// look right on a screen that is wrong — the user would then open a pane that
/// does not exist on the machine they are actually talking to.
class NavTreeCache {
  ({String hostId, WorkspaceTree tree})? _last;

  /// The tree [hostId] last reported, or null if we have never read one.
  WorkspaceTree? forHost(String hostId) =>
      _last?.hostId == hostId ? _last!.tree : null;

  void store(String hostId, WorkspaceTree tree) =>
      _last = (hostId: hostId, tree: tree);
}

/// Alive for the whole app session, deliberately: a cache that the page could
/// dispose would be empty in exactly the case it exists for.
final navTreeCacheProvider = Provider<NavTreeCache>((ref) => NavTreeCache());

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

    final hostId = ref.read(currentHostProvider)?.id ?? '';
    final cache = ref.read(navTreeCacheProvider);
    final remembered = cache.forHost(hostId);

    // SHOW WHAT WE ALREADY HAVE, BEFORE ASKING ANYTHING.
    //
    // Seeding the state is what makes the first frame after this page opens
    // carry the tree instead of an empty page. Waiting for the read would be
    // three requests on a link that may be re-dialling, and the wait is visible
    // as "there are no workspaces" for as long as it lasts. `build`'s own
    // return value still lands when it lands, so the seed is a floor and never
    // a ceiling.
    if (remembered != null) state = AsyncValue.data(remembered);

    final connection = await ref.watch(connectionProvider.future);
    if (connection is! Online) return remembered ?? WorkspaceTree.empty();

    final tree = await connection.client.workspaceTree();
    cache.store(hostId, tree);
    return tree;
  }

  /// Re-reads without clearing what is already on screen.
  ///
  /// Keeps the last good tree on failure for the same reason the board does: a
  /// machine that briefly cannot answer should not make every workspace vanish.
  ///
  /// A successful read is also written to [NavTreeCache] — this is not
  /// bookkeeping, it is the whole point: a board event burst is an ordinary way
  /// for the newest tree to arrive, and a page rebuilt after it must see that
  /// tree and not the one `build` happened to read.
  Future<void> refresh() async {
    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) return;
    final hostId = ref.read(currentHostProvider)?.id ?? '';
    try {
      final tree = await connection.client.workspaceTree();
      // THE PAGE MAY BE GONE BY NOW, and this provider is auto-disposing: a
      // read that lands after the user left would otherwise throw on a disposed
      // ref — a background refresh is not worth an unhandled error.
      if (!ref.mounted) return;
      ref.read(navTreeCacheProvider).store(hostId, tree);
      state = AsyncValue.data(tree);
    } on Object catch (e, st) {
      if (!ref.mounted) return;
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
/// on a LAN is a few tens of milliseconds — and since the tree that was read is
/// remembered in [NavTreeCache], the page shows it while that re-read runs. The
/// cost is therefore never a blank screen, which is what it used to be on a link
/// that was down when the user came back.
final navTreeProvider = AsyncNotifierProvider<NavTreeNotifier, WorkspaceTree>(
  NavTreeNotifier.new,
  isAutoDispose: true,
);
