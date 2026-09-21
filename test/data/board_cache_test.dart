import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WHAT THE BOARD REMEMBERS, AND FROM WHICH READ.
///
/// The board has kept its rows across a reconnect since Phase 26 — but only the
/// reads that went through `build()` were ever remembered. On a flaky link that
/// is not the usual path: events and the 30-second safety net both arrive
/// through `refresh()`, so a session whose first read failed and whose next one
/// succeeded had a full board on screen and an EMPTY memory. The moment the link
/// dropped, `build()` ran again, found nothing to fall back to, and blanked the
/// board — the exact lie the cache exists to prevent. Reported from the phone as
/// 「列表一会出现，一会消失」(2026-09-21).
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  test('a board that arrived through refresh() survives the next reconnect',
      () async {
    final daemon = _BoardDaemon()..failReads = true;
    final run = _Run(prefs);
    addTearDown(run.dispose);

    run.container.read(_statusProvider.notifier).status = _online(daemon);

    // The link is up, the read is not: this is a daemon still starting, or a
    // request that lost its connection halfway. Nothing has been read yet, so
    // there is nothing to remember and the board is honestly empty.
    await _until(() => run.board.hasError);
    expect(run.board.value, isNull);

    // The next read succeeds. On the phone this is a `pane.updated` event
    // landing, or the safety net — not a rebuild, which is exactly why the
    // cache has to be written from here as well.
    daemon.failReads = false;
    await run.container.read(boardProvider.notifier).refresh();
    await _until(() => run.board.value?.rows.isNotEmpty ?? false);

    // And now the link goes: the provider rebuilds, the connection is not
    // Online, and the answer is the board that was read a moment ago.
    final settled = run.nextSettle();
    run.container.read(_statusProvider.notifier).status =
        const Connecting(attempt: 2, afterLoss: true);
    await settled;

    expect(
      run.board.value?.rows,
      hasLength(1),
      reason: 'the rows were on screen a second ago; blanking them says the '
          'agents are gone when what is gone is the connection',
    );
  });

  test('and a board read by build() is remembered too', () async {
    final daemon = _BoardDaemon();
    final run = _Run(prefs);
    addTearDown(run.dispose);

    run.container.read(_statusProvider.notifier).status = _online(daemon);
    await _until(() => run.board.value?.rows.isNotEmpty ?? false);

    final settled = run.nextSettle();
    run.container.read(_statusProvider.notifier).status =
        const Connecting(attempt: 2, afterLoss: true);
    await settled;

    expect(run.board.value?.rows, hasLength(1));
  });

  test("a different machine is never served the previous machine's board",
      () async {
    final daemon = _BoardDaemon();
    final run = _Run(prefs);
    addTearDown(run.dispose);

    run.container.read(_statusProvider.notifier).status = _online(daemon);
    await _until(() => run.board.value?.rows.isNotEmpty ?? false);

    // A machine the app has never read: empty is the only honest answer, and
    // the other host's agents would look right on a screen that is wrong.
    final settled = run.nextSettle();
    run.container.read(_machineProvider.notifier).host = _hostB;
    run.container.read(_statusProvider.notifier).status =
        const Connecting(attempt: 2, afterLoss: true);
    await settled;

    expect(run.board.value?.rows, isEmpty);
  });
}

/// Runs the event queue until [condition] holds.
///
/// Polling rather than awaiting a provider's `future`: a rebuild that fails
/// keeps the previous state around, so `future` can take another whole round of
/// retries (seconds, here) to answer a question this test can ask directly.
Future<void> _until(bool Function() condition, {int turns = 500}) async {
  for (var i = 0; i < turns; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('the condition never became true');
}

const _hostA = HostProfile(
  id: 'a',
  label: 'devbox',
  username: 'dev',
  host: '10.0.0.5',
);
const _hostB = HostProfile(
  id: 'b',
  label: 'laptop',
  username: 'dev',
  host: '10.0.0.6',
);

Online _online(HerdrTransport transport) => Online(
      client: HerdrClient(transport),
      hello: const HerdrHello(version: '0.9.0', protocol: 22),
      socketPath: '/tmp/herdr.sock',
    );

/// One container with the real board provider over a scripted machine.
class _Run {
  _Run(SharedPreferences prefs)
      : container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentHostProvider
                .overrideWith((ref) => ref.watch(_machineProvider)),
            connectionProvider.overrideWith(_ScriptedConnection.new),
          ],
        ) {
    container.read(_machineProvider.notifier).host = _hostA;
    subscription = container.listen(
      boardProvider,
      (_, _) {},
      fireImmediately: true,
    );
  }

  final ProviderContainer container;
  late final ProviderSubscription<AsyncValue<AgentList>> subscription;

  /// The current board state, re-read from the container on every access.
  AsyncValue<AgentList> get board => container.read(boardProvider);

  /// Completes when the provider publishes its next SETTLED state.
  ///
  /// A rebuild answers asynchronously — it waits for the connection provider to
  /// rebuild first — so a test that asserted straight after changing the
  /// connection would still be reading the value the previous build left
  /// behind, and would pass whatever the cache did.
  Future<void> nextSettle() {
    final completer = Completer<void>();
    final sub = container.listen<AsyncValue<AgentList>>(
      boardProvider,
      (_, next) {
        if (!next.isLoading && !completer.isCompleted) completer.complete();
      },
    );
    return completer.future.whenComplete(sub.close);
  }

  void dispose() {
    subscription.close();
    container.dispose();
  }
}

class _Machine extends Notifier<HostProfile?> {
  @override
  HostProfile? build() => _hostA;

  /// Read back through the notifier: a setter needs its getter to be a pair.
  HostProfile? get host => state;
  set host(HostProfile? value) => state = value;
}

final _machineProvider = NotifierProvider<_Machine, HostProfile?>(_Machine.new);

class _Status extends Notifier<ConnectionStatus> {
  @override
  ConnectionStatus build() => const Disconnected();

  ConnectionStatus get status => state;
  set status(ConnectionStatus value) => state = value;
}

final _statusProvider =
    NotifierProvider<_Status, ConnectionStatus>(_Status.new);

class _ScriptedConnection extends ConnectionNotifier {
  /// No `async` and no await: the status is a value the test already owns, and
  /// the future is part of the base class's contract rather than this fake's
  /// work.
  @override
  Future<ConnectionStatus> build() =>
      Future<ConnectionStatus>.value(ref.watch(_statusProvider));
}

/// A machine whose board read can be switched off mid-test.
class _BoardDaemon implements HerdrTransport {
  /// While true, every request fails the way a dropped link fails.
  bool failReads = false;

  @override
  Future<String> roundTrip(String requestLine) async {
    final method =
        (jsonDecode(requestLine) as Map)['method'] as String?;
    if (failReads) {
      throw HerdrTransportException(
        TransportFailure.streamClosed,
        'the SSH connection is gone',
      );
    }
    return switch (method) {
      'agent.list' =>
        '{"id":"1","result":{"type":"agent_list","agents":['
            '{"pane_id":"w1:p1","agent_status":"working","agent":"pi"}]}}',
      'pane.list' =>
        '{"id":"1","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1",'
            '"workspace_id":"w1","tab_id":"w1:t1","focused":true}]}}',
      // The event channel is not what this test is about: the board falls back
      // to its safety net when the subscription cannot be opened, which is a
      // real path and the cheapest one to fake.
      _ => '{"id":"","error":{"code":"unknown_method","message":"n/a"}}',
    };
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError('no event channel on this fake');

  @override
  Future<void> close() async {}
}
