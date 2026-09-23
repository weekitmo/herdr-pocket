/// Finding the file, on the machine, over the connection we already have.
///
/// THREE STRATEGIES, IN ORDER OF HOW MUCH THEY KNOW:
///
///   1. the process's own open file (`lsof -p <pid>`), which is the agent
///      telling us where it is writing — a fact, when it works at all;
///   2. the newest file in the directory that belongs to this pane's working
///      directory, which is what pi's layout makes possible;
///   3. the newest file anywhere under the agent's session root, which is a
///      guess and is reported as one.
///
/// The caller is told which one answered, because the screen has to say
/// "按目录推测的最新会话" when it guessed. A ledger silently built from the wrong
/// session is worse than no ledger: it looks like an answer.
///
/// WHY THE PATH IS GUARDED: the remote shell is not a login shell, so `lsof`
/// (which lives in `/usr/sbin` on macOS) is often not on PATH at all. The first
/// version of this file ran `lsof` and got "command not found" on a machine
/// where it exists — the same class of bug as the `herdr` path resolution.
library;

import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/data/transcripts/transcript_registry.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// How sure we are about the file we found.
enum TranscriptSource {
  /// The agent process had it open.
  openFile,

  /// The newest file in the directory that belongs to this pane's cwd.
  byDirectory,

  /// The newest file under the agent's session root. A guess.
  byRecency,
}

/// A file we believe holds this pane's session.
class TranscriptLocation {
  const TranscriptLocation({
    required this.path,
    required this.source,
    this.alternatives = const [],
  });

  final String path;
  final TranscriptSource source;

  /// Other files the adapter offered, newest first, tried in order when the
  /// first one turns out to have nothing in it.
  final List<String> alternatives;

  /// Whether the screen owes the user a note about how this was found.
  bool get isGuess => source != TranscriptSource.openFile;
}

/// Looking for a session file.
class TranscriptLocator {
  const TranscriptLocator(this._runner, {this.tailBytes = 512 * 1024});

  final RemoteCommandRunner _runner;

  /// How much of the END of the file to read.
  ///
  /// Sessions run to tens of megabytes — one on the machine this was written
  /// against is 18 MB — and a phone wants the recent end, not the beginning.
  /// The figure is a compromise: big enough to hold several turns of real tool
  /// output, small enough to arrive on a slow link.
  final int tailBytes;

  /// Finds and reads the newest session belonging to [cwd].
  ///
  /// [pid] is the agent's own process when the daemon can tell us, and null
  /// when it cannot — which is not an error, only one fewer strategy.
  Future<LocatedTranscript> locate({
    required String agentId,
    required String cwd,
    int? pid,
  }) async {
    final adapter = adapterForAgent(agentId);
    if (adapter == null) return UnsupportedAgent(agentId, supportedLedgerAgents);

    final now = DateTime.now();
    final candidates = <TranscriptLocation>[];

    if (pid != null) {
      final open = await _openFileOf(pid, adapter.agentId);
      if (open != null) {
        candidates.add(
          TranscriptLocation(path: open, source: TranscriptSource.openFile),
        );
      }
    }

    final guessed = await _newestFor(adapter, cwd: cwd, now: now);
    if (guessed != null) {
      candidates
        ..add(guessed)
        ..addAll([
          for (final path in guessed.alternatives)
            TranscriptLocation(path: path, source: guessed.source),
        ]);
    }

    if (candidates.isEmpty) return const NoTranscript();

    // ASK THE ADAPTER TO READ IT, rather than asking one line whether this
    // looks like the agent's file. Two rounds of bugs came out of that one
    // line: the sample was a fragment (we read the END of a file, so the first
    // line is usually half a record), and then it was a record the adapter's
    // vocabulary did not happen to list. A parse either understands the file or
    // says it cannot, and the adapters already count what they understood.
    // WALK THE CANDIDATES, newest first, and prefer one that has something to
    // show. An agent that opens a session directory every time it runs leaves
    // empty ones behind; reporting the newest of those as "no session record
    // found" would be answering the wrong question.
    FoundTranscript? empty;
    for (final candidate in candidates) {
      final read = await _read(adapter, candidate.path);
      if (read == null) continue;
      final (lines, truncated) = read;
      final parse = adapter.parse(lines);
      if (parse is! ParsedTranscript) continue;
      final found = FoundTranscript(
        location: candidate,
        parse: parse,
        truncated: truncated,
      );
      if (parse.session.turns.isNotEmpty) return found;
      // A session with no turns is a real answer — it just is not a useful one
      // while there is an older session with content to try first.
      empty ??= found;
    }

    return empty ?? const NoTranscript();
  }

  /// `lsof` is not on a non-login shell's PATH on macOS; `/usr/sbin` is where
  /// it actually lives, so both are tried before giving up on this strategy.
  Future<String?> _openFileOf(int pid, String agentId) async {
    const probe = r'L="$(command -v lsof || echo /usr/sbin/lsof)"; '
        r'[ -x "$L" ] && "$L" -p ';
    final output = await _run('$probe$pid -Fn 2>/dev/null');
    if (output == null) return null;
    for (final line in output.split('\n')) {
      // `-Fn` prints one name per line, prefixed with `n`.
      if (!line.startsWith('n')) continue;
      final path = line.substring(1);
      if (!path.endsWith('.jsonl')) continue;
      if (path.contains('/sessions/')) return path;
    }
    return null;
  }

  /// Asks the adapter where its sessions live, and takes its answer.
  ///
  /// The per-agent knowledge — the directory layout, the slug rule, the glob —
  /// lives in the adapter, not here. Adding an agent must not mean editing this
  /// file, and the first version of this feature proved why: the pi lookup's
  /// quoting was wrong and this file was where it hid.
  Future<TranscriptLocation?> _newestFor(
    TranscriptAdapter adapter, {
    required String cwd,
    required DateTime now,
  }) async {
    final output = await _run(adapter.locateCommand(cwd, now));
    if (output == null) return null;
    final paths = [
      for (final line in output.trim().split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (paths.isEmpty) return null;
    // What the adapter found: derived from the pane's own working directory,
    // which is a fact about where we looked rather than a guess about which
    // session the agent is in.
    return TranscriptLocation(
      path: paths.first,
      source: TranscriptSource.byDirectory,
      alternatives: paths.skip(1).toList(growable: false),
    );
  }

  /// Reads the END of the file, splitting on newlines afterwards so a cut in
  /// the middle of a line costs one line rather than the whole read.
  Future<(List<String>, bool)?> _read(
    TranscriptAdapter adapter,
    String path,
  ) async {
    // The size of the CONTENT, not of the file: a compressed transcript is
    // several times larger once decoded, and it is the decoded size that says
    // whether we are looking at all of it.
    final size = await _run(
      'wc -c < <(${adapter.readTailCommand(path, 1 << 30)}) 2>/dev/null',
    );
    final bytes = int.tryParse(size?.trim() ?? '');
    final wants = bytes ?? tailBytes;
    final limit = wants > tailBytes ? tailBytes : wants;
    final output = await _run(adapter.readTailCommand(path, limit));
    if (output == null) return null;
    // A cut in the middle of a line costs one unreadable line at the top of the
    // window, which the adapters already count rather than fail on.
    return (output.split('\n'), wants > tailBytes);
  }



  Future<String?> _run(String command) async {
    try {
      return await _runner.runCommand(command);
    } on Object {
      // A command that cannot run is a strategy that did not answer, not a
      // failure of the screen: the next strategy gets its turn.
      return null;
    }
  }
}

/// What the locator found.
sealed class LocatedTranscript {
  const LocatedTranscript();
}

/// A file, and what the adapter made of it.
class FoundTranscript extends LocatedTranscript {
  const FoundTranscript({
    required this.location,
    required this.parse,
    required this.truncated,
  });

  final TranscriptLocation location;
  final TranscriptParse parse;

  /// Whether only the end of the file was read.
  final bool truncated;
}

/// The machine has no session for this pane.
class NoTranscript extends LocatedTranscript {
  const NoTranscript();
}

/// Looking for the file went wrong in a way we cannot classify.
///
/// Distinct from [NoTranscript] on purpose: one is "there is nothing here",
/// the other is "we could not tell", and only one of them is the machine's
/// answer. Conflating them is how a parser crash read as an empty directory.
class UnreadableTranscript extends LocatedTranscript {
  const UnreadableTranscript();
}

/// This build cannot read this agent's sessions.
class UnsupportedAgent extends LocatedTranscript {
  const UnsupportedAgent(this.agentId, this.supported);

  final String agentId;
  final List<String> supported;
}
