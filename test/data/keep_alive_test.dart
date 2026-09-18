import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/local/keep_alive.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// WHEN THE PROCESS IS HELD ALIVE, AND WHEN IT IS LET GO.
///
/// The feature is a foreground service, which is a persistent notification and
/// a process Android will not freeze — so the interesting part is not "does it
/// start" but the two judgement calls around it:
///
///   * it must be held through a RECOVERY, because a frozen app runs no timers
///     and the retry rounds for a sleeping machine would never fire while the
///     user is in another app;
///   * it must be released when there is nothing left to keep — a failure that
///     will not be retried, a deliberate disconnect, or the user turning the
///     switch off — because a notification claiming to hold a connection that
///     no longer exists is worse than no notification.
void main() {
  // THE HOLDS ARE WRITTEN THROUGH THE SCHEDULER. `KeepAliveHolders` writes
  // through `runOutsideFrame`, because a page releases its hold from
  // `dispose` — inside the frame's unmount pass — and a widget-notifying write
  // from there stops the whole app from ever scheduling another frame. Asking
  // for the binding here is that dependency stated out loud; without it the
  // scheduler has no phase to report and the getter throws.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the policy', () {
    test('held while connected, released when the user says so', () {
      expect(keepAliveWanted(enabled: true, status: _online()), isTrue);
      expect(
        keepAliveWanted(enabled: false, status: _online()),
        isFalse,
        reason: 'the switch is the whole answer to "may I spend a notification"',
      );
    });

    test('held through a recovery, including its waiting periods', () {
      expect(
        keepAliveWanted(
          enabled: true,
          status: const Connecting(attempt: 2, afterLoss: true),
        ),
        isTrue,
        reason: 'the slow retry rounds only run if the process is awake',
      );
      expect(
        keepAliveWanted(
          enabled: true,
          status: ConnectionFailed(
            Exception('no route'),
            afterLoss: true,
            willRetry: true,
          ),
        ),
        isTrue,
        reason: 'between rounds the app is idle, and that is when it freezes',
      );
    });

    test('held for a page that owns its own session', () {
      // The SSH shell page dials its own connection and may be open on a
      // machine with no herdr at all — so the herdr connection being absent
      // says nothing about whether there is something to keep.
      expect(
        keepAliveWanted(
          enabled: true,
          status: const Disconnected(),
          sessionOpen: true,
        ),
        isTrue,
      );
      expect(
        keepAliveWanted(
          enabled: false,
          status: const Disconnected(),
          sessionOpen: true,
        ),
        isFalse,
        reason: 'the switch outranks everything',
      );
    });

    test('released when nothing is left to keep', () {
      expect(
        keepAliveWanted(
          enabled: true,
          status: ConnectionFailed(
            Exception('no route'),
            afterLoss: true,
            willRetry: false,
          ),
        ),
        isFalse,
        reason: 'out of rounds: holding the process would promise a retry that '
            'is not coming',
      );
      expect(
        keepAliveWanted(enabled: true, status: const Disconnected()),
        isFalse,
        reason: 'nobody asked for a connection, so there is none to keep',
      );
      expect(
        keepAliveWanted(
          enabled: true,
          status: const Connecting(attempt: 1),
        ),
        isFalse,
        reason: 'a first dial has no connection yet — the app is on screen, '
            'which is the one place a process cannot be frozen',
      );
      expect(
        keepAliveWanted(
          enabled: true,
          status: ConnectionFailed(Exception('denied')),
        ),
        isFalse,
        reason: 'a first dial that failed is not an outage to survive',
      );
    });
  });

  group('the holds', () {
    test('an id held twice is released once', () {
      // Two pages, or one page rebuilt: the ids must not add up to two holds
      // that a single close cannot release.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final holds = container.read(keepAliveHoldersProvider.notifier);

      holds.hold('shell');
      holds.hold('shell');
      expect(container.read(keepAliveHoldersProvider), {'shell'});

      holds.release('shell');
      expect(container.read(keepAliveHoldersProvider), isEmpty);
    });
  });

  group('the controller', () {
    test('starts once, and keeps its word', () async {
      final fake = _FakeKeepAlive();
      final controller = KeepAliveController(fake);
      final online = _online();

      expect(
        await controller.sync(
          enabled: true,
          status: online,
          title: 'Herdr Pocket',
          text: 'Keeping the connection to dev open',
        ),
        isTrue,
      );
      expect(fake.starts, 1);
      expect(fake.title, 'Herdr Pocket');
      expect(fake.text, contains('dev'));

      // A reconnect publishes several states; only the ANSWER changing may
      // reach the platform, or every dial would restart the service.
      await controller.sync(
        enabled: true,
        status: online,
        title: 'Herdr Pocket',
        text: 'Keeping the connection to dev open',
      );
      expect(fake.starts, 1);
      expect(fake.stops, 0);
    });

    test('turning the switch off stops it immediately', () async {
      final fake = _FakeKeepAlive();
      final controller = KeepAliveController(fake);

      await controller.sync(
        enabled: true,
        status: _online(),
        title: 't',
        text: 'x',
      );
      expect(controller.isHeld, isTrue);

      await controller.sync(
        enabled: false,
        status: _online(),
        title: 't',
        text: 'x',
      );

      expect(fake.stops, 1);
      expect(
        controller.isHeld,
        isFalse,
        reason: 'turning it off has to be immediate: a switch that leaves the '
            'notification there until the next reconnect is a switch that '
            'looks broken',
      );
    });

    test('a platform that refuses is reported, not retried in a loop',
        () async {
      // The phone's answer is allowed to be no — no notification permission, an
      // OEM that blocks background starts. What must not happen is the app
      // believing it is held when it is not: the settings row reads this.
      final fake = _FakeKeepAlive(willStart: false);
      final controller = KeepAliveController(fake);

      expect(
        await controller.sync(
          enabled: true,
          status: _online(),
          title: 't',
          text: 'x',
        ),
        isFalse,
      );
      expect(controller.isHeld, isFalse);

      // The retry is the caller's next sync (a reconnect), not a spin here.
      await controller.sync(
        enabled: true,
        status: _online(),
        title: 't',
        text: 'x',
      );
      expect(fake.starts, 2);
    });
  });
}

Online _online() => const Online(
      client: _NoClient(),
      hello: HerdrHello(version: '0.9.0', protocol: 22, capabilities: {}),
      socketPath: '/home/dev/.config/herdr/herdr.sock',
    );

/// A client the policy tests never use: they only look at the status.
class _NoClient implements HerdrClient {
  const _NoClient();

  @override
  HerdrTransport get transport => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeKeepAlive implements ProcessKeeper {
  _FakeKeepAlive({this.willStart = true});

  final bool willStart;

  int starts = 0;
  int stops = 0;
  String? title;
  String? text;

  @override
  Future<bool> start({required String title, required String text}) async {
    starts++;
    this.title = title;
    this.text = text;
    return willStart;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}
