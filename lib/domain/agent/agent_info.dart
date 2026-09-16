/// One agent as `agent.list` reports it.
///
/// Field shape verified against a live herdr 0.9.0 (protocol 22):
///
/// ```json
/// {"terminal_id":"term_65b180c353d1b2","agent":"pi",
///  "terminal_title":"pi - my-project","agent_status":"working",
///  "workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":true,
///  "state_change_seq":9577,"cwd":"/x","foreground_cwd":"/x","revision":26}
/// ```
///
/// The upstream field set DRIFTS between versions and between rows: the probe
/// saw one row carrying `title` + `tokens` and another carrying neither.
/// Every optional field below is therefore genuinely optional, and callers must
/// degrade rather than assume. `status_since`, `input_pending` and
/// `last_known_status` exist only on newer/forked daemons — we parse them when
/// present and fall back when not.
class AgentInfo {
  const AgentInfo({
    required this.paneId,
    required this.agent,
    this.terminalId,
    this.title,
    this.terminalTitle,
    this.agentStatus,
    this.lastKnownStatus,
    this.workspaceId,
    this.tabId,
    this.isFocused = false,
    this.stateChangeSeq,
    this.revision,
    this.cwd,
    this.foregroundCwd,
    this.inputPending = false,
    this.isArchived = false,
    this.archivedAt,
    this.statusSinceUnixMs,
    this.lastCompletedTurnUnixMs,
    this.tokens = const {},
  });

  /// Builds from a decoded `agent.list` entry.
  ///
  /// Tolerant by construction: an unknown key is ignored, a missing key leaves
  /// the field null, and a wrong-typed value is treated as missing rather than
  /// throwing. A client that crashes on an unexpected field is worse than one
  /// that shows a slightly poorer row.
  factory AgentInfo.fromJson(Map<String, Object?> json) {
    return AgentInfo(
      paneId: _str(json['pane_id']) ?? '',
      agent: _str(json['agent']) ?? '',
      terminalId: _str(json['terminal_id']),
      title: _str(json['title']),
      terminalTitle: _str(json['terminal_title']),
      agentStatus: _str(json['agent_status']),
      lastKnownStatus: _str(json['last_known_status']),
      workspaceId: _str(json['workspace_id']),
      tabId: _str(json['tab_id']),
      isFocused: json['focused'] == true,
      stateChangeSeq: _int(json['state_change_seq']),
      revision: _int(json['revision']),
      cwd: _str(json['cwd']),
      foregroundCwd: _str(json['foreground_cwd']),
      inputPending: json['input_pending'] == true,
      isArchived: json['archived'] != null,
      archivedAt: _str(_mapOrNull(json['archived'])?['at']),
      statusSinceUnixMs: _int(json['status_since_unix_ms']),
      lastCompletedTurnUnixMs:
          _int(_mapOrNull(json['last_completed_turn'])?['completed_unix_ms']),
      tokens: _mapOrNull(json['tokens']) ?? const {},
    );
  }

  /// Public pane id, e.g. `w9:p1`. The stable identity of a row.
  final String paneId;

  /// Agent kind, e.g. `claude`, `codex`, `pi`.
  final String agent;

  final String? terminalId;

  /// A user-set title that overrides the terminal title when present.
  final String? title;

  /// The terminal's own title.
  final String? terminalTitle;

  /// The RAW `agent_status` string. Null means the field was absent. Kept
  /// unwrapped so [AgentStatus.fromWire] can distinguish absent from unknown.
  final String? agentStatus;

  /// The raw `last_known_status`, used only for the blocked escalation.
  final String? lastKnownStatus;

  final String? workspaceId;
  final String? tabId;
  final bool isFocused;

  /// Counts agent LIFECYCLE transitions, not terminal output. A live
  /// measurement held `state_change_seq = 1092` across 13 distinct screens in
  /// 26 s, so it is usable as a positive signal of change and NEVER as evidence
  /// that nothing changed.
  final int? stateChangeSeq;

  final int? revision;
  final String? cwd;
  final String? foregroundCwd;

  /// True when the agent is showing a plan-approval / AskUserQuestion menu.
  /// Absent on stock herdr 0.9.0, so this is false unless a newer server says
  /// otherwise.
  final bool inputPending;

  final bool isArchived;
  final String? archivedAt;

  /// When the agent entered its CURRENT state, if the server reports it.
  /// Preferred time anchor for "how long has it been like this".
  final int? statusSinceUnixMs;

  /// Fallback time anchor on servers too old to send `status_since_unix_ms`.
  final int? lastCompletedTurnUnixMs;

  /// The agent's own free-form key/value state, reported by the integration.
  ///
  /// A real live row carries `{"ctx":"69k/262k","model":"glm-5.3-flash"}`, and
  /// an earlier version of this class threw that away as "one agent's UI
  /// convention". That was the wrong call: `tokens` is the only place the
  /// daemon says WHICH MODEL is answering and HOW FULL its context is, and
  /// those are the two things a person watching five agents actually wants to
  /// know. The keys belong to the integration, so the values are carried raw
  /// and interpreted only where they are read — see [contextUsage] and [model].
  final Map<String, Object?> tokens;

  /// The model answering, if the integration reports one.
  ///
  /// Recognises the key the live integrations use. A different key is not an
  /// error and gets no guess: an agent that does not say what it is running
  /// simply shows nothing.
  String? get model {
    for (final key in const ['model', 'model_name', 'modelName']) {
      final value = tokens[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// Context used and total, in whatever unit the integration chose.
  ///
  /// Parsed from `"69k/262k"` — the shape every live integration uses — and
  /// returned as plain numbers so the UI can draw a bar. A pair that does not
  /// parse, or a zero total, returns null rather than a bar with a made-up
  /// fraction: a progress indicator that is wrong is worse than no progress
  /// indicator, because it is believed.
  ({int used, int total})? get contextUsage {
    for (final key in const ['ctx', 'context', 'context_usage']) {
      final value = tokens[key];
      if (value is! String) continue;
      final parsed = _parsePair(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// Reads `"69k/262k"`, `"69K / 262K"` or `"69000/262000"`.
  static ({int used, int total})? _parsePair(String raw) {
    final parts = raw.split('/');
    if (parts.length != 2) return null;
    final used = _parseCount(parts[0]);
    final total = _parseCount(parts[1]);
    if (used == null || total == null || total <= 0) return null;
    return (used: used, total: total);
  }

  static int? _parseCount(String raw) {
    final text = raw.trim().toLowerCase().replaceAll(',', '');
    if (text.isEmpty) return null;
    final multiplier = text.endsWith('k')
        ? 1000
        : text.endsWith('m')
            ? 1000000
            : 1;
    final digits = multiplier == 1 ? text : text.substring(0, text.length - 1);
    final value = double.tryParse(digits);
    if (value == null || value < 0) return null;
    return (value * multiplier).round();
  }

  /// The name to show. Prefers an explicit title, then the terminal title,
  /// then the agent kind, then the pane id — never empty, because an
  /// empty-titled row is indistinguishable from a broken one.
  String get displayName {
    for (final candidate in [title, terminalTitle, agent, paneId]) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return paneId;
  }

  /// The single instant "how long has it been in this state" is measured from.
  ///
  /// There is one right answer and two screens that must not disagree about it
  /// (the board card's badge and the terminal header's timer). `status_since`
  /// is it; the completed-turn stamp survives only as the fallback for a daemon
  /// too old to report it — an approximate timer beats none, and on those
  /// servers both screens still agree because both land here.
  int? get statusAnchorUnixMs => statusSinceUnixMs ?? lastCompletedTurnUnixMs;
}

String? _str(Object? v) => v is String ? v : null;

int? _int(Object? v) => switch (v) {
  int() => v,
  // The daemon is known to send epoch values as strings on some fields.
  String() => int.tryParse(v),
  _ => null,
};

Map<String, Object?>? _mapOrNull(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;
