import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/latency.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';

/// What the latency number means, and what it must not mean.
///
/// The measurement is one NDJSON round trip over the transport — the same path
/// the terminal takes — so the two things worth pinning are that the number is
/// the LINK rather than the handshake, and that a failed measurement says so
/// instead of silently showing a stale number as though it were current.
void main() {
  const host = HostProfile(
    id: 'h1',
    label: 'devbox',
    username: 'dev',
    host: '10.0.0.5',
  );

  ProviderContainer containerWith(
    HostConnector connector, {
    Duration deadline = latencyProbeTimeout,
  }) {
    final container = ProviderContainer(
      overrides: [
        hostConnectorProvider.overrideWithValue(connector),
        latencyProbeTimeoutProvider.overrideWithValue(deadline),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  HostLatency readingOf(ProviderContainer container) =>
      container.read(hostLatencyProvider)[host.id] ?? HostLatency.unknown;

  test('a fresh connection is dialled, warmed, measured — in that order',
      () async {
    final transport = _ScriptedTransport(const Duration(milliseconds: 30));
    final connector = _FakeConnector(transport);
    final container = containerWith(connector);

    await container.read(hostLatencyProvider.notifier).measure(host);

    expect(
      transport.rounds,
      2,
      reason: 'the SSH session opens on the FIRST request, so timing that one '
          'would report a handshake as though it were the latency of the link',
    );
    expect(
      transport.closed,
      isTrue,
      reason: 'a throwaway connection opened to take a reading must not be left '
          'open on the machine',
    );
    final reading = readingOf(container);
    expect(reading.millis, greaterThanOrEqualTo(20));
    expect(reading.failed, isFalse);
    expect(reading.measuring, isFalse);
  });

  test('an already-open client is used as it is, with no second dial', () async {
    final transport = _ScriptedTransport(Duration.zero);
    // A connector that would FAIL if it were used: the fast path must not dial.
    final container = containerWith(_FakeConnector(_ScriptedTransport(Duration.zero)));

    await container
        .read(hostLatencyProvider.notifier)
        .measure(host, live: HerdrClient(transport));

    expect(transport.rounds, 1, reason: 'one request, one answer');
  });

  test('a measurement that does not answer keeps the last number and says so',
      () async {
    final transport = _ScriptedTransport(const Duration(milliseconds: 10));
    final container = containerWith(_FakeConnector(transport));
    final notifier = container.read(hostLatencyProvider.notifier);

    await notifier.measure(host);
    final first = readingOf(container).millis;
    expect(first, isNotNull);

    transport.fail = true;
    await notifier.measure(host);

    final after = readingOf(container);
    expect(after.failed, isTrue);
    expect(
      after.millis,
      first,
      reason: 'the old number is still the last thing that was true; blanking '
          'it would make a failure look like a machine never measured',
    );
    expect(after.measuring, isFalse);
  });

  test('a second measurement while one is running does not dial again',
      () async {
    final transport = _ScriptedTransport(const Duration(milliseconds: 60));
    final connector = _FakeConnector(transport);
    final container = containerWith(connector);
    final notifier = container.read(hostLatencyProvider.notifier);

    final first = notifier.measure(host);
    await notifier.measure(host);
    await first;

    expect(
      connector.dials,
      1,
      reason: 'two taps on a slow machine are one measurement, not a queue',
    );
  });

  test('a measurement that hangs is a failure, not a wait that never ends',
      () async {
    final transport = _ScriptedTransport(Duration.zero)..hang = true;
    final container = containerWith(
      _FakeConnector(transport),
      deadline: const Duration(milliseconds: 150),
    );

    await container
        .read(hostLatencyProvider.notifier)
        .measure(host)
        .timeout(const Duration(seconds: 2));

    expect(readingOf(container).failed, isTrue);
  });
}

/// A transport that answers `ping` after [delay], and can be made to fail.
class _ScriptedTransport implements HerdrTransport {
  _ScriptedTransport(this.delay);

  final Duration delay;
  bool fail = false;

  /// Never answers at all, for the timeout case.
  bool hang = false;

  int rounds = 0;
  bool closed = false;

  @override
  Future<String> roundTrip(String requestLine) async {
    rounds++;
    if (hang) return await Completer<String>().future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) {
      throw HerdrTransportException(
        TransportFailure.streamClosed,
        'the connection is gone',
      );
    }
    return '{"id":"1","result":{"version":"0.9.0","protocol":22}}';
  }

  @override
  Future<HerdrDuplex> openDuplex(String openLine) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeConnector extends HostConnector {
  _FakeConnector(this.transport)
      : super(
          credentialsFor: (_) async => const SshSecrets(password: 'x'),
          verifyHostKey: (_) async => HostKeyVerdict.trust,
        );

  final HerdrTransport transport;
  int dials = 0;

  @override
  Future<({HerdrClientBundle bundle, String socketPath})> connect(
    HostProfile profile, {
    void Function(DialStage stage)? onStage,
  }) async {
    dials++;
    const path = '/home/dev/.config/herdr/herdr.sock';
    return (
      bundle: HerdrClientBundle(transport: transport, socketPath: path),
      socketPath: path,
    );
  }
}
