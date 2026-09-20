import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WHAT HAPPENS AFTER THE CONNECTION DIES.
///
/// Reported from the phone, after an hour on a virtual overlay network: "the
/// SSH connection dropped, and it never reconnected — I had to go to the
/// machine. It looked connected the whole time." It did: nothing watched the
/// live transport, so the status stayed `Online` with a green dot while every
/// request on the corpse failed — one at a time, each with whatever message the
/// caller happened to produce.
///
/// So the two properties asserted here are the two that were missing:
///
///   1. A connection that dies is NOTICED, and it is noticed from the
///      transport's own end (`ConnectionLiveness.lost`), not from a request
///      that happens to fail.
///   2. It is re-dialled by itself, repeatedly enough to survive a machine that
///      is asleep or an overlay path that is re-establishing — and then it
///      STOPS, because an app that dials forever is an app that flattens a
///      battery on a train.
void main() {
  test('a connection that dies is re-dialled without being asked', () async {
    final run = await _Run.start();
    expect(run.status, isA<Online>());
    expect(run.connector.dials, 1);

    run.transport!.die();
    await run.breathe();

    expect(
      run.connector.dials,
      2,
      reason: 'the loss itself is the trigger: no request failed, and nobody '
          'tapped anything',
    );
    expect(run.status, isA<Online>());
    expect(
      run.transport,
      isNot(same(run.connector.transports.first)),
      reason: 'recovery is a NEW session, not the dead one reused',
    );
  });

  test('a recovery says the connection is gone, not that it is connecting',
      () async {
    // The wording is the whole difference for the user: "Connecting…" over a
    // board they were reading a minute ago reads as if the app had restarted,
    // and says nothing about why the board underneath it is stale.
    final run = await _Run.start();
    run.transport!.die();
    await run.breathe();

    // The dials BEFORE the loss were the app connecting for the first time;
    // everything after the first `Online` is a recovery.
    final afterFirstOnline = run.seen
        .skipWhile((s) => s is! Online)
        .whereType<Connecting>()
        .toList();
    expect(afterFirstOnline, isNotEmpty);
    expect(
      afterFirstOnline.every((c) => c.afterLoss),
      isTrue,
      reason: 'nothing in a recovery is narrated as a first connect',
    );
  });

  test('a recovery that cannot dial keeps trying, then stops', () async {
    final run = await _Run.start(failAfterFirst: true);
    run.transport!.die();
    await run.breathe(turns: 400);

    // One immediate round of the ordinary ladder, then the slow rounds.
    expect(
      run.connector.dials,
      1 + connectionMaxAttempts * (1 + connectionSlowRounds),
      reason: 'the immediate round and every slow round, each a full ladder',
    );

    final status = run.status;
    expect(status, isA<ConnectionFailed>());
    final failure = status! as ConnectionFailed;
    expect(failure.afterLoss, isTrue);
    expect(
      failure.willRetry,
      isFalse,
      reason: 'the last round must not promise another one',
    );
    expect(
      run.seen.whereType<ConnectionFailed>().last.willRetry,
      isFalse,
      reason: 'and the line the user is left looking at has to say so',
    );
  });

  test('a recovery in progress says another attempt is coming', () async {
    final run = await _Run.start(failAfterFirst: true);
    run.transport!.die();
    await run.breathe(turns: 40);

    final failures = run.seen.whereType<ConnectionFailed>().toList();
    expect(failures, isNotEmpty);
    expect(
      failures.first.afterLoss,
      isTrue,
      reason: 'this is the end of a link that was up, not a first dial',
    );
    expect(
      failures.map((f) => f.willRetry),
      contains(true),
      reason: 'while a slow round is queued the user is owed that fact',
    );
  });

  test('a connection that was never up is not narrated as a loss', () async {
    // The counter-case, and the reason `afterLoss` is carried on the state
    // instead of being guessed from `attempts`: a machine that never answered
    // has not "disconnected" from anything.
    final run = await _Run.start(failAlways: true);

    expect(run.status, isA<ConnectionFailed>());
    final failure = run.status! as ConnectionFailed;
    expect(failure.afterLoss, isFalse);
    expect(failure.willRetry, isFalse);
    expect(
      run.seen.whereType<Connecting>().every((c) => !c.afterLoss),
      isTrue,
    );
    expect(
      run.connector.dials,
      connectionMaxAttempts,
      reason: 'a first dial still gets the ordinary ladder, and no slow rounds',
    );
  });

  group('what a dead link is called', () {
    test('a command that merely CONTAINS the sentinel is not a missing herdr',
        () {
      // The real shape of the false diagnosis. The terminal command is built
      // from `herdrCommandPrefix`, which embeds the sentinel, and a failure to
      // start it used to quote the command in full — so every dropped
      // connection reported "herdr is not installed on this machine".
      const command = r'HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr"); '
          r'[ -x "$HERDR" ] || { echo __HERDR_NOT_INSTALLED__ >&2; exit 127; }; '
          r'exec "$HERDR" terminal session control w9:p1';
      final dead = HerdrTransportException(
        TransportFailure.unknown,
        'could not start the remote command ($command): connection closed',
      );

      expect(reportsHerdrMissing(dead.message), isFalse);
      expect(
        ConnectionFailed(dead).isHerdrMissing,
        isFalse,
        reason: 'a dropped connection is not a missing binary',
      );
      expect(
        isWorthRetrying(dead),
        isTrue,
        reason: 'and it is worth retrying, which the substring match also broke',
      );
    });

    test('the sentinel alone on its line is a missing herdr', () {
      const real = 'bash: herdr: command not found\n__HERDR_NOT_INSTALLED__\n';
      expect(reportsHerdrMissing(real), isTrue);
      expect(
        ConnectionFailed(
          HerdrTransportException(TransportFailure.connectFailed, real),
        ).isHerdrMissing,
        isTrue,
      );
      expect(
        isWorthRetrying(
          HerdrTransportException(TransportFailure.connectFailed, real),
        ),
        isFalse,
        reason: 'the command already ran on the other side and answered',
      );
    });

    test('a long command is shortened rather than quoted whole', () {
      final long = 'x' * 400;
      final short = shortCommand(long);
      expect(short.length, lessThan(long.length));
      expect(short, endsWith('…'));
      expect(shortCommand('ls -la'), 'ls -la');
      expect(
        shortCommand('echo one\necho two'),
        'echo one echo two',
        reason: 'an error message is one line',
      );
    });
  });
}

/// One test's container, its scripted connector, and what it published.
class _Run {
  _Run._(this.container, this.connector, this.seen);

  final ProviderContainer container;
  final _ScriptedConnector connector;
  final List<ConnectionStatus> seen;

  ConnectionStatus? get status => container.read(connectionProvider).value;

  /// The transport of the connection that is live right now.
  _FakeTransport? get transport =>
      connector.transports.isEmpty ? null : connector.transports.last;

  static Future<_Run> start({
    bool failAfterFirst = false,
    bool failAlways = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.settings.autoConnect': true,
    });
    final prefs = await SharedPreferences.getInstance();

    final connector = _ScriptedConnector(
      failAfterFirst: failAfterFirst,
      failAlways: failAlways,
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The two waits are the part under test elsewhere; here they only cost
        // seconds. Both are overridden for the same reason: `flutter test`
        // cannot wait two minutes for the slow rounds.
        connectionRetryDelayProvider.overrideWithValue(Duration.zero),
        connectionSlowRetryDelayProvider.overrideWithValue(
          const Duration(milliseconds: 2),
        ),
        hostConnectorProvider.overrideWithValue(connector),
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
    await run.breathe();
    return run;
  }

  /// Lets the timers and futures of a recovery run, without real waiting.
  Future<void> breathe({int turns = 40}) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }
}

/// A connector whose dials succeed when they are allowed to.
class _ScriptedConnector extends HostConnector {
  _ScriptedConnector({this.failAlways = false, this.failAfterFirst = false})
      : super(
          credentialsFor: (_) async => const SshSecrets(password: 'x'),
          verifyHostKey: (_) async => HostKeyVerdict.trust,
        );

  /// Every dial fails.
  final bool failAlways;

  /// The first dial works; everything after it fails.
  final bool failAfterFirst;

  final List<_FakeTransport> transports = [];

  int get dials => _dials;
  int _dials = 0;

  @override
  Future<({HerdrClientBundle bundle, String socketPath})> connect(
    HostProfile profile, {
    void Function(DialStage stage)? onStage,
  }) async {
    final index = _dials++;
    if (failAlways || (failAfterFirst && index > 0)) {
      throw HerdrTransportException(
        TransportFailure.connectFailed,
        'no route to host',
      );
    }

    // The same last stage the real connector reports once the transport is up:
    // what is left to prove is that the daemon answers.
    onStage?.call(DialStage.verifying);

    const path = '/home/dev/.config/herdr/herdr.sock';
    final transport = _FakeTransport();
    transports.add(transport);
    return (
      bundle: HerdrClientBundle(transport: transport, socketPath: path),
      socketPath: path,
    );
  }
}

/// A transport that holds one session, answers a ping, and can be killed.
class _FakeTransport implements HerdrTransport, ConnectionLiveness {
  final Completer<void> _lost = Completer<void>();
  bool _alive = true;

  /// Ends the session the way a real one ends: on its own, with the app
  /// finding out from the transport rather than from a failed request.
  void die() {
    if (!_alive) return;
    _alive = false;
    _lost.complete();
  }

  @override
  bool get isAlive => _alive;

  @override
  Future<void> get lost => _lost.future;

  @override
  Future<String> roundTrip(String requestLine) async {
    if (!_alive) {
      throw HerdrTransportException(
        TransportFailure.streamClosed,
        'the SSH connection is gone',
      );
    }
    return '{"id":"1","result":{"version":"0.9.0","protocol":22}}';
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  /// A deliberate close, which by contract is NOT a loss.
  @override
  Future<void> close() async {
    _alive = false;
  }
}
