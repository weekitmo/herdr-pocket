import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which board sections the user has CLOSED, remembered per machine.
///
/// ## The default is "everything open"
///
/// It used to be one section — working, else approvals, else idle — chosen by
/// `defaultExpandedGroup`, on the argument that a board which opened everything
/// let a fleet of idle agents bury the one that was stuck. That argument lost to
/// the user's own experience of it: the working section is at the TOP when it
/// exists (the order is the screen's whole argument), so the row that needs you
/// is never below the fold, and a user who wants a quieter screen can close the
/// sections they do not care about — which is the point of remembering it.
///
/// ## Remembered, not held in the page
///
/// The old state was two `Set`s on `BoardPage`, with a comment explaining that
/// it "should reset when the app does". It reset far more often than that: any
/// rebuild of the root shell — switching to Settings and back is enough —
/// threw the user's choice away, and the board came back with the default. The
/// memory now lives on disk, keyed by MACHINE, because two machines have two
/// different boards and a preference about "idle" on one says nothing about the
/// other.
///
/// ## Why the state is a set of CLOSED groups
///
/// The complement would mean a group the user has never seen starts collapsed,
/// and the first board after an upgrade would be a list of headings. Storing
/// what was closed makes "never touched" and "explicitly opened" the same
/// answer, which is what the default already is.
///
/// ## Bounded on purpose — and therefore not pruned
///
/// Five groups exist, so the stored set can hold at most five names; there is
/// nothing to garbage-collect, and pruning against the CURRENT board would be
/// actively wrong. Agents are closed on the remote machine all the time, and a
/// section that vanishes for a minute (every idle agent exited) is not the user
/// saying "forget that I collapsed this". The remembered name stays, and the
/// section comes back the way the user left it.
///
/// What the memory never does is invent rows: the sections drawn are always the
/// live ones from `AgentList` — a group with nothing in it is not rendered at
/// all (see `AgentList.sections`), so a remotely-closed tab simply stops being
/// listed while its preference waits.
class BoardSectionsNotifier extends Notifier<Set<AgentGroup>> {
  @override
  Set<AgentGroup> build() {
    // Read SYNCHRONOUSLY, like every other preference in this app: `main()`
    // awaits `SharedPreferences` before the first frame and injects it, so the
    // first board already has the user's own answer on it. An async load would
    // show the default for a frame and then jump.
    final prefs = ref.watch(sharedPreferencesProvider);
    final hostId = ref.watch(currentHostProvider)?.id ?? '';
    return _read(prefs, hostId);
  }

  /// Opens a closed section, or closes an open one.
  Future<void> toggle(AgentGroup group) async {
    // THE HOST IS READ ONCE, BEFORE THE SET IS BUILT, so the state change and
    // the write that remembers it are about the same machine. Resolving it
    // again at the bottom would be a second read of a value that can move
    // underneath — the user can switch machines between the tap and the write —
    // and the failure mode is a preference stored under the wrong machine's
    // name, which is invisible until the user goes back to the first one.
    final hostId = _hostId;
    final next = {...state};
    // `remove` returns false when it was not there, which is the "open it" case
    // — one branch instead of a `contains` test followed by a branch, so the
    // set is read once.
    if (!next.remove(group)) next.add(group);
    state = next;
    await _write(hostId, next);
  }

  /// Whether [group] should be drawn closed.
  bool isCollapsed(AgentGroup group) => state.contains(group);

  String get _hostId => ref.read(currentHostProvider)?.id ?? '';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  /// `board.collapsed.<hostId>` → the group names that are closed.
  static String _key(String hostId) => 'board.collapsed.$hostId';

  static Set<AgentGroup> _read(SharedPreferences prefs, String hostId) {
    final names = prefs.getStringList(_key(hostId));
    if (names == null) return const {};
    final byName = {for (final g in AgentGroup.values) g.name: g};
    // Unknown names are DROPPED rather than throwing: a stored file outlives
    // the build that wrote it, and a group removed from the enum must cost the
    // user that one preference rather than the whole screen.
    return {for (final name in names) ?byName[name]};
  }

  Future<void> _write(String hostId, Set<AgentGroup> groups) async {
    if (hostId.isEmpty) return;
    await _prefs.setStringList(_key(hostId), [
      for (final group in AgentGroup.values)
        if (groups.contains(group)) group.name,
    ]);
  }
}

/// The board's open/closed state, for the machine the app is pointed at.
final boardSectionsProvider =
    NotifierProvider<BoardSectionsNotifier, Set<AgentGroup>>(
  BoardSectionsNotifier.new,
);
