/// Deciding where an agent can be started, and what to call it.
///
/// `agent.start` is narrower than it looks: it activates **an existing idle
/// shell pane** whose interactive shell owns the foreground. So "can I start an
/// agent here?" is a question about PROCESSES, not about agent status — and
/// getting it wrong produces a refusal from the daemon that explains nothing
/// about which of the three conditions failed.
///
/// All of that is decided here, purely, so the UI can say WHY before the user
/// taps rather than after.
library;

import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/pane_process.dart';

/// One agent herdr knows how to start, from `integration.list`.
///
/// The list is the daemon's, not ours: 17 targets on a live 0.9.0, each with
/// the command it would run. Hard-coding the names would have been wrong twice
/// over — the target is not always the command (`cursor` runs `cursor-agent`,
/// `antigravity_cli` runs `agy`), and a new upstream agent would be invisible.
class AgentIntegration {
  const AgentIntegration({
    required this.target,
    required this.label,
    required this.command,
    this.available = false,
    this.state = '',
  });

  factory AgentIntegration.fromJson(Map<String, Object?> json) =>
      AgentIntegration(
        target: _str(json['target']) ?? '',
        label: _str(json['label']) ?? '',
        command: _str(json['command']) ?? '',
        available: json['available'] == true,
        state: _str(json['state']) ?? '',
      );

  /// The `kind` to pass to `agent.start`.
  final String target;

  /// Display name.
  final String label;

  /// The binary herdr would run.
  final String command;

  /// Whether that binary exists ON THAT MACHINE. The single most useful field
  /// here: offering an agent that is not installed is offering a failure.
  final bool available;

  /// The raw integration state (e.g. `not_installed`), carried verbatim because
  /// it belongs to the daemon and new values are expected.
  final String state;

  String get displayName => label.isNotEmpty ? label : target;
}

/// Why a pane cannot host a new agent.
enum LaunchBlock {
  /// The pane is gone.
  gone,

  /// An agent is already detected in it.
  alreadyAgent,

  /// Something else owns the foreground — a shell command, a TUI, a build.
  busy,

  /// The daemon did not answer the process question, so we cannot prove the
  /// shell is free.
  ///
  /// This is a refusal on purpose. "We could not check" is not "it is free",
  /// and the cost of being wrong is starting an agent on top of somebody's
  /// running process.
  unknown,
}

/// Where an agent could go.
sealed class LaunchSurface {
  const LaunchSurface();
}

/// This pane can host one.
final class CanLaunch extends LaunchSurface {
  const CanLaunch();
}

/// This pane cannot, for [reason]. [holder] names the process or agent in the
/// way, when we know it.
final class CannotLaunch extends LaunchSurface {
  const CannotLaunch(this.reason, {this.holder});

  final LaunchBlock reason;
  final String? holder;
}

/// Judges one pane.
///
/// [process] is null when the process question has not been asked or failed to
/// answer — see [LaunchBlock.unknown].
LaunchSurface evaluateLaunchSurface({
  required PaneInfo pane,
  required PaneProcessInfo? process,
  required bool paneIsLive,
}) {
  if (!paneIsLive) return const CannotLaunch(LaunchBlock.gone);

  // Checked before the process list so the message can name the agent rather
  // than whatever runtime is under it (`claude` rather than `node`).
  if (pane.agent.trim().isNotEmpty) {
    return CannotLaunch(LaunchBlock.alreadyAgent, holder: pane.agent);
  }

  if (process == null) return const CannotLaunch(LaunchBlock.unknown);

  if (process.foregroundProcesses.isNotEmpty) {
    return CannotLaunch(
      LaunchBlock.busy,
      holder: process.foregroundProcesses.first.displayName,
    );
  }

  return const CanLaunch();
}

/// A name for the new agent that is not already taken.
///
/// `agent.start` needs one, and a duplicate is refused by the daemon with a
/// message about the name — so the default is derived rather than blank: the
/// kind, then `kind-2`, `kind-3`… The user can always edit it.
String suggestAgentName({
  required String kind,
  Iterable<String> taken = const [],
  int limit = 50,
}) {
  final base = kind.trim().isEmpty ? 'agent' : kind.trim();
  final used = taken.map((t) => t.trim()).toSet();
  if (!used.contains(base)) return base;
  for (var n = 2; n <= limit; n++) {
    final candidate = '$base-$n';
    if (!used.contains(candidate)) return candidate;
  }
  return base;
}

/// A sensible default working directory for a new workspace.
///
/// Prefers a pane that already sits in the repository, because "start another
/// agent where I am working" is the common case. Returns null when nothing
/// knows a directory — and null means ASK, not guess: `workspace.create` with a
/// path that does not exist is a failure the user then has to decode.
String? defaultWorkingDirectory(Iterable<PaneInfo> panes) {
  for (final pane in panes) {
    final cwd = pane.foregroundCwd?.trim().isNotEmpty ?? false
        ? pane.foregroundCwd!.trim()
        : pane.cwd?.trim();
    if (cwd != null && cwd.isNotEmpty) return cwd;
  }
  return null;
}

String? _str(Object? v) => v is String ? v : null;
