import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/pane_scroll_watch.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/workspace/pane_scroll_event.dart';

/// A daemon that will (or will not) open a scroll subscription.
class _FakeDaemon implements HerdrTransport {
  _FakeDaemon({this.subscribe = true});

  /// Whether the daemon opens the channel at all. False stands in for an older
  /// protocol, a refused kind, or a machine that answers nothing — the three
  /// cases the page has to survive by falling back to its own mirror.
  final bool subscribe;

  /// The subscriptions the client asked for, verbatim.
  final List<Map<String, Object?>> asked = [];

  StreamController<String>? channel;

  @override
  Future<String> roundTrip(String requestLine) async =>
      '{"id":"","error":{"code":"unknown_method","message":"n/a"}}';

  @override
  Future<HerdrDuplex> openDuplex(String openLine) async {
    final request = (jsonDecode(openLine) as Map).cast<String, Object?>();
    if (request['method'] != 'events.subscribe') {
      throw UnimplementedError('not an event channel: ${request['method']}');
    }
    asked.add((request['params']! as Map).cast<String, Object?>());
    final controller = StreamController<String>();
    channel = controller;
    if (!subscribe) {
      // Refused the way the daemon refuses: an error envelope on the channel,
      // then it closes.
      scheduleMicrotask(() {
        controller.add(
          '{"id":"${request['id']}","error":{"code":"invalid_request",'
          '"message":"missing field `pane_id`"}}',
        );
        unawaited(controller.close());
      });
    } else {
      controller.add(
        '{"id":"${request['id']}","result":{"type":"subscription_started"}}',
      );
    }
    return _FakeDuplex(controller.stream);
  }

  /// Pushes one event line the way the daemon does.
  void emit(String line) => channel?.add(line);

  /// Pushes a real-shaped scroll event for [paneId].
  void emitScroll({
    required String paneId,
    required int offset,
    required int max,
  }) {
    emit(
      jsonEncode({
        'event': 'pane.scroll_changed',
        'data': {
          'pane_id': paneId,
          'workspace_id': 'w13',
          'scroll': {
            'offset_from_bottom': offset,
            'max_offset_from_bottom': max,
            'viewport_rows': 24,
          },
        },
      }),
    );
  }

  @override
  Future<void> close() async {}
}

class _FakeDuplex implements HerdrDuplex {
  _FakeDuplex(this._lines);

  final Stream<String> _lines;

  @override
  Stream<String> get lines => _lines;

  @override
  void send(String line) {}

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {}
}

void main() {
  group("watching one pane's scroll state", () {
    test('asks for that pane, and only that pane', () async {
      final daemon = _FakeDaemon();
      final watch = await PaneScrollWatch.start(
        HerdrClient(daemon),
        paneId: 'w13:p1',
      );
      addTearDown(watch!.close);

      // THE PANE ID IS NOT OPTIONAL, and this is the assertion that remembers
      // it: the daemon rejected the first version of this subscription with
      // `missing field pane_id`, and the failure was invisible in the app —
      // the page simply kept its own mirror and looked exactly as it did before.
      expect(daemon.asked, hasLength(1));
      expect(daemon.asked.single['subscriptions'], [
        {'type': 'pane.scroll_changed', 'pane_id': 'w13:p1'},
      ]);
    });

    test("hands the daemon's numbers to the page", () async {
      final daemon = _FakeDaemon();
      final watch = (await PaneScrollWatch.start(
        HerdrClient(daemon),
        paneId: 'w13:p1',
      ))!;
      addTearDown(watch.close);

      final seen = <PaneScrollEvent>[];
      final listen = watch.states.listen(seen.add);
      addTearDown(listen.cancel);

      daemon.emitScroll(paneId: 'w13:p1', offset: 15, max: 385);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      expect(seen.single.offset, 15);
      expect(seen.single.max, 385);

      // The case the mirror cannot express: the reader swiped past the top and
      // the daemon refused, so the offset stops where the history does.
      daemon.emitScroll(paneId: 'w13:p1', offset: 385, max: 385);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.offset, 385);
      expect(seen.last.atOldest, isTrue);
    });

    test("drops another pane's events", () async {
      final daemon = _FakeDaemon();
      final watch = (await PaneScrollWatch.start(
        HerdrClient(daemon),
        paneId: 'w13:p1',
      ))!;
      addTearDown(watch.close);

      final seen = <PaneScrollEvent>[];
      final listen = watch.states.listen(seen.add);
      addTearDown(listen.cancel);

      daemon.emitScroll(paneId: 'w9:p1', offset: 900, max: 1970);
      daemon.emitScroll(paneId: 'w13:p1', offset: 3, max: 385);
      await Future<void>.delayed(Duration.zero);

      // One event, not two: a page that switched panes must not have the pane it
      // left move its mirror, and a subscription that leaked would do exactly
      // that.
      expect(seen, hasLength(1));
      expect(seen.single.paneId, 'w13:p1');
    });

    test('returns null instead of throwing when the daemon refuses', () async {
      final daemon = _FakeDaemon(subscribe: false);
      final watch = await PaneScrollWatch.start(
        HerdrClient(daemon),
        paneId: 'w13:p1',
      );
      // The page then keeps its own mirror — the old behaviour, which is right
      // for a pane only this phone is scrolling. A screen that refused to open
      // because an optional correction channel was unavailable would be trading
      // a working terminal for a pristine one.
      expect(watch, isNull);
    });

    test('closing twice is safe', () async {
      final daemon = _FakeDaemon();
      final watch = (await PaneScrollWatch.start(
        HerdrClient(daemon),
        paneId: 'w13:p1',
      ))!;
      await watch.close();
      await watch.close();
    });

    test('the channel ending closes the stream rather than hanging', () async {
      final daemon = _FakeDaemon();
      final watch = (await PaneScrollWatch.start(
        HerdrClient(daemon),
        paneId: 'w13:p1',
      ))!;
      addTearDown(watch.close);

      final done = watch.states.toList();
      await daemon.channel!.close();
      expect(await done, isEmpty);
    });
  });
}
