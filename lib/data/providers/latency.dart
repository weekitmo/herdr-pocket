import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';

/// What the app knows about one machine's round-trip time.
///
/// ONE MACHINE, ONE READING, and the three fields are not a state machine: a
/// measurement can be in flight while the previous answer is still on screen,
/// and a failed one keeps that answer. Blanking the number when a test fails
/// would make "this machine is unreachable right now" look like "this machine
/// has never been measured", which is a different and much less useful sentence.
class HostLatency {
  const HostLatency({this.millis, this.measuring = false, this.failed = false});

  /// The last successful measurement, in milliseconds.
  ///
  /// Null means nobody has measured this machine yet — never zero, which would
  /// be a claim about a machine that has not answered.
  final int? millis;

  /// True while a measurement is in flight.
  final bool measuring;

  /// True when the LAST attempt did not get an answer.
  final bool failed;

  /// Nothing has been measured, and nothing is being measured.
  static const HostLatency unknown = HostLatency();

  HostLatency copyWith({int? millis, bool? measuring, bool? failed}) =>
      HostLatency(
        millis: millis ?? this.millis,
        measuring: measuring ?? this.measuring,
        failed: failed ?? this.failed,
      );
}

/// How long one measurement may take before it is called a failure.
///
/// Ten seconds, because this is a measurement and not a dial: a number that
/// takes longer than that to arrive is not a latency, it is an outage — and
/// leaving the row spinning forever would be the app refusing to admit it.
const Duration latencyProbeTimeout = Duration(seconds: 10);

/// The deadline above, as a provider so a test need not spend twenty seconds
/// watching a stopwatch. Same shape as the connection's own retry delays.
final latencyProbeTimeoutProvider = Provider<Duration>(
  (ref) => latencyProbeTimeout,
);

/// The last measurement per machine, and the ability to take another one.
///
/// ## Session-scoped, deliberately
///
/// Held in memory and NOT written to disk. A latency number is a fact about the
/// network the phone is on right now — a café's Wi-Fi, a train, a hotel — and a
/// stored one would be re-shown on the next launch as though it still described
/// this morning's connection. A number with no date on it is worse than no
/// number, so the reading lives as long as the process and the machine is
/// measured again when it is needed.
///
/// ## What is measured, and why not an ICMP ping
///
/// The number is ONE `ping` REQUEST OVER THE TRANSPORT — the same NDJSON round
/// trip every other part of the app makes, over the same SSH connection the
/// terminal uses. That is the only latency the user can act on: it includes
/// everything between this phone and the daemon (the radio, the overlay network,
/// the SSH channel, the agent's own CPU) rather than the subset an ICMP echo
/// would see, and ICMP is not something a phone can count on over an SSH
/// tunnel in any case.
class HostLatencyNotifier extends Notifier<Map<String, HostLatency>> {
  @override
  Map<String, HostLatency> build() => const {};

  /// Measures [host], once at a time.
  ///
  /// [live] is the already-open client when the caller has one. Passed in rather
  /// than looked up, because the caller that has it — the dial, on its way to
  /// `Online` — is still inside its own build and must not read this provider's
  /// dependencies back out of Riverpod.
  Future<void> measure(HostProfile host, {HerdrClient? live}) async {
    if (state[host.id]?.measuring ?? false) return;
    // READ BEFORE ANY AWAIT. Everything this method needs from Riverpod is
    // taken now, while the provider is certainly alive: a measurement is a
    // network round trip, and the app can be closed — or the container
    // disposed, which is what a test does — while it is in flight. Touching
    // `ref` after that is an error, not a race worth tolerating.
    final deadline = ref.read(latencyProbeTimeoutProvider);
    final connector = live == null ? ref.read(hostConnectorProvider) : null;

    _write(host.id, (current) => current.copyWith(measuring: true, failed: false));

    try {
      final millis = await _roundTrip(
        host,
        live: live,
        connector: connector,
        deadline: deadline,
      );
      _write(host.id, (_) => HostLatency(millis: millis));
    } on Object {
      _write(
        host.id,
        (current) => current.copyWith(measuring: false, failed: true),
      );
    }
  }

  /// One round trip to [host], in milliseconds.
  Future<int> _roundTrip(
    HostProfile host, {
    required HerdrClient? live,
    required HostConnector? connector,
    required Duration deadline,
  }) async {
    if (live != null) return await _time(live.ping, deadline);

    final opened = await connector!.connect(host);
    final client = HerdrClient(opened.bundle.transport);
    try {
      // TWO REQUESTS, AND ONLY THE SECOND ONE COUNTS. The SSH session is opened
      // lazily by the first request, so timing that one would report a
      // handshake and a key exchange as though they were the latency of the
      // link — hundreds of milliseconds for a machine that answers in ten.
      //
      // The warm-up carries a deadline of its own: a machine that never answers
      // this one would otherwise hang here instead of failing, which is the
      // difference between a row that says "no answer" and a row that spins
      // forever.
      await client.ping().timeout(deadline);
      return await _time(client.ping, deadline);
    } finally {
      await client.close();
    }
  }

  Future<int> _time(Future<void> Function() request, Duration deadline) async {
    final clock = Stopwatch()..start();
    await request().timeout(deadline);
    clock.stop();
    return clock.elapsedMilliseconds;
  }

  void _write(String hostId, HostLatency Function(HostLatency) update) {
    // A MEASUREMENT CAN OUTLIVE THE APP IT WAS TAKEN FOR — the container is
    // disposed while the round trip is still in flight, which is exactly what
    // happens at the end of an integration test and what happens on a phone
    // when the process is killed. The reading is dropped rather than published;
    // there is nobody left to read it.
    if (!ref.mounted) return;
    state = {
      ...state,
      hostId: update(state[hostId] ?? HostLatency.unknown),
    };
  }
}

/// The readings, keyed by machine id.
final hostLatencyProvider =
    NotifierProvider<HostLatencyNotifier, Map<String, HostLatency>>(
  HostLatencyNotifier.new,
);

/// The reading for the machine the app is pointed at, if there is one.
///
/// A separate provider so a row does not rebuild the whole list when one
/// machine's number changes — and so a screen can ask the question without
/// knowing how the map is keyed.
final currentHostLatencyProvider = Provider<HostLatency>((ref) {
  final id = ref.watch(currentHostProvider)?.id;
  if (id == null) return HostLatency.unknown;
  return ref.watch(hostLatencyProvider)[id] ?? HostLatency.unknown;
});
