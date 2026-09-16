/// What is actually running inside a pane.
///
/// `agent.list` says which panes host a DETECTED agent; it does not say whether
/// the pane's shell is free. That second question is the one `agent.start`
/// depends on — it activates "an existing idle shell pane", so a pane whose
/// foreground process is something else is not a candidate no matter how idle
/// its agent status looks.
///
/// Verified against a live 0.9.0: an agent pane answers with
/// `foreground_processes: [{argv0: "pi", name: "node", pid: 977, cwd: …}]`,
/// while a plain shell answers with an empty list and only `shell_pid` set.
library;

/// One process holding a pane's foreground.
class ForegroundProcess {
  const ForegroundProcess({
    required this.pid,
    required this.name,
    this.argv0,
    this.cwd,
  });

  factory ForegroundProcess.fromJson(Map<String, Object?> json) =>
      ForegroundProcess(
        pid: switch (json['pid']) {
          final int v => v,
          final String v => int.tryParse(v) ?? 0,
          _ => 0,
        },
        name: _str(json['name']) ?? '',
        argv0: _str(json['argv0']),
        cwd: _str(json['cwd']),
      );

  final int pid;

  /// The process's own name, e.g. `node`.
  final String name;

  /// How it was invoked, e.g. `pi`. Preferred for display: it is what the user
  /// recognises, while `name` is often just the runtime.
  final String? argv0;

  final String? cwd;

  String get displayName {
    final a = argv0?.trim();
    if (a != null && a.isNotEmpty) return a;
    return name.isEmpty ? 'pid $pid' : name;
  }
}

/// `pane.process_info`'s answer.
class PaneProcessInfo {
  const PaneProcessInfo({
    required this.paneId,
    this.shellPid,
    this.foregroundProcesses = const [],
    this.tty,
  });

  factory PaneProcessInfo.fromJson(Map<String, Object?> json) {
    final procs = json['foreground_processes'];
    return PaneProcessInfo(
      paneId: _str(json['pane_id']) ?? '',
      shellPid: switch (json['shell_pid']) {
        final int v => v,
        final String v => int.tryParse(v),
        _ => null,
      },
      foregroundProcesses: procs is List
          ? procs
              .whereType<Map<Object?, Object?>>()
              .map((e) => ForegroundProcess.fromJson(e.cast<String, Object?>()))
              .toList(growable: false)
          : const [],
      tty: _str(json['tty']),
    );
  }

  final String paneId;

  /// The pane's allotted shell. Null when the shell has exited.
  final int? shellPid;

  /// Empty means the shell owns the foreground — the condition `agent.start`
  /// needs.
  final List<ForegroundProcess> foregroundProcesses;

  final String? tty;

  bool get shellOwnsForeground => foregroundProcesses.isEmpty;
}

String? _str(Object? v) => v is String ? v : null;
