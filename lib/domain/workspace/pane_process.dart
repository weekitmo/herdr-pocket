/// What is actually running inside a pane.
///
/// `agent.list` says which panes host a DETECTED agent; it does not say whether
/// the pane's shell is free. That second question is the one `agent.start`
/// depends on — it activates "an existing idle shell pane", so a pane whose
/// foreground process is something else is not a candidate no matter how idle
/// its agent status looks.
///
/// ⚠️ **THE LIST INCLUDES THE PANE'S OWN SHELL, AND ON macOS IT STAYS THERE.**
/// This was first read as "a plain shell answers with an empty list and only
/// `shell_pid` set", and that is wrong often enough to break the feature. A
/// probe of a freshly created pane on macOS (herdr 0.9.0, twelve samples over
/// six seconds) answered, every time from the moment the shell settled:
///
/// ```json
/// "shell_pid": 16345,
/// "foreground_processes": [{"pid": 16345, "name": "zsh", "argv": ["-zsh"]}]
/// ```
///
/// Note `pid == shell_pid`. A rule of "the list is empty" therefore never fires
/// here, every pane looks busy, and starting an agent in an existing pane is
/// refused by us before the daemon is even asked. The rule is about the pid, not
/// about the length: the shell being in the foreground is exactly what we want,
/// and the question is whether anything ELSE is there with it.
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

  /// Every process the daemon calls a foreground process — **including the
  /// pane's own shell**, whose pid is [shellPid].
  ///
  /// Do not test this for emptiness; ask [otherForegroundProcesses] instead.
  final List<ForegroundProcess> foregroundProcesses;

  final String? tty;

  /// The foreground processes that are NOT the pane's own shell.
  ///
  /// This is the list that answers "is anything running in here?" — see the
  /// note on the library for why the raw list cannot.
  ///
  /// When [shellPid] is null the shell has exited, so there is nothing to
  /// subtract and the list is returned as-is; a pane with no shell cannot host
  /// an agent anyway, and the caller refuses it on other grounds.
  List<ForegroundProcess> get otherForegroundProcesses => shellPid == null
      ? foregroundProcesses
      : foregroundProcesses
            .where((p) => p.pid != shellPid)
            .toList(growable: false);

  bool get shellOwnsForeground => otherForegroundProcesses.isEmpty;
}

String? _str(Object? v) => v is String ? v : null;
