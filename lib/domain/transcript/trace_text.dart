/// Turning the trace's numbers into something short enough for a phone.
///
/// Pure, and separate from the page, for the same reason as the stats: a table
/// column that says `1.2s` in one row and `2 minutes 4 seconds` in the next is
/// a table nobody can compare down, and "short enough" is a rule worth being
/// able to test.
///
/// The labels around these values (`in`, `out`, `cache`) are NOT here — they
/// are words, they belong to l10n, and the screen composes them.
library;

/// Trims `262000` to `262k`, and keeps one decimal where it still says something.
///
/// The same rule the board uses for its context pair, so one number does not
/// wear two hats in two parts of the app.
String compactCount(int value) {
  final negative = value < 0;
  final magnitude = value.abs();
  final text = switch (magnitude) {
    >= 1000000 => _oneDecimal(magnitude / 1000000, 'M'),
    >= 1000 => _oneDecimal(magnitude / 1000, 'k'),
    _ => '$magnitude',
  };
  return negative ? '-$text' : text;
}

String _oneDecimal(double value, String suffix) {
  // 1.5M reads better than 1M; 262.4k is noise, so the decimal only survives
  // below ten units of its own suffix.
  if (value >= 10) return '${value.round()}$suffix';
  final rounded = value.roundToDouble() == value
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rounded$suffix';
}

/// A duration as a person would say it, in at most three characters of suffix.
///
/// Tools are usually fast and occasionally not, so the scale has to survive
/// both: milliseconds below a second, tenths of a second below a minute, and
/// `1m04s` past it. Sub-millisecond calls read as `0ms` rather than `0.0001s`
/// — at that size the number is noise, but the call still happened.
String formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) {
    final seconds = ms / 1000;
    return seconds < 10 ? '${seconds.toStringAsFixed(1)}s' : '${seconds.round()}s';
  }
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    return '${hours}h${(minutes % 60).toString().padLeft(2, '0')}m';
  }
  return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
}

/// A clock, for the turn headers. `14:22` on a phone; seconds are noise.
String formatClock(DateTime at) {
  final local = at.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// One line out of a tool's arguments, short enough to sit on a row.
///
/// Whitespace collapses because half of what an agent passes is pretty-printed
/// JSON, and a preview that starts with three empty lines tells the reader
/// nothing. The cut is deliberately blunt: an ellipsis means "there is more",
/// and the whole thing is one tap away.
String oneLinePreview(String raw, {int maxChars = 68}) {
  final flattened = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flattened.isEmpty) return '';
  if (flattened.length <= maxChars) return flattened;
  return '${flattened.substring(0, maxChars)}…';
}

/// A result body, trimmed to something a phone can hold in a scroll view.
///
/// The tail is kept as well as the head: a test failure says what broke in its
/// last lines far more often than in its first, and a preview that stops after
/// "Running build..." is worse than no preview at all.
String trimResult(String raw, {int maxChars = 4000}) {
  if (raw.length <= maxChars) return raw;
  final head = raw.substring(0, maxChars ~/ 2);
  final tail = raw.substring(raw.length - maxChars ~/ 2);
  return '$head\n…\n$tail';
}
