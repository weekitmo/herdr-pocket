import 'dart:async';

import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/workspace/agent_launch.dart';

/// Starting an agent in a pane that may not be READY yet.
///
/// This exists because of a real failure, found by running the write path
/// against a live daemon:
///
/// ```text
/// agent_pane_busy: agent target pane wH:p1 is not an available shell
/// ```
///
/// `workspace.create` returns as soon as the workspace exists, but its root
/// pane's shell takes a moment to become the foreground process — and
/// `agent.start` requires exactly that. Worse, the daemon's own `timeout_ms`
/// does NOT cover it: the refusal comes back immediately, so passing a generous
/// timeout changes nothing. Scripted fakes cannot catch this, because a fake
/// always says yes.
///
/// So the client waits for the condition it is actually waiting on — the shell
/// owning the foreground — using the same [evaluateLaunchSurface] judgement the
/// UI shows, rather than sleeping for a guessed interval.
class AgentLauncher {
  const AgentLauncher(this._client);

  final HerdrClient _client;

  /// How long to keep asking before giving up.
  ///
  /// Ten seconds is generous for a shell prompt and short enough that a person
  /// is still looking at the screen when it fails.
  static const readyTimeout = Duration(seconds: 10);

  static const pollInterval = Duration(milliseconds: 250);

  /// Starts [kind] in [paneId] once the pane can take it.
  ///
  /// Throws [AgentLaunchException] when the pane never becomes available, or
  /// when it is gone — which is a different answer and is not retried.
  Future<AgentInfo?> startWhenReady({
    required String paneId,
    required String name,
    required String kind,
    Duration timeout = readyTimeout,
    Duration interval = pollInterval,
  }) async {
    // ATTEMPT-COUNTED, not wall-clock. A `DateTime.now()` deadline cannot be
    // advanced by a test's fake clock, so the loop would spin forever under
    // `tester.pump` — and a timeout that behaves differently in a test than in
    // production is a timeout nobody can write a test for.
    final attempts = interval > Duration.zero
        ? (timeout.inMilliseconds / interval.inMilliseconds).ceil().clamp(1, 10000)
        : 1;
    LaunchBlock? lastBlock;
    String? lastHolder;

    for (var attempt = 0; attempt < attempts; attempt++) {
      final surface = await _probe(paneId);
      switch (surface) {
        case CanLaunch():
          try {
            return await _client.agentStart(
              name: name,
              kind: kind,
              paneId: paneId,
              // The daemon's own allowance for the agent's STARTUP (not for the
              // pane becoming ready — that is what the loop above is for).
              timeoutMs: 10000,
            );
          } on HerdrApiException catch (e) {
            // A pane can also become busy again between the probe and the
            // call. Treated as "not ready yet" rather than as a failure, as
            // long as there is time left.
            if (!_isNotReady(e.code)) rethrow;
            lastBlock = LaunchBlock.busy;
            lastHolder = e.code;
          }
        case CannotLaunch(reason: LaunchBlock.gone):
          // Nothing to wait for.
          throw const AgentLaunchException(LaunchBlock.gone);
        case CannotLaunch(:final reason, :final holder):
          lastBlock = reason;
          lastHolder = holder;
      }

      if (attempt < attempts - 1) await Future<void>.delayed(interval);
    }

    // `?? unknown` rather than a bare read: with the loop now counted rather
    // than clocked, the compiler cannot prove every path assigned it, and
    // "we ran out of attempts without learning why" is a real answer.
    throw AgentLaunchException(lastBlock ?? LaunchBlock.unknown, holder: lastHolder);
  }

  Future<LaunchSurface> _probe(String paneId) async {
    try {
      final panes = await _client.paneList();
      final pane = panes.where((p) => p.paneId == paneId).firstOrNull;
      if (pane == null) return const CannotLaunch(LaunchBlock.gone);
      final process = await _client.paneProcessInfo(paneId: paneId);
      return evaluateLaunchSurface(
        pane: pane,
        process: process,
        paneIsLive: true,
      );
    } on Object {
      // A failed probe is "we could not check", which is a refusal, not a
      // green light — the same rule the domain applies.
      return const CannotLaunch(LaunchBlock.unknown);
    }
  }

  /// The two codes the daemon uses for "not yet".
  static bool _isNotReady(String code) =>
      code == 'agent_pane_busy' || code == 'agent_not_ready';
}

/// Raised when a pane never became able to take an agent.
class AgentLaunchException implements Exception {
  const AgentLaunchException(this.reason, {this.holder});

  final LaunchBlock reason;
  final String? holder;

  @override
  String toString() => 'AgentLaunchException($reason${holder == null ? '' : ': $holder'})';
}
