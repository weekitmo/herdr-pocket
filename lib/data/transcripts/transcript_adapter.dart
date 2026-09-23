/// Reading an agent's own session file.
///
/// WHY THIS IS A SET OF ADAPTERS RATHER THAN ONE PARSER: there is no protocol
/// here. Every agent writes its own file, in its own shape, at its own path —
/// `docs/research/13-competitive-gap-2026-09.md` has the measured table. What
/// they share is only that they are line-delimited JSON. So the seam is one
/// small adapter per agent, and adding the next agent is adding one file.
///
/// WHY FAILURE IS DATA: the formats are internal and will change without
/// telling us. A parse that returns "I could not read this" is a screen that
/// says so and offers the terminal; a parse that throws is a screen that
/// crashes on somebody else's upgrade. Nothing in this library throws.
library;

import 'package:herdr_pocket/domain/transcript/session_trace.dart';

/// What an adapter made of a file.
sealed class TranscriptParse {
  const TranscriptParse();
}

/// Read well enough to show.
///
/// [badLines] is not zero-tolerance but not hidden either: a transcript that
/// half-parsed is still worth reading, and the screen says how much of it was
/// understood rather than presenting a partial file as the whole session.
class ParsedTranscript extends TranscriptParse {
  const ParsedTranscript(this.session);

  final TraceSession session;
}

/// This is not the shape this adapter knows.
class UnusableTranscript extends TranscriptParse {
  const UnusableTranscript(this.detail);

  /// Shown to nobody: it exists for the test that asserts *why* an adapter
  /// refused, and for a log line when somebody reports a broken file.
  final String detail;
}

/// One agent's file format.
///
/// THE ADAPTER OWNS EVERYTHING ABOUT THIS AGENT'S SESSIONS: where they live,
/// how to find the right one, how to read the end of it, and how to parse it.
/// The locator is only the machinery around that — try the process's own file,
/// then ask the adapter where it keeps them, then read and parse. Adding an
/// agent is adding a file here, and the locator does not change.
abstract interface class TranscriptAdapter {
  /// The name `agent.list` uses for this agent (`pi`, `codex`).
  String get agentId;

  /// Whether the transcript has to be decompressed as it is read.
  bool get isCompressed;

  /// A shell command that prints the newest transcript for [cwd], or nothing.
  ///
  /// [$HOME] and `$(` must survive as dollars for the REMOTE shell; everything
  /// else in the command is quoted for it here. Getting that mixture wrong is
  /// how this feature once shipped a lookup that could never match.
  String locateCommand(String cwd, DateTime now);

  /// A shell command that prints the last [limit] bytes of [path]'s CONTENT.
  ///
  /// For a compressed transcript this decodes first and then cuts, because the
  /// tail of a compressed stream is not the tail of the file.
  String readTailCommand(String path, int limit);

  /// Whether [firstLine] looks like this agent's file.
  ///
  /// Used to check a guess: the locator can find a `.jsonl` by path and still
  /// be wrong about which agent wrote it, and reading a codex file with the pi
  /// adapter would produce an empty session that looks like a real answer.
  bool canParse(String firstLine);

  /// Reads a whole file. Never throws.
  TranscriptParse parse(Iterable<String> lines);
}

/// The adapters this build knows how to read live in `transcript_registry.dart`,
/// which is the only file that lists them — keeping this one free of the
/// imports that would make the two files mutually dependent.

// --- Shell quoting ---------------------------------------------------------
//
// Two languages, one string: a command is built in Dart and parsed by `sh`.
// The rule is always the same — the parts that must be expanded by the REMOTE
// shell stay as bare `$…`, everything derived from user data is quoted here.

/// Quotes a value as a single-quoted shell word. Safe for any content.
String quoteShell(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";

/// Quotes a value for the INSIDE of a double-quoted shell word.
///
/// Used where something else in the same word has to expand (a `$HOME`), which
/// single quotes would switch off.
String dqShell(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll(r'$', r'\$')
    .replaceAll('`', r'\`');

/// The directory a cwd maps to under an agent's sessions root.
///
/// Three of the four agents seen so far name the directory after the working
/// directory: `/Users/x/app` becomes `--Users-x-app--`.
String cwdSlug(String cwd) =>
    '--${cwd.replaceFirst('/', '').replaceAll('/', '-')}--';

// --- Tolerant readers ------------------------------------------------------
//
// The formats drift between versions, so every field is read through one of
// these and a missing one is simply absent. `strict-casts` is on in
// analysis_options.yaml, which is why they all return nullable types instead
// of casting at the use site.

Map<String, Object?>? mapOf(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Object?> listOf(Object? value) => value is List<Object?> ? value : const [];

String? stringOf(Object? value) => value is String ? value : null;

int? intOf(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  return null;
}

double? doubleOf(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return null;
}

/// An ISO-8601 timestamp, which is what both formats write at the line level.
DateTime? timeOf(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// Epoch milliseconds. pi writes message timestamps this way.
DateTime? timeMsOf(Object? value) {
  final ms = intOf(value);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Epoch seconds. codex writes `task_started.started_at` this way.
DateTime? timeSecOf(Object? value) {
  final seconds = intOf(value);
  return seconds == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Joins the text of every block of the given [type] in a content list.
String textOfBlocks(Object? content, {Set<String> types = const {'text'}}) {
  final blocks = listOf(content);
  final parts = <String>[];
  for (final block in blocks) {
    final map = mapOf(block);
    if (map == null) continue;
    if (!types.contains(stringOf(map['type']))) continue;
    final text = stringOf(map['text']);
    if (text != null && text.isNotEmpty) parts.add(text);
  }
  return parts.join('\n\n');
}
