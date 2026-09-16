/// One tab, as `tab.list` reports it.
///
/// Live shape (herdr 0.9.0, protocol 22):
///
/// ```json
/// {"tab_id":"w9:t1","workspace_id":"w9","number":1,"label":"Agent",
///  "focused":true,"pane_count":2,"agent_status":"done"}
/// ```
class TabInfo {
  const TabInfo({
    required this.tabId,
    required this.workspaceId,
    required this.number,
    required this.label,
    this.isFocused = false,
    this.paneCount = 0,
    this.agentStatus,
  });

  factory TabInfo.fromJson(Map<String, Object?> json) {
    return TabInfo(
      tabId: _str(json['tab_id']) ?? '',
      workspaceId: _str(json['workspace_id']) ?? '',
      number: _int(json['number']) ?? 0,
      label: _str(json['label']) ?? '',
      isFocused: json['focused'] == true,
      paneCount: _int(json['pane_count']) ?? 0,
      agentStatus: _str(json['agent_status']),
    );
  }

  final String tabId;
  final String workspaceId;

  /// 1-based, and the same number herdr shows in its own tab bar — so a
  /// screenshot of the machine and this screen can be compared by eye.
  final int number;

  final String label;
  final bool isFocused;
  final int paneCount;

  /// Aggregate status across the tab's agent panes, as the daemon computed it.
  final String? agentStatus;

  String get displayName => label.trim().isNotEmpty ? label : tabId;

  static String? _str(Object? v) => v is String ? v : null;
  static int? _int(Object? v) => v is int ? v : null;
}
