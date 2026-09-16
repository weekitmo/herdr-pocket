import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/agent_launcher.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/workspace/agent_launch.dart';

/// Waiting for a pane that is not ready yet.
///
/// Written after a live run failed with `agent_pane_busy: agent target pane
/// wH:p1 is not an available shell` — create-then-start raced the shell, and the
/// daemon's `timeout_ms` does not cover it (the refusal is immediate). A
/// scripted fake never caught it because a fake always says yes; this time the
/// fake says NO first, on purpose.
class _ScriptedDaemon implements HerdrTransport {
  _ScriptedDaemon(this.handlers);

  final Map<String, String Function(Map<String, Object?> params)> handlers;
  final List<String> methods = [];
  final List<Map<String, Object?>> calls = [];

  @override
  Future<String> roundTrip(String requestLine) async {
    final req = (jsonDecode(requestLine) as Map).cast<String, Object?>();
    final method = req['method']! as String;
    methods.add(method);
    calls.add(req);
    final handler = handlers[method];
    if (handler == null) {
      return '{"id":"","error":{"code":"unknown_method","message":"no handler"}}';
    }
    return handler((req['params']! as Map).cast<String, Object?>());
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) => throw UnimplementedError();

  @override
  Future<void> close() async {}

  Map<String, Object?> paramsOf(String method) {
    for (final c in calls.reversed) {
      if (c['method'] == method) {
        return (c['params']! as Map).cast<String, Object?>();
      }
    }
    return const {};
  }

  bool got(String method) => methods.contains(method);
}

String _paneList({bool present = true}) =>
    '{"id":"x","result":{"type":"pane_list","panes":['
    '${present ? '{"pane_id":"wH:p1","workspace_id":"wH","tab_id":"wH:t1"}' : ''}]}}';

/// A pane whose shell is NOT yet in the foreground — what a freshly created
/// workspace actually looks like.
String _busyProcess() =>
    '{"id":"x","result":{"type":"pane_process_info","process_info":'
    '{"pane_id":"wH:p1","foreground_processes":[{"pid":9,"name":"sh"}]}}}';

String _freeProcess() =>
    '{"id":"x","result":{"type":"pane_process_info","process_info":'
    '{"pane_id":"wH:p1","shell_pid":9,"foreground_processes":[]}}}';

const _started = '{"id":"x","result":{"type":"agent_started",'
    '"agent":{"pane_id":"wH:p1","agent":"pi","agent_status":"working"},'
    '"argv":["pi"]}}';

void main() {
  test('waits for the shell, then starts exactly once', () async {
    // Three probes are busy, the fourth is free. This is the live failure
    // reproduced: the agent must NOT be started while the shell is not ready.
    var probes = 0;
    final daemon = _ScriptedDaemon({
      'pane.list': (_) => _paneList(),
      'pane.process_info': (_) {
        probes++;
        return probes < 4 ? _busyProcess() : _freeProcess();
      },
      'agent.start': (_) => _started,
    });

    final agent = await AgentLauncher(HerdrClient(daemon)).startWhenReady(
      paneId: 'wH:p1',
      name: 'pocket',
      kind: 'pi',
      // The loop is attempt-counted, so the timeout and the interval are what
      // decide how many probes happen — one millisecond is enough.
      timeout: const Duration(milliseconds: 50),
      interval: const Duration(milliseconds: 1),
    );

    expect(agent?.agent, 'pi');
    expect(probes, 4);
    expect(daemon.methods.where((m) => m == 'agent.start').length, 1);
  });

  test('a busy pane that never frees up gives up, naming the reason', () async {
    final daemon = _ScriptedDaemon({
      'pane.list': (_) => _paneList(),
      'pane.process_info': (_) => _busyProcess(),
    });

    await expectLater(
      AgentLauncher(HerdrClient(daemon)).startWhenReady(
        paneId: 'wH:p1',
        name: 'pocket',
        kind: 'pi',
        timeout: const Duration(milliseconds: 5),
        interval: const Duration(milliseconds: 1),
      ),
      throwsA(isA<AgentLaunchException>()
          .having((e) => e.reason, 'reason', LaunchBlock.busy)),
    );
    expect(daemon.got('agent.start'), isFalse);
  });

  test('a pane that is gone is not retried', () async {
    final daemon = _ScriptedDaemon({'pane.list': (_) => _paneList(present: false)});

    await expectLater(
      AgentLauncher(HerdrClient(daemon)).startWhenReady(
        paneId: 'wH:p1',
        name: 'pocket',
        kind: 'pi',
        interval: const Duration(milliseconds: 1),
      ),
      throwsA(isA<AgentLaunchException>()
          .having((e) => e.reason, 'reason', LaunchBlock.gone)),
    );
    // One probe and out: waiting for a pane that no longer exists is waiting
    // for nothing.
    expect(daemon.methods.where((m) => m == 'pane.list').length, 1);
  });

  test('a pane that goes busy between the probe and the call is waited out',
      () async {
    // The daemon can refuse even after a clean probe. That is the same
    // condition, so it is retried rather than reported as a failure.
    var attempts = 0;
    final daemon = _ScriptedDaemon({
      'pane.list': (_) => _paneList(),
      'pane.process_info': (_) => _freeProcess(),
      'agent.start': (_) {
        attempts++;
        if (attempts == 1) {
          return '{"id":"","error":{"code":"agent_pane_busy",'
              '"message":"not an available shell"}}';
        }
        return _started;
      },
    });

    final agent = await AgentLauncher(HerdrClient(daemon)).startWhenReady(
      paneId: 'wH:p1',
      name: 'pocket',
      kind: 'pi',
      timeout: const Duration(milliseconds: 50),
      interval: const Duration(milliseconds: 1),
    );

    expect(agent, isNotNull);
    expect(attempts, 2);
  });

  test('a refusal that is NOT about readiness is raised, not retried', () async {
    final daemon = _ScriptedDaemon({
      'pane.list': (_) => _paneList(),
      'pane.process_info': (_) => _freeProcess(),
      'agent.start': (_) => '{"id":"","error":{"code":"unknown_kind",'
          '"message":"no such agent kind"}}',
    });

    await expectLater(
      AgentLauncher(HerdrClient(daemon)).startWhenReady(
        paneId: 'wH:p1',
        name: 'pocket',
        kind: 'nope',
        interval: const Duration(milliseconds: 1),
      ),
      throwsA(isA<HerdrApiException>()),
    );
  });

  test('a failed probe is a refusal, never a green light', () async {
    final daemon = _ScriptedDaemon({
      'pane.list': (_) => throw HerdrTransportException(
            TransportFailure.streamClosed,
            'closed',
          ),
    });

    await expectLater(
      AgentLauncher(HerdrClient(daemon)).startWhenReady(
        paneId: 'wH:p1',
        name: 'pocket',
        kind: 'pi',
        timeout: const Duration(milliseconds: 5),
        interval: const Duration(milliseconds: 1),
      ),
      throwsA(isA<AgentLaunchException>()),
    );
    expect(daemon.got('agent.start'), isFalse);
  });
}
