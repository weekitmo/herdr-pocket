import 'dart:convert';

/// One `pane.scroll_changed` event, decoded.
///
/// THE FACT THIS EXISTS FOR. The terminal screen's "N lines back" bar used to be
/// drawn from a number the client advanced by whatever it had ASKED the daemon
/// for. That works right up to the two moments that matter — asking to scroll
/// past the top of the buffer, and asking a pane that has no history at all —
/// because in both the daemon refuses, nothing moves, and the client's own count
/// keeps climbing. The bar then announced a scrollback the user was not in.
///
/// A rendered frame cannot resolve this: history and the present look identical,
/// and every frame is exactly the size that was asked for. The daemon's own
/// scroll bookkeeping can, and this is it — `offset_from_bottom` is where the
/// viewport IS, `max_offset_from_bottom` is HOW MUCH HISTORY THERE IS, and zero
/// is therefore a real, useful answer rather than a missing one.
///
/// Shape verified against a live herdr 0.9.0 (protocol 22):
///
/// ```json
/// {"event":"pane.scroll_changed","data":{"pane_id":"w13:p1","workspace_id":"w13",
///  "scroll":{"max_offset_from_bottom":385,"offset_from_bottom":5,"viewport_rows":24}}}
/// ```
///
/// Only three fields, all required by the daemon's own schema
/// (`subscription_event.$defs.PaneScrollInfo`), which is why a line missing any of
/// them returns null instead of a half-filled object: a client that reads a
/// default here would be inventing a scroll position, which is the bug.
class PaneScrollEvent {
  const PaneScrollEvent({
    required this.paneId,
    required this.offset,
    required this.max,
    this.viewportRows,
  });

  /// The pane this describes. Callers must check it: one subscription can carry
  /// events for whatever it was opened on, and a page that has moved to another
  /// pane must ignore the old one's.
  final String paneId;

  /// Where the viewport is, in lines back from the live bottom.
  final int offset;

  /// How many lines of history there are to scroll back through.
  ///
  /// Zero means the pane cannot scroll at all. That is not an error and not
  /// "unknown" — it is the answer.
  final int max;

  /// Rows the pane was rendered with, when reported.
  final int? viewportRows;

  /// True when the reader is as far back as the buffer goes.
  ///
  /// False for a pane with no history at all: "at the top of nothing" is not a
  /// state worth telling anybody about, and it is exactly the state the old bar
  /// used to announce.
  bool get atOldest => max > 0 && offset >= max;

  /// Decodes one event line, or null if it is not a `pane.scroll_changed`.
  ///
  /// Tolerant about the envelope and strict about the payload, which is the split
  /// the daemon's own evolution makes useful: the envelope key has moved between
  /// `event`/`type`/`kind` before (see `parseEventEnvelope`) while the number we
  /// cannot guess lives inside `scroll`.
  static PaneScrollEvent? tryParse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final rawKind = decoded['event'] ?? decoded['type'] ?? decoded['kind'];
    // Dotted on `events.subscribe`, snake_case on `events.wait` — the same
    // normalisation `parseEventEnvelope` applies, applied the same way.
    final kind = switch (rawKind) {
      final String s => s,
      final Map<Object?, Object?> m when m['type'] is String =>
        m['type']! as String,
      _ => null,
    };
    if (kind == null || kind.replaceAll('_', '.') != 'pane.scroll.changed') {
      return null;
    }

    // The payload is under `data` in the shapes seen so far; accepting the
    // top-level one as well costs a branch and removes a class of "the daemon
    // moved it" bug.
    final payload = decoded['data'];
    final source = payload is Map ? payload : decoded;

    final paneId = source['pane_id'];
    if (paneId is! String || paneId.isEmpty) return null;

    final scroll = source['scroll'];
    if (scroll is! Map) return null;

    final offset = _int(scroll['offset_from_bottom']);
    final max = _int(scroll['max_offset_from_bottom']);
    if (offset == null || max == null) return null;

    return PaneScrollEvent(
      paneId: paneId,
      offset: offset < 0 ? 0 : offset,
      max: max < 0 ? 0 : max,
      viewportRows: _int(scroll['viewport_rows']),
    );
  }

  static int? _int(Object? v) => switch (v) {
        final int v => v,
        final String v => int.tryParse(v),
        _ => null,
      };

  @override
  String toString() =>
      'PaneScrollEvent($paneId, $offset/$max'
      '${viewportRows == null ? '' : ', ${viewportRows}rows'})';
}
