/// How the ledger page gets its data.
///
/// A provider rather than a call inside the page, because the page must be
/// renderable in a test with a fixed session — that is the only way to check
/// what the screen says about a tool table without a live machine.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transcripts/transcript_locator.dart';

/// Finds and reads a pane's session file.
typedef LedgerLoader =
    Future<LocatedTranscript> Function({
      required String agentId,
      required String cwd,
      int? pid,
    });

/// The loader for the live connection, or null when there is no runner.
///
/// Null is a real answer: the local-socket transport cannot run commands, so on
/// a desktop talking to a local daemon there is nothing to read a file with,
/// and the page says that instead of spinning.
final ledgerLoaderProvider = Provider<LedgerLoader?>((ref) {
  final runner = ref.watch(remoteRunnerProvider);
  if (runner == null) return null;
  final locator = TranscriptLocator(runner);
  return locator.locate;
});
