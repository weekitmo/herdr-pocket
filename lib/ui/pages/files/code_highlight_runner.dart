import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/domain/highlight/syntax.dart';

/// Tokenises a file's text, off the UI thread.
///
/// ## Why this is a seam rather than a direct `compute` call
///
/// Two reasons, and the second is the one that decided it.
///
/// The first is cost: measured on this machine (JIT, so a phone is slower), 256
/// KB of Dart takes 78 ms and 100 KB of Python 71 ms. That is several frames
/// gone on a page that is being pushed open, so the work belongs in an isolate —
/// and the result is plain data ([CodeLine]s of [CodeRun]s) precisely so it can
/// cross that boundary.
///
/// The second is testability. `compute` spawns a REAL isolate, and a widget test
/// drives a fake clock: a test that has to `runAsync` to see its own colours is
/// a test that will be written once and deleted. Tests override this provider
/// with an inline runner, and the production path is covered by one test that
/// awaits it directly.
typedef CodeHighlightRunner = Future<List<CodeLine>> Function(
  String source,
  String? language,
);

/// The runner the app uses.
final codeHighlightRunnerProvider = Provider<CodeHighlightRunner>(
  (ref) => runHighlightInIsolate,
);

/// Tokenises [source] in a fresh isolate.
Future<List<CodeLine>> runHighlightInIsolate(
  String source,
  String? language,
) =>
    compute(_tokenise, _HighlightJob(source, language));

/// The isolate's entry point. Top-level, and it takes one sendable argument.
List<CodeLine> _tokenise(_HighlightJob job) =>
    highlightLines(job.source, job.language);

/// One job, as a plain object.
///
/// A class rather than a record because this is what crosses the isolate
/// boundary: two `final` fields of sendable types, nothing captured, nothing
/// native. A closure or a `ReceivePort` in here would fail at runtime with an
/// error about isolate messages, on a phone, on the one file large enough to
/// notice.
class _HighlightJob {
  const _HighlightJob(this.source, this.language);

  final String source;
  final String? language;
}
