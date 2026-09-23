/// The agents this build can read a session file for.
///
/// One list, in its own file, so that `transcript_adapter.dart` stays free of
/// the imports it would need to name a concrete adapter. Adding an agent is:
/// write `<name>_transcript.dart`, add its class here, add a fixture — and the
/// entry row in the terminal's menu picks it up on its own.
library;

import 'package:herdr_pocket/data/transcripts/codex_transcript.dart';
import 'package:herdr_pocket/data/transcripts/dsh_transcript.dart';
import 'package:herdr_pocket/data/transcripts/pi_transcript.dart';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';

const List<TranscriptAdapter> transcriptAdapters = [
  PiTranscript(),
  DshTranscript(),
  CodexTranscript(),
];

/// The adapter for an agent name, or null when we cannot read that agent.
///
/// Null is a real answer, not a failure: herdr knows seventeen agents and this
/// build can read two of them, and a pane running any of the other fifteen
/// simply does not offer the ledger.
TranscriptAdapter? adapterForAgent(String agentId) {
  final wanted = agentId.trim().toLowerCase();
  for (final adapter in transcriptAdapters) {
    if (adapter.agentId == wanted) return adapter;
  }
  return null;
}

/// The adapter that recognises [firstLine], for when the path was a guess.
///
/// A hint, not a verdict: one line is a weak sample, and the line this is
/// usually asked about is the first of a window read from the END of a file,
/// which is half a record more often than not. Prefer [adapterForLines].
TranscriptAdapter? adapterForLine(String firstLine) {
  for (final adapter in transcriptAdapters) {
    if (adapter.canParse(firstLine)) return adapter;
  }
  return null;
}

/// The adapter that can actually read [lines].
///
/// Asked by PARSING rather than by inspecting one line: an adapter either
/// understands the file or says it cannot, and that answer is not fooled by
/// where the cut landed. The locator decides the same way, with the agent name
/// it already has; this is that rule for callers that have only the file.
///
/// A COUNT, not a first-past-the-post, because a file with no conversation can
/// be claimed by more than one adapter — pi's header check accepts a dsh
/// `session` line, and "whoever parses it first" then picks the wrong one. The
/// adapter that understands the most lines is the one that wrote the file.
TranscriptAdapter? adapterForLines(List<String> lines) {
  final sample = [
    for (final line in lines)
      if (line.trim().isNotEmpty) line,
  ];
  if (sample.isEmpty) return null;

  TranscriptAdapter? best;
  var bestScore = 0;
  for (final adapter in transcriptAdapters) {
    if (adapter.parse(lines) is! ParsedTranscript) continue;
    var score = 0;
    for (final line in sample) {
      if (adapter.canParse(line)) score++;
    }
    // Turns beat lines: an adapter that read the conversation is the answer
    // even if another one recognised more metadata.
    final parsed = adapter.parse(lines);
    if (parsed is ParsedTranscript && parsed.session.turns.isNotEmpty) {
      score += sample.length;
    }
    if (score > bestScore) {
      best = adapter;
      bestScore = score;
    }
  }
  return best;
}

/// Every agent this build can render a ledger for.
List<String> get supportedLedgerAgents => [
  for (final adapter in transcriptAdapters) adapter.agentId,
];
