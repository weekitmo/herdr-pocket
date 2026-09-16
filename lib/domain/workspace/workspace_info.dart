/// One workspace, as `workspace.list` reports it.
///
/// Live shape (herdr 0.9.0, protocol 22):
///
/// ```json
/// {"workspace_id":"w9","number":1,"label":"my-project",
///  "focused":true,"active_tab_id":"w9:t1","tab_count":3,"pane_count":6,
///  "agent_status":"done"}
/// ```
///
/// The schema also reserves an optional `worktree` object, which the live
/// daemon does not populate. It is not modelled here: a field that is always
/// absent is a field that would be read as "no worktree" when it actually means
/// "this daemon does not say", which is the same class of mistake the agent
/// status type exists to prevent.
class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    required this.number,
    required this.label,
    this.isFocused = false,
    this.activeTabId,
    this.tabCount = 0,
    this.paneCount = 0,
    this.agentStatus,
  });

  factory WorkspaceInfo.fromJson(Map<String, Object?> json) {
    return WorkspaceInfo(
      workspaceId: _str(json['workspace_id']) ?? '',
      number: _int(json['number']) ?? 0,
      label: _str(json['label']) ?? '',
      isFocused: json['focused'] == true,
      activeTabId: _str(json['active_tab_id']),
      tabCount: _int(json['tab_count']) ?? 0,
      paneCount: _int(json['pane_count']) ?? 0,
      agentStatus: _str(json['agent_status']),
    );
  }

  final String workspaceId;
  final int number;
  final String label;
  final bool isFocused;
  final String? activeTabId;
  final int tabCount;
  final int paneCount;
  final String? agentStatus;

  String get displayName => label.trim().isNotEmpty ? label : workspaceId;

  static String? _str(Object? v) => v is String ? v : null;
  static int? _int(Object? v) => v is int ? v : null;
}
