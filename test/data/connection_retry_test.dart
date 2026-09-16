import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_socket_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dial's retry loop, exercised against the real provider.
///
/// WHY HERE AND NOT IN A WIDGET TEST. "Three tries, then stop" is a promise
/// about time and network state, and the two ways to get it wrong are both
/// invisible on a happy path: retrying a failure that cannot change (thirty
/// seconds of spinner before the same sentence) and giving up on one that could
/// (the app was correct and useless). Both are properties of
/// [ConnectionNotifier] itself, so they are asserted against it with the
/// connector and the delay swapped out — the same code path the app runs, with
/// the waiting removed.
void main() {
  test('a dial that fails transiently is retried and ends up online', () async {
    final run = await _Run.start([
      _unreachable(),
      _unreachable(),
      null, // the third try works
    ]);

    expect(
      run.connector.dials,
      3,
      reason: 'three dials, the last one successful',
    );
    expect(run.seen.whereType<Online>(), hasLength(1));
    expect(
      run.seen.whereType<Connecting>().map((c) => c.stage),
      [
        ConnectStage.dialling, // try 1
        ConnectStage.dialling, // try 2, announced before its backoff wait
        ConnectStage.dialling, // try 3
        ConnectStage.verifying, // try 3 reached the daemon
      ],
      reason: 'the user is told which try is running, and that a late dial got '
          'as far as talking to the daemon',
    );
    expect(
      run.seen.whereType<Connecting>().map((c) => c.attempt),
      // Four entries for three tries: the last one publishes both of its
      // stages, and only it got as far as the second.
      [1, 2, 3, 3],
      reason: 'the try number is what the retry wording counts from',
    );
    expect(
      run.seen.whereType<Connecting>().map((c) => c.attempt).toSet(),
      {1, 2, 3},
    );
  });

  test('the loop stops at connectionMaxAttempts and reports the failure', () async {
    final run = await _Run.start([_unreachable()]);

    expect(connectionMaxAttempts, 3, reason: 'the ceiling the UI promises');
    expect(run.connector.dials, connectionMaxAttempts);
    expect(run.status, isA<ConnectionFailed>());
    expect((run.status! as ConnectionFailed).attempts, connectionMaxAttempts);

    // Exactly one try is the last one, and it is the final try — the wording
    // "one last attempt" is a promise that there is nothing after it.
    final connecting = run.seen.whereType<Connecting>().toList();
    expect(connecting.where((c) => c.isLastAttempt), hasLength(1));
    expect(connecting.last.isLastAttempt, isTrue);
  });

  test('a credential the user has to fix is not retried', () async {
    final run = await _Run.start([
      HerdrTransportException(
        TransportFailure.authenticationFailed,
        'Permission denied (publickey)',
      ),
    ]);

    expect(
      run.connector.dials,
      1,
      reason: 'the same wrong password three times is not a retry, it is a '
          'thirty-second delay before the same sentence',
    );
    expect((run.status! as ConnectionFailed).attempts, 1);
  });

  test('a host key waiting for a human is not retried', () async {
    final run = await _Run.start([
      HerdrTransportException(
        TransportFailure.hostKeyUnknown,
        'unknown host key',
      ),
    ]);

    expect(run.connector.dials, 1);
  });

  test('a machine with no herdr is not retried', () async {
    final run = await _Run.start([
      HerdrTransportException(
        TransportFailure.connectFailed,
        'herdr not found: $herdrNotInstalledSentinel',
      ),
    ]);

    expect(
      run.connector.dials,
      1,
      reason: 'the command already ran on the other side and answered',
    );
    expect((run.status! as ConnectionFailed).isHerdrMissing, isTrue);
  });

  test('a second request dials again even after the first gave up', () async {
    final run = await _Run.start([_unreachable()]);
    expect(run.connector.dials, connectionMaxAttempts);

    // The user taps retry. One tap is one more sequence — not a sequence that
    // continues from where the last one stopped.
    run.container.read(connectRequestProvider.notifier).request();
    await run.settle();
    expect(run.connector.dials, connectionMaxAttempts * 2);
  });

  test('nothing dials until it is asked', () async {
    final run = await _Run.start([_unreachable()], dial: false);

    expect(run.connector.dials, 0);
    expect(run.status, isA<Disconnected>());
  });

  test('a successful dial is verified against the daemon, not just opened', () async {
    final run = await _Run.start([null]);

    expect(run.seen.whereType<Connecting>().map((c) => c.stage), [
      ConnectStage.dialling,
      ConnectStage.verifying,
    ]);
    expect(run.seen.whereType<Online>().single.hello.version, '0.9.0');
  });
}

/// One test's container, its scripted connector and everything it published.
class _Run {
  _Run._(this.container, this.connector, this.seen);

  final ProviderContainer container;
  final ScriptedConnector connector;
  final List<ConnectionStatus> seen;

  ConnectionStatus? get status => container.read(connectionProvider).value;

  /// Starts a container, subscribes, and waits for the dial to finish.
  static Future<_Run> start(
    List<HerdrTransportException?> script, {
    bool dial = true,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (dial) 'flutter.settings.autoConnect': true,
    });
    final prefs = await SharedPreferences.getInstance();

    final connector = ScriptedConnector(script);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        hostConnectorProvider.overrideWithValue(connector),
        // The waiting is the part under test elsewhere; here it only costs
        // seconds.
        connectionRetryDelayProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(container.dispose);

    final seen = <ConnectionStatus>[];
    container.listen(
      connectionProvider,
      (_, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      },
      fireImmediately: true,
    );

    final run = _Run._(container, connector, seen);
    await run.settle();
    return run;
  }

  /// Waits for the dial to reach a terminal state.
  ///
  /// Polling rather than awaiting `connectionProvider.future`: that future
  /// resolves with the first non-loading value, which during a retry is a
  /// [Connecting].
  Future<void> settle() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final value = container.read(connectionProvider);
      if (!value.isLoading &&
          (value.value is Online ||
              value.value is ConnectionFailed ||
              value.value is Disconnected)) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('the dial never settled: $value');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }
}

/// A connector that plays a scripted list of outcomes.
///
/// `null` in the list means "this dial works"; an error means it fails that
/// way. Running past the end keeps failing the same way, so a loop that never
/// stops is caught by the try count rather than by an index error.
class ScriptedConnector extends HostConnector {
  ScriptedConnector(this.script)
      : super(
          credentialsFor: (_) async => const SshSecrets(password: 'x'),
          verifyHostKey: (_) async => HostKeyVerdict.trust,
        );

  final List<HerdrTransportException?> script;
  int dials = 0;

  @override
  Future<({HerdrClientBundle bundle, String socketPath})> connect(
    HostProfile profile,
  ) async {
    final step = dials < script.length ? script[dials] : script.last;
    dials++;
    if (step != null) throw step;

    const path = '/home/dev/.config/herdr/herdr.sock';
    return (
      bundle: HerdrClientBundle(transport: _PingingTransport(), socketPath: path),
      socketPath: path,
    );
  }
}

/// A transport that answers the one call a dial makes.
class _PingingTransport implements HerdrTransport {
  @override
  Future<String> roundTrip(String requestLine) async =>
      '{"id":"1","result":{"version":"0.9.0","protocol":22}}';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}

HerdrTransportException _unreachable() =>
    HerdrTransportException(TransportFailure.connectFailed, 'no route to host');
