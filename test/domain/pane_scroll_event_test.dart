import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/workspace/pane_scroll_event.dart';

/// The event that tells the terminal where the reader actually is.
///
/// WHY THIS IS A TEST FILE AND NOT THREE LINES IN THE PAGE. Every failure mode
/// here is silent. A parser that reads the wrong key returns null and the page
/// quietly keeps its own mirror — which is exactly the bug this event was
/// adopted to fix, wearing the same clothes as the fix. A parser that accepts a
/// line missing `max_offset_from_bottom` and fills in zero would make a pane
/// with history look unscrollable. A parser that ignores `pane_id` would let the
/// pane the user just left move the mirror of the one they are looking at.
///
/// The shape is the daemon's own, captured live (herdr 0.9.0, protocol 22):
///
/// ```json
/// {"event":"pane.scroll_changed","data":{"pane_id":"w13:p1","workspace_id":"w13",
///  "scroll":{"max_offset_from_bottom":385,"offset_from_bottom":5,"viewport_rows":24}}}
/// ```
void main() {
  String line({
    String kind = 'pane.scroll_changed',
    String paneId = 'w13:p1',
    Object? offset = 5,
    Object? max = 385,
    Object? rows = 24,
    bool nest = true,
  }) {
    final scroll = <String, Object?>{
      if (offset != null) 'offset_from_bottom': offset,
      if (max != null) 'max_offset_from_bottom': max,
      if (rows != null) 'viewport_rows': rows,
    };
    final payload = <String, Object?>{'pane_id': paneId, 'scroll': scroll};
    return jsonEncode(
      nest
          ? {'event': kind, 'data': payload}
          : {...payload, 'event': kind},
    );
  }

  group("decoding the daemon's own scroll state", () {
    test('reads the live shape', () {
      final event = PaneScrollEvent.tryParse(line());
      expect(event, isNotNull);
      expect(event!.paneId, 'w13:p1');
      expect(event.offset, 5);
      expect(event.max, 385);
      expect(event.viewportRows, 24);
      expect(event.atOldest, isFalse);
    });

    test('accepts the snake_case kind and the flattened payload', () {
      // Both are shapes the daemon has used for events before — see
      // `parseEventEnvelope`, which normalises the same way for the same reason.
      final snake = PaneScrollEvent.tryParse(line(kind: 'pane_scroll_changed'));
      expect(snake?.offset, 5);
      final flat = PaneScrollEvent.tryParse(line(nest: false));
      expect(flat?.paneId, 'w13:p1');
      expect(flat?.max, 385);
    });

    test('a pane with no history is a real answer, not a missing one', () {
      final event = PaneScrollEvent.tryParse(line(offset: 0, max: 0));
      expect(event, isNotNull);
      expect(event!.max, 0);
      // "At the top of nothing" is not a state worth announcing: it is the one
      // the old bar used to announce for every swipe on a fresh shell.
      expect(event.atOldest, isFalse);
    });

    test('says so when the reader is as far back as the buffer goes', () {
      expect(PaneScrollEvent.tryParse(line(offset: 385, max: 385))!.atOldest,
          isTrue);
      expect(PaneScrollEvent.tryParse(line(offset: 400, max: 385))!.atOldest,
          isTrue, reason: 'a buffer trimmed under the reader is still the top');
      expect(PaneScrollEvent.tryParse(line(offset: 384, max: 385))!.atOldest,
          isFalse);
    });

    test('negative numbers are clamped rather than carried into the UI', () {
      final event = PaneScrollEvent.tryParse(line(offset: -4, max: -1));
      expect(event!.offset, 0);
      expect(event.max, 0);
    });

    test('numbers arriving as strings still decode', () {
      // The socket has sent integers as strings for other fields before; the
      // client already tolerates it in `HerdrClient._asInt`.
      final event = PaneScrollEvent.tryParse(line(offset: '42', max: '100'));
      expect(event!.offset, 42);
      expect(event.max, 100);
    });
  });

  group('what it refuses, and why refusing matters', () {
    test('a different event kind', () {
      expect(PaneScrollEvent.tryParse(line(kind: 'pane.focused')), isNull);
      expect(PaneScrollEvent.tryParse(line(kind: 'pane.created')), isNull);
    });

    test('a payload without a maximum', () {
      // The failure this guards: defaulting the missing maximum to zero would
      // tell the page "this pane has no history" and make it refuse to scroll a
      // pane that has plenty.
      expect(PaneScrollEvent.tryParse(line(max: null)), isNull);
    });

    test('a payload without an offset, or without a pane', () {
      expect(PaneScrollEvent.tryParse(line(offset: null)), isNull);
      expect(PaneScrollEvent.tryParse(line(paneId: '')), isNull);
      expect(PaneScrollEvent.tryParse(line(paneId: '')), isNull);
    });

    test('anything that is not a JSON object', () {
      expect(PaneScrollEvent.tryParse('not json at all'), isNull);
      expect(PaneScrollEvent.tryParse('[1,2,3]'), isNull);
      expect(PaneScrollEvent.tryParse(''), isNull);
      // A terminal frame is not a scroll event, and this stream shares a channel
      // with other kinds — a parser that threw here would kill the subscription.
      expect(
        PaneScrollEvent.tryParse('{"type":"terminal.frame","bytes":"AAAA"}'),
        isNull,
      );
    });
  });
}
