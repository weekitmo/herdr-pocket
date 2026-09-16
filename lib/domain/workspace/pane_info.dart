import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/domain/agent/agent_status.dart';

/// One pane, as `pane.list` reports it.
///
/// Shape verified against a live herdr 0.9.0 (protocol 22):
///
/// ```json
/// {"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","agent":"pi",
///  "agent_status":"done","cwd":"/x","foreground_cwd":"/x","focused":true,
///  "revision":26,"terminal_id":"term_…","terminal_title":"π - x",
///  "label":"Sidebar","title":"晚间行情分析",
///  "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":301,"viewport_rows":46},
///  "tokens":{"ctx":"69k/262k","model":"glm-5.3-flash"}}
/// ```
///
/// The optional set DRIFTS between rows: a plain shell pane carries no `agent`
/// and no `title`; a sidebar pane carries `label` instead of `title`. Every
/// field here is therefore genuinely optional and the UI degrades rather than
/// assuming. `tokens` is not modelled: it is a free-form string map whose keys
/// belong to whatever program happens to be running, so a client that rendered
/// `ctx` prominently would be rendering one agent's UI convention as if it were
/// the protocol's.
class PaneInfo {
  const PaneInfo({
    required this.paneId,
    required this.workspaceId,
    required this.tabId,
    this.agent = '',
    this.agentStatus,
    this.title,
    this.label,
    this.terminalTitle,
    this.cwd,
    this.foregroundCwd,
    this.isFocused = false,
    this.revision,
    this.scrollOffsetFromBottom,
    this.viewportRows,
  });

  factory PaneInfo.fromJson(Map<String, Object?> json) {
    return PaneInfo(
      paneId: _str(json['pane_id']) ?? '',
      workspaceId: _str(json['workspace_id']) ?? '',
      tabId: _str(json['tab_id']) ?? '',
      agent: _str(json['agent']) ?? '',
      agentStatus: _str(json['agent_status']),
      title: _str(json['title']),
      label: _str(json['label']),
      terminalTitle: _str(json['terminal_title']),
      cwd: _str(json['cwd']),
      foregroundCwd: _str(json['foreground_cwd']),
      isFocused: json['focused'] == true,
      revision: switch (json['revision']) {
        final int v => v,
        _ => null,
      },
      scrollOffsetFromBottom: switch (json['scroll']) {
        // `PaneScrollInfo` = how far this pane's viewport is scrolled back,
        // out of how far it can go, and how many rows it has. The client cannot
        // infer any of it from the frames it receives — a rendered frame of
        // history looks exactly like a rendered frame of the present, and a
        // frame is always the size the client asked for — so this is the only
        // place the app can learn that somebody (another client) left the pane
        // scrolled, or that the pane is taller than the window being rendered
        // for it.
        final Map<Object?, Object?> m => switch (m['offset_from_bottom']) {
          final int v => v,
          _ => null,
        },
        _ => null,
      },
      viewportRows: switch (json['scroll']) {
        final Map<Object?, Object?> m => switch (m['viewport_rows']) {
          final int v when v > 0 => v,
          _ => null,
        },
        _ => null,
      },
    );
  }

  final String paneId;

  /// `w9`.
  final String workspaceId;

  /// `w9:t1`.
  final String tabId;

  /// Empty for a plain shell pane — those are not agents.
  final String agent;

  /// The raw wire string, deliberately not pre-mapped. See [AgentStatus] for
  /// why collapsing the unknown cases into a real state is a bug rather than a
  /// convenience.
  final String? agentStatus;

  /// A human-given name (`title`) or the daemon's role label (`label`).
  final String? title;
  final String? label;

  /// What the terminal program set as its own title.
  final String? terminalTitle;

  final String? cwd;
  final String? foregroundCwd;
  final bool isFocused;
  final int? revision;

  /// Lines this pane's viewport is scrolled back from the live bottom, when the
  /// daemon reports it. Null means "not reported", NOT "at the bottom".
  final int? scrollOffsetFromBottom;

  /// How many rows this pane's terminal HAS, in cells.
  ///
  /// The number the daemon is asked to render at, because it crops a pane
  /// rather than reflowing it: ask for fewer rows than this and the bottom of
  /// the pane is simply not in the frame. Null means "not reported" — the
  /// caller then falls back to the widget's own height, which is the old
  /// behaviour.
  final int? viewportRows;

  bool get isAgent => agent.isNotEmpty;

  /// The typed status, applying the same fail-closed mapping the board uses.
  AgentStatus get status => AgentStatus.fromWire(agentStatus);

  /// How this pane should read on a status board.
  ///
  /// THE BOARD'S FAIL-CLOSED GROUPING DOES NOT TRANSFER UNCHANGED, and applying
  /// it here directly was a mistake worth writing down. On the board,
  /// `agent.list` returns ONLY agent terminals, so a missing or unreadable
  /// status is genuinely anomalous and belongs in the loud `unrecognised`
  /// group.
  ///
  /// `pane.list` returns EVERY pane, and a live probe shows what that means:
  /// every plain shell and every sidebar pane reports `agent_status: "unknown"`
  /// as its NORMAL value. Running those through [resolveAgentGroup] put the
  /// amber "this build cannot read it" alarm on four rows out of six — and an
  /// alarm that fires on most of the screen is an alarm nobody reads. Worse, it
  /// would have buried the one pane that genuinely was in a state this build
  /// could not interpret.
  ///
  /// So the discriminator is not the status, it is [isAgent]: a pane is only
  /// judged by its status when it actually claims to be running an agent. A
  /// pane that does is still judged fail-closed.
  AgentGroup get group {
    if (!isAgent) return AgentGroup.idle;
    return resolveAgentGroup((
      status: status,
      lastKnownStatus: const AgentAbsent(),
      // A pane read from `pane.list` exists — that is a fact, not something to
      // infer.
      isLive: true,
      isAwaitingMenuInput: false,
    ));
  }

  /// What to call this pane on a small screen.
  ///
  /// Order is deliberate: a name a human typed beats a title the program set,
  /// which beats the last path segment. A pane id is the last resort because it
  /// is machine noise — but showing it beats showing an empty row.
  String get displayName {
    for (final candidate in [title, label, terminalTitle]) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    final dir = cwd;
    if (dir != null && dir.isNotEmpty) {
      final parts = dir.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isNotEmpty) return parts.last;
    }
    return paneId;
  }

  static String? _str(Object? v) => v is String ? v : null;
}
