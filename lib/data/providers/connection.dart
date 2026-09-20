import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/app_lifecycle.dart';
import 'package:herdr_pocket/data/board_sync.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/notifications/agent_notifier.dart';
import 'package:herdr_pocket/data/notifications/attention_tracker.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';

/// How the connection to the current host is going.
///
/// A sealed type rather than a bool + nullable error, because the UI needs to
/// say four different things ("connecting", "online", "this machine has no
/// herdr", "your key changed") and the difference between them is the whole
/// value of showing a status at all.
sealed class ConnectionStatus {
  const ConnectionStatus();
}

class Disconnected extends ConnectionStatus {
  const Disconnected();
}

/// How far one dial has got.
///
/// WAS TWO STAGES, and the two are still the ones that matter — the failures
/// they produce are different sentences:
///
///  * "your phone cannot reach that machine" — nothing ever opened;
///  * "the machine answered but herdr did not" — the transport is up.
///
/// What changed is that the stages in between are now REAL rather than implied:
/// the enum lives in the transport layer ([DialStage]) because only the dialler
/// knows when the socket is up, when the host key is being asked about, and
/// when the daemon is being probed. This alias keeps the name the connection's
/// own API has always used, so nothing above it had to be renamed to gain the
/// finer narration.
typedef ConnectStage = DialStage;

/// A dial in flight, and how many have already failed.
///
/// [attempt] is 1-based and counts TRIES, not retries: attempt 1 is the one the
/// user asked for, and attempt `connectionMaxAttempts` is the last one there
/// will be. The UI narrates from this rather than from a separate progress
/// channel, so what the user reads and what the dialler is doing cannot drift.
class Connecting extends ConnectionStatus {
  const Connecting({
    this.attempt = 1,
    this.stage = ConnectStage.dialling,
    this.afterLoss = false,
  });

  final int attempt;
  final ConnectStage stage;

  /// True when this dial is a RECOVERY: the connection was up and then died,
  /// and nobody asked for this attempt.
  ///
  /// It exists for the wording and nothing else, but the wording matters here.
  /// "Connecting" is the right sentence for a machine that never answered a
  /// first dial, and the wrong one for a link that dropped while the user was
  /// in another app: that case has to say the connection is GONE, because the
  /// user is looking at a screen that was working a minute ago and the app is
  /// the only thing that knows what changed.
  final bool afterLoss;

  /// True for every try after the first — what the user would call "retrying".
  bool get isRetry => attempt > 1;

  /// True on the final try, which gets its own wording: "retrying" is a
  /// promise that there is another one coming, and on the last try there is
  /// not.
  bool get isLastAttempt => attempt >= connectionMaxAttempts;
}

class Online extends ConnectionStatus {
  const Online({required this.client, required this.hello, required this.socketPath});

  final HerdrClient client;
  final HerdrHello hello;
  final String socketPath;

  String get label => 'herdr ${hello.version}';
}

class ConnectionFailed extends ConnectionStatus {
  const ConnectionFailed(
    this.error, {
    this.attempts = 1,
    this.afterLoss = false,
    this.willRetry = false,
  });

  final Object error;

  /// How many dials were spent before giving up. One means "this was never
  /// worth retrying"; more means time was spent trying.
  final int attempts;

  /// True when this failure is the end of a connection that HAD been working.
  ///
  /// The distinction the status line needs: "cannot reach this machine" is
  /// about the first dial, and "the connection dropped and would not come back"
  /// is about a link the user was using — which is worth saying, because it
  /// explains the stale board underneath it.
  final bool afterLoss;

  /// True when another attempt is already scheduled.
  ///
  /// Carried on the state rather than derived from [attempts], because the two
  /// are different facts: `attempts` is what this run spent, and this is
  /// whether the app has not given up yet. The user is owed the difference —
  /// "it is still trying" and "it is not coming back on its own" are opposite
  /// instructions about whether to wait.
  final bool willRetry;

  /// True when we reached the machine but found no daemon on it.
  ///
  /// Two shapes, because the two transports fail differently: the SSH path
  /// reports our own sentinel from the command wrapper, and the local path
  /// reports a socket that is not there. Both mean "herdr is not running here",
  /// which is the one failure the user can actually act on — so it deserves
  /// real guidance rather than a generic apology.
  ///
  /// The sentinel is matched as a LINE and never as a substring: it is a
  /// constant this app builds its own commands out of, so a failure message
  /// that quotes one of those commands contains it. That is exactly how a
  /// dropped SSH link reported "herdr is not installed" — see
  /// [reportsHerdrMissing].
  bool get isHerdrMissing {
    final e = error;
    if (e is! HerdrTransportException) return false;
    if (e.failure != TransportFailure.connectFailed) return false;
    return reportsHerdrMissing(e.message) ||
        e.message.contains('no herdr socket');
  }

  bool get isForwardingRefused =>
      error is HerdrTransportException &&
      (error as HerdrTransportException).failure ==
          TransportFailure.forwardingRefused;

  bool get isSecurityRelevant =>
      error is HerdrTransportException &&
      (error as HerdrTransportException).isSecurityRelevant;
}

/// How many times one request may dial before it gives up.
///
/// THREE, and it is a ceiling rather than a comfort setting. A dial has a
/// 15-second timeout, so three tries is already most of a minute of a user's
/// attention; a phone that can reach the machine at all almost always reaches
/// it on the second try (the first after a network switch is the one that
/// fails), and a phone that cannot reach it is not going to start on the
/// tenth.
const int connectionMaxAttempts = 3;

/// How long to wait before dialling again.
///
/// Short, and deliberately shorter than any exponential ladder would start:
/// the failures worth retrying here are a sleeping radio or a dropped Wi-Fi
/// handover, and both are fixed by the time it takes the user to notice the
/// spinner. A long backoff would turn "the network hiccuped" into "the app is
/// broken".
const Duration connectionRetryDelay = Duration(milliseconds: 1200);

/// The delay between dials, as a provider so tests need not wait in real time.
final connectionRetryDelayProvider = Provider<Duration>(
  (ref) => connectionRetryDelay,
);

/// How many extra rounds a connection that WAS up gets after it dies.
///
/// The first round is immediate — a link that dropped because the radio blinked
/// is back by the time the user notices. These are the slow ones, for the case
/// that actually prompted them: the machine is asleep, or the overlay network
/// that carries the connection is re-establishing a path, and neither is fixed
/// in fifteen seconds. Four rounds at half a minute is two minutes of the app
/// quietly getting itself back, which is roughly as long as anyone waits before
/// they decide it is broken — and then the retry is one tap away and the status
/// line already says the connection is gone.
const int connectionSlowRounds = 4;

/// How long between those rounds.
const Duration connectionSlowRetryDelay = Duration(seconds: 30);

/// The slow-round delay, as a provider so tests need not wait in real time.
final connectionSlowRetryDelayProvider = Provider<Duration>(
  (ref) => connectionSlowRetryDelay,
);

/// How long a resume-time health check may take before the link is presumed
/// gone.
///
/// Short on purpose. This one runs when the user has just looked at the screen
/// and wants the board: a check that takes as long as a dial is worse than
/// dialling again, because the answer is only useful if it arrives before the
/// user's next tap.
const Duration resumeHealthCheckTimeout = Duration(seconds: 4);

/// Builds the connector a dial uses.
///
/// A provider rather than a literal inside [ConnectionNotifier.build], so the
/// retry loop can be exercised end to end by a test that scripts the dials —
/// which is the only way to assert "three tries, then it stops" against the
/// real code path rather than against a re-implementation of it.
final hostConnectorProvider = Provider<HostConnector>(
  (ref) => HostConnector(
    // Secrets come from the keystore at connect time and are never held on
    // the profile, so a profile stays safe to log or export.
    credentialsFor: (profile) =>
        ref.read(hostSecretsStoreProvider).read(profile.id),
    // Trust on first use, with the changed-key case kept visibly distinct
    // from the unknown-host one.
    verifyHostKey: (prompt) => verifyHostKeyWithStores(ref, prompt),
  ),
);

/// Whether dialling again could plausibly change the answer.
///
/// THIS IS THE WHOLE POINT OF RETRYING, and getting it wrong is worse than not
/// retrying at all. A dial that failed because the phone had no signal is
/// worth repeating — the second try is the one that works. A dial that failed
/// because the password is wrong, or because the machine's key is not the one
/// the user approved, will fail identically three times; all three retries
/// achieve is thirty seconds of spinner before the same sentence, and the user
/// standing there unable to tell whether the app is working on it.
bool isWorthRetrying(Object error) {
  if (error is! HerdrTransportException) return false;

  // Reaching the machine and finding no herdr is the most specific failure
  // this app has, and the one where a retry is provably pointless: the
  // command already ran on the other side and reported its answer.
  if (reportsHerdrMissing(error.message)) return false;

  return switch (error.failure) {
    // The case this exists for: no route, refused, radio asleep.
    TransportFailure.connectFailed => true,
    TransportFailure.timeout => true,
    TransportFailure.streamClosed => true,
    // The catch-all. Retried because a `SocketException` from the SSH library
    // usually lands here, and a dropped packet is exactly what a second try
    // fixes.
    TransportFailure.unknown => true,
    // A credential the user has to change.
    TransportFailure.authenticationFailed => false,
    // A question waiting for a human, not for time. Retrying would re-raise
    // the same sheet — or, worse, answer it twice.
    TransportFailure.hostKeyUnknown => false,
    TransportFailure.hostKeyChanged => false,
    // A server setting. Deterministic until someone edits sshd_config.
    TransportFailure.forwardingRefused => false,
    // Also a server setting, and equally deterministic. It is the file
    // transfer's `AllowStreamLocalForwarding` — a separate case from the one
    // above because the two are fixed by different lines in different files, so
    // a retry is pointless for both but the guidance they produce is not the
    // same guidance.
    TransportFailure.sftpUnavailable => false,
  };
}

/// Owns the live connection to the daemon.
///
/// Deliberately an AsyncNotifier rather than a StreamProvider: connecting is a
/// one-shot operation with a rich outcome, and the interesting states are
/// "connecting", "online with these capabilities" and "failed for this
/// specific reason" — none of which a bare `AsyncValue<Client>` expresses.
class ConnectionNotifier extends AsyncNotifier<ConnectionStatus> {
  /// The client this notifier opened, if it has one.
  ///
  /// HELD AS A FIELD RATHER THAN READ BACK OFF `state`, because `onDispose` is
  /// one of the places Riverpod forbids touching `Ref` or `state` — "Cannot use
  /// Ref or modify other providers inside life-cycles/selectors" — and the
  /// first version of this did exactly that. It never fired while the app ran,
  /// because the provider outlives every screen; it fired the moment a test
  /// disposed its container, which is the only cheap way to prove the socket
  /// gets closed at all.
  HerdrClient? _live;

  /// Which run of [build] owns the screen.
  ///
  /// A REBUILD DOES NOT UNDO A DIAL THAT IS ALREADY IN FLIGHT. Dart cannot
  /// cancel a future, so invalidating this provider starts a second run and
  /// leaves the first one somewhere inside `connect()` — and that abandoned run
  /// still holds a reference to `state` and still intends to publish
  /// "connecting, try 2 of 3" when its dial fails. The user sees the retry
  /// banner for a machine they just deleted, which is the bug this field exists
  /// for: a run may only publish while it is still the current one.
  int _generation = 0;

  /// True when the run of [build] that is dialling now is RECOVERING a link
  /// that died, rather than answering a request.
  ///
  /// Set by the loss watcher just before it asks for another dial, consumed at
  /// the top of the next run, and used for the status wording alone. It has to
  /// live here rather than on the request counter, because the counter is a
  /// number the user and the network both bump and there is no version of it
  /// that says why.
  bool _afterLoss = false;

  /// Rounds of slow retries already spent on the current outage.
  int _slowRounds = 0;

  Timer? _slowRetry;

  AppResumeWatcher? _resumeWatcher;

  @override
  Future<ConnectionStatus> build() async {
    final generation = ++_generation;
    final host = ref.watch(currentHostProvider);
    if (host == null) return const Disconnected();

    // Nothing dials until the user asks. See [ConnectRequestNotifier] and
    // `SettingsState.autoConnect` — the default is "wait", and a build that
    // opens a network connection the user did not request is the bug this
    // guard exists to prevent.
    final auto = ref.watch(settingsProvider.select((s) => s.autoConnect));
    final requested = ref.watch(connectRequestProvider) > 0;
    if (!auto && !requested) return const Disconnected();

    ref.onDispose(() {
      final client = _live;
      _live = null;
      if (client != null) unawaited(client.close());
      // A pending slow round belongs to the run that scheduled it. Without
      // this, deleting a machine and re-adding it would be racing a timer that
      // still wants to dial the old one.
      _slowRetry?.cancel();
      _slowRetry = null;
      _resumeWatcher?.stop();
      _resumeWatcher = null;
    });

    // The app coming back to the foreground is the one moment the OS may have
    // silently taken the link away — see [AppResumeWatcher]. Installed for the
    // life of this run, and only for a run that is dialling something.
    _resumeWatcher?.stop();
    _resumeWatcher = AppResumeWatcher(() => _healthCheck(host, generation))..start();

    final status = await _dialUntilAnswered(host, generation);
    if (status is Online) {
      // The link is up: bank the round counter and start watching it for its
      // own end.
      _slowRounds = 0;
      _watchForLoss(status.client, host, generation);
    }
    return status;
  }

  /// Watches a live session for its own end, and recovers from it.
  ///
  /// THIS IS THE BUG THE USER REPORTED. The app used to find out that a link
  /// had died only when a request on it failed one at a time, and each failure
  /// was narrated by whatever code happened to be awaiting it — so a dead
  /// connection looked like a missing binary, a missing file, or an 8 KB shell
  /// script on the screen. Nothing re-dialled, and the status stayed `Online`
  /// with a green dot, because nothing had told it otherwise.
  void _watchForLoss(HerdrClient client, HostProfile host, int generation) {
    // Widened to `Object` on purpose: Dart does not promote across two
    // unrelated interfaces, and this is the same two-step the command runner
    // uses — see `_runnerOf` in `remote_fs.dart`.
    final Object transport = client.transport;
    // Not every transport can answer: the local socket opens one connection per
    // request and finds out at the call. See [ConnectionLiveness].
    if (transport is! ConnectionLiveness) return;
    unawaited(
      transport.lost.then((_) => _recover(host, generation)),
    );
  }

  /// Re-dials after a loss, if this run is still the one that owns the screen.
  void _recover(HostProfile host, int generation) {
    if (!ref.mounted || generation != _generation) return;
    if (!_stillWanted(host)) return;
    _afterLoss = true;
    ref.read(connectRequestProvider.notifier).request();
  }

  /// Checks that a connection the OS may have frozen is still usable.
  ///
  /// A FROZEN PROCESS IS NOT A CLOSED SOCKET. When the app goes to the
  /// background the OS can stop the isolate without the kernel noticing
  /// anything; the keepalive stops being written, the far end (or the NAT, or
  /// the overlay network in between) drops the flow, and this side is never
  /// told. So "the client says it is open" is not evidence. One round trip with
  /// a deadline is.
  ///
  /// A failed check re-dials through the ordinary path, which means the user
  /// sees the same "recovering" narration a dropped link produces.
  void _healthCheck(HostProfile host, int generation) {
    if (generation != _generation || !ref.mounted) return;
    final client = _live;
    if (client == null) return;

    unawaited(() async {
      try {
        await client.ping().timeout(resumeHealthCheckTimeout);
        return;
      } on Object {
        // A ping that fails or does not come back in time is the answer we
        // needed: whatever the socket claims, this connection is not carrying
        // traffic.
      }
      _recover(host, generation);
    }());
  }

  /// Whether the machine a dial is for is still one the user has.
  ///
  /// THE OTHER HALF OF THE SAME BUG. A profile captured before the dial started
  /// is a snapshot, and the user can delete the machine it names while the loop
  /// is between attempts — at which point every further attempt is a connection
  /// to something that no longer exists, narrated on a screen that has already
  /// moved on. Reading the list again is what makes "I deleted it" mean "it
  /// stops".
  ///
  /// The local pseudo-profile is exempt by construction: it is not in the list,
  /// because it is not a machine the user added — see `HostStore.localProfile`.
  bool _stillWanted(HostProfile host) =>
      host.isLocal ||
      ref.read(hostListProvider).any((h) => h.id == host.id);

  /// Writes progress to this provider's state, but only while this run owns it.
  ///
  /// Every write goes through here. The alternative — checking in the loop and
  /// writing directly — leaves the smallest and most confusing gap of all: a
  /// generation check followed by an `await` followed by a write, which is a
  /// write from a run that was superseded during the await.
  void _publish(int generation, ConnectionStatus next) {
    if (generation != _generation || !ref.mounted) return;
    state = AsyncValue.data(next);
  }

  /// Dials, and dials again while the failure is one that time can fix.
  ///
  /// THE PROGRESS IS WRITTEN TO THIS PROVIDER'S OWN STATE rather than to a
  /// side channel, so there is exactly one thing for the UI to listen to and
  /// no way for "the spinner says connecting" and "the dialler is connecting"
  /// to disagree. Riverpod permits it: the guard that protects against
  /// cross-provider writes during a build (`element.dart`, "Providers are not
  /// allowed to modify other providers during their initialization") names the
  /// offending element, and this is the element doing the building.
  ///
  /// The consequence to know about: `connectionProvider.future` resolves with
  /// the first non-loading value, so a dependent that awaits it during a retry
  /// window can observe `Connecting`. That is self-correcting — the final
  /// value re-notifies the future and the dependent rebuilds — and it is the
  /// price of the UI being able to say "retrying, 2 of 3" at all.
  Future<ConnectionStatus> _dialUntilAnswered(
    HostProfile host,
    int generation,
  ) async {
    // Consumed, not read: the flag describes THIS run. A later dial the user
    // asked for is not a recovery, and saying "the connection dropped" over a
    // machine they just tapped would be the app inventing a fact.
    final afterLoss = _afterLoss;
    _afterLoss = false;

    Object? lastError;
    var spent = 0;

    for (var attempt = 1; attempt <= connectionMaxAttempts; attempt++) {
      // SUPERSEDED: another run of [build] owns the screen now — the user
      // tapped connect again, changed a setting, or deleted a machine. This run
      // keeps its hands off the state and stops dialling.
      if (generation != _generation) return const Disconnected();
      // DELETED: the machine this loop is dialling is not one the user has any
      // more. Every further attempt would be a connection to nothing, narrated
      // on a screen the user has already left.
      if (!_stillWanted(host)) return const Disconnected();

      _publish(generation, Connecting(attempt: attempt, afterLoss: afterLoss));

      if (attempt > 1) {
        // Say what is happening BEFORE the wait, not after it. The wait is the
        // part the user is judging, and silence during it is the difference
        // between "working on it" and "stuck".
        await Future<void>.delayed(ref.read(connectionRetryDelayProvider));
        if (!ref.mounted) return const Disconnected();
      }

      spent = attempt;
      HerdrTransport? opened;
      try {
        final connector = ref.read(hostConnectorProvider);
        // Every stage the transport reports while this dial runs, published as
        // it happens. The guard inside `_publish` is what keeps a superseded
        // run's late report off the screen it no longer owns.
        void report(DialStage stage) => _publish(
              generation,
              Connecting(
                attempt: attempt,
                stage: stage,
                afterLoss: afterLoss,
              ),
            );
        final connected = await connector.connect(host, onStage: report);
        opened = connected.bundle.transport;

        // THE DIAL MAY HAVE TAKEN A MINUTE, and the user may have spent it
        // deleting the machine — in which case this connection now belongs to
        // nobody. Closing it here rather than returning it is the difference
        // between "the app stopped" and "the app left an SSH session open on a
        // machine the user removed".
        if (generation != _generation || !_stillWanted(host)) {
          unawaited(opened.close().catchError((_) {}));
          return const Disconnected();
        }

        // THE STAGE FROM HERE ON IS THE TRANSPORT'S TO REPORT, and it does: a
        // lazily-dialled SSH session reports `resolving`/`dialling`/`hostKey`
        // while this `ping` is what opens it, then `verifying` the moment
        // authentication succeeds. Publishing "verifying" here instead was
        // what made the old narration jump backwards — the screen said the
        // daemon was being probed while the handshake had not started.
        final client = HerdrClient(connected.bundle.transport);
        final hello = await client.ping();
        if (generation != _generation || !_stillWanted(host)) {
          unawaited(client.close());
          return const Disconnected();
        }
        _live = client;
        return Online(
          client: client,
          hello: hello,
          socketPath: connected.socketPath,
        );
      } on Object catch (e) {
        lastError = e;
        // A transport that was opened and then failed the handshake is still
        // holding an SSH connection. Dropping it on the floor leaks the
        // session on the machine for as long as the daemon keeps it alive.
        if (opened != null) unawaited(opened.close().catchError((_) {}));
        if (attempt >= connectionMaxAttempts || !isWorthRetrying(e)) break;
      }
    }

    // THE FAILURE IS PUBLISHED THE SAME WAY PROGRESS IS, and that is not
    // tidiness. This is the last write a run makes, so a run that was
    // superseded while its last dial was failing would otherwise paint "could
    // not reach 10.0.0.7" over a screen that has since said something else
    // entirely. Returning the value rather than writing it is not enough:
    // Riverpod applies the result of a build it has already replaced, which is
    // exactly how the reported bug kept its banner up.
    //
    // `willRetry` is decided HERE and acted on below, so the sentence the user
    // reads and the timer that is running cannot disagree about whether another
    // attempt is coming.
    final willRetry = afterLoss && _slowRounds < connectionSlowRounds;
    _publish(
      generation,
      ConnectionFailed(
        lastError!,
        attempts: spent,
        afterLoss: afterLoss,
        willRetry: willRetry,
      ),
    );
    if (willRetry) _scheduleSlowRetry(host, generation);
    return ConnectionFailed(
      lastError,
      attempts: spent,
      afterLoss: afterLoss,
      willRetry: willRetry,
    );
  }

  /// Keeps trying, slowly, while a RECOVERED link refuses to come back.
  ///
  /// WHY THIS IS NOT JUST "THE LADDER AGAIN". The three-attempt ladder is sized
  /// for a user watching a spinner: most of a minute, then a sentence and a
  /// button. A lost connection is a different situation — the machine is very
  /// often asleep, or the overlay network that carries it is re-establishing a
  /// path, and both fix themselves in a minute or two. Without these rounds the
  /// user taps "reconnect" into a machine that is still asleep, gets the same
  /// failure, and concludes the app is broken; with them the app simply comes
  /// back on its own, and the status line says the connection is gone the whole
  /// time.
  ///
  /// Bounded by [connectionSlowRounds] so nothing dials forever, and silent
  /// between rounds (the published state stays the failure, which is the honest
  /// description of the next thirty seconds) — until the round runs, when the
  /// ordinary [Connecting] narration takes over again.
  void _scheduleSlowRetry(HostProfile host, int generation) {
    _slowRounds++;
    _slowRetry?.cancel();
    _slowRetry = Timer(ref.read(connectionSlowRetryDelayProvider), () {
      if (!ref.mounted || generation != _generation) return;
      if (!_stillWanted(host)) return;
      _afterLoss = true;
      ref.read(connectRequestProvider.notifier).request();
    });
  }

  /// Dials now, because the user asked.
  ///
  /// Bumps the request counter rather than calling [build] directly: the build
  /// already knows how to connect, and having exactly one path into the dial
  /// is what keeps "requested" and "connected" from disagreeing.
  void connect() => ref.read(connectRequestProvider.notifier).request();

  /// Re-runs the whole connect sequence.
  ///
  /// ALSO ONLY A REQUEST, and it used to be a request PLUS a hand-run `build`.
  /// Both at once is two dials for one tap: the counter bump already rebuilds
  /// this provider, so the manual `AsyncValue.guard(build)` was a second,
  /// racing connection whose result could land after the first one's and
  /// overwrite it. That is a plausible reading of "the status never updates
  /// and I have to go back a screen" — one dial wins, the other's answer
  /// arrives late and says something else.
  void reconnect() => ref.read(connectRequestProvider.notifier).request();
}

final connectionProvider =
    AsyncNotifierProvider<ConnectionNotifier, ConnectionStatus>(
  ConnectionNotifier.new,
);

/// The board, kept current by events.
///
/// Replaces a 3-second poll. The poll was correct but wasteful and slow: it
/// spent a round trip every three seconds whether anything had changed or not,
/// and an agent that went blocked could still take three seconds to show up.
///
/// The ordering — subscribe, THEN read — is what makes events trustworthy here.
/// See [BoardSync] for why doing it the other way round loses changes silently.
class BoardNotifier extends AsyncNotifier<AgentList> {
  final _attention = AttentionTracker();
  BoardSync? _sync;
  StreamSubscription<void>? _changes;
  Timer? _resubscribe;
  Timer? _safetyNet;

  /// A slow re-read that runs regardless of events.
  ///
  /// Not a substitute for events — insurance against them. A subscription can
  /// end without either side noticing (a NAT dropping an idle connection is the
  /// usual cause), and a board that silently stops updating is worse than one
  /// that updates late. Thirty seconds is slow enough to cost nothing and fast
  /// enough that the worst case is bounded.
  static const safetyNetInterval = Duration(seconds: 30);

  /// How long to wait before rebuilding a subscription that ended.
  static const resubscribeDelay = Duration(seconds: 3);

  /// The last board actually read, and the machine it came from.
  ///
  /// KEPT ACROSS A RECONNECT, because the alternative is a board that blanks
  /// itself. A rebuild during a recovery — and there is always one, the
  /// connection state changes — used to return [AgentList.empty], so an app
  /// that had just lost its link showed the user "no agents" for as long as the
  /// re-dial took. Blank is the one answer that is a lie: it says the agents
  /// are gone when what is gone is the connection, and `refresh()` has said the
  /// opposite in its own comment since the beginning ("keeps the previous value
  /// on failure instead of flashing an error").
  ///
  /// Keyed by MACHINE, because the other half of the rule is that a stale list
  /// must never be shown for a different host: switching machines is exactly
  /// when a board full of the previous one's agents would look right and be
  /// wrong.
  ({String hostId, AgentList board})? _lastBoard;

  @override
  Future<AgentList> build() async {
    ref.onDispose(() {
      _resubscribe?.cancel();
      _safetyNet?.cancel();
      unawaited(_changes?.cancel());
      unawaited(_sync?.close());
    });

    final hostId = ref.watch(currentHostProvider)?.id ?? '';
    final connection = await ref.watch(connectionProvider.future);
    if (connection is! Online) {
      final cached = _lastBoard;
      if (cached != null && cached.hostId == hostId) return cached.board;
      return AgentList.empty();
    }

    await _startSync(connection.client);
    final board = await _readBoard(connection.client);
    _lastBoard = (hostId: hostId, board: board);
    return board;
  }

  Future<void> _startSync(HerdrClient client) async {
    await _changes?.cancel();
    await _sync?.close();

    try {
      // Subscribe BEFORE reading, so nothing that happens during the read is
      // lost. This is the single line that makes the rest correct.
      final sync = await BoardSync.start(client);
      _sync = sync;

      _changes = sync.changes.listen((_) => unawaited(refresh()));

      _safetyNet?.cancel();
      _safetyNet = Timer.periodic(
        safetyNetInterval,
        (_) => unawaited(refresh()),
      );
    } on Object {
      // The daemon may not support subscriptions, or the stream may have died.
      // Fall back to the safety net alone rather than leaving the board frozen:
      // slow updates beat no updates.
      _scheduleResubscribe();
    }
  }

  void _scheduleResubscribe() {
    _resubscribe?.cancel();
    _resubscribe = Timer(resubscribeDelay, () {
      unawaited(_resubscribeNow());
    });
  }

  Future<void> _resubscribeNow() async {
    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) return;
    await _startSync(connection.client);
    await refresh();
  }

  Future<AgentList> _readBoard(HerdrClient client) => client.board();

  /// Raises a notification for any agent that JUST started waiting.
  ///
  /// The tracker decides what counts as "just" — see [AttentionTracker]. It
  /// also means the first board after opening the app is silent, which is the
  /// difference between a useful feature and one the user turns off in a day.
  Future<void> _maybeNotify(AgentList board) async {
    final fired = _attention.observe(board);
    if (fired.isEmpty) return;
    if (!ref.read(settingsProvider).notificationsEnabled) return;
    await ref.read(agentNotifierProvider).notify(fired);
  }

  /// Re-reads the board without tearing down the connection.
  ///
  /// Keeps the previous value on failure instead of flashing an error: a board
  /// that briefly cannot refresh should show the last known state, not empty
  /// itself and imply the agents are gone.
  Future<void> refresh() async {
    final connection = ref.read(connectionProvider).value;
    if (connection is! Online) return;

    try {
      final board = await _readBoard(connection.client);
      state = AsyncValue.data(board);
      unawaited(_maybeNotify(board));
    } on Object catch (e, st) {
      if (!state.hasValue) state = AsyncValue.error(e, st);
    }
  }
}

/// The notification channel, overridden in tests and on platforms that have
/// none.
final agentNotifierProvider = Provider<AgentNotifier>((ref) {
  final notifier = AgentNotifier(
    onSelected: (paneId) =>
        ref.read(pendingPaneProvider.notifier).open = paneId,
  );
  // Prepared lazily, on first use, so the permission prompt cannot appear
  // before the user has a board to look at.
  unawaited(notifier.initialise());
  return notifier;
});

final boardProvider = AsyncNotifierProvider<BoardNotifier, AgentList>(
  BoardNotifier.new,
);
