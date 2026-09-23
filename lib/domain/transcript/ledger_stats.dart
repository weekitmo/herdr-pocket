/// What a session adds up to: per tool, and in total.
///
/// Pure Dart, and deliberately separate from the page. The numbers on this
/// screen are the whole feature — "which tool did the work, how long did it
/// take, how often did it fail" — so they are computed where they can be
/// checked against hand-counted fixtures rather than inside a build method.
library;

import 'package:herdr_pocket/domain/transcript/session_ledger.dart';

/// One row of the tool table.
class ToolStat {
  const ToolStat({
    required this.name,
    required this.count,
    required this.failures,
    required this.measured,
    required this.total,
    required this.median,
  });

  /// Reads one row out of every call to [name] in [calls].
  factory ToolStat.of(String name, List<LedgerToolCall> calls) {
    final durations = [for (final call in calls) ?call.duration]..sort();
    return ToolStat(
      name: name,
      count: calls.length,
      failures: calls.where((c) => c.isError == true).length,
      measured: durations.length,
      total: durations.fold(Duration.zero, (a, b) => a + b),
      median: durations.isEmpty
          ? Duration.zero
          : durations[(durations.length - 1) ~/ 2],
    );
  }

  final String name;

  /// How many times this tool was called in the session.
  final int count;

  /// How many of those the agent reported as failed. Calls with no recorded
  /// result are not counted here — they are not failures, they are unknowns.
  final int failures;

  /// How many calls came back with two timestamps to subtract. The rest are
  /// still counted and listed; they simply contribute no time.
  final int measured;

  /// Busy time across all calls, summed from the paired timestamps.
  final Duration total;

  /// The middle call, so one slow outlier does not describe the tool.
  ///
  /// With an even number of calls this is the lower of the two middle values
  /// rather than their average: an average of two measured durations is a
  /// duration nobody measured, and the smaller one is the honest pick.
  final Duration median;

  /// Calls that never came back, so a table can say so instead of pretending
  /// the count and the durations agree.
  int get open => count - measured;
}

/// Every tool the session used, busiest first.
///
/// Sorted by TOTAL busy time rather than by call count: the question this table
/// answers is "where did this session's time go", and a tool called forty times
/// in three milliseconds did not spend it. Ties fall back to the name so the
/// order is stable between rebuilds.
List<ToolStat> toolStats(List<LedgerTurn> turns) {
  final byName = <String, List<LedgerToolCall>>{};
  for (final turn in turns) {
    for (final call in turn.toolCalls) {
      byName.putIfAbsent(call.name, () => []).add(call);
    }
  }

  final rows = [
    for (final entry in byName.entries) ToolStat.of(entry.key, entry.value),
  ];
  rows.sort((a, b) {
    final byTime = b.total.compareTo(a.total);
    return byTime != 0 ? byTime : a.name.compareTo(b.name);
  });
  return rows;
}

/// The session at a glance.
class LedgerSummary {
  const LedgerSummary({
    required this.turns,
    required this.toolCalls,
    required this.toolFailures,
    required this.openCalls,
    required this.toolBusy,
    this.usage,
    this.firstAt,
    this.lastAt,
    this.contextWindow,
  });

  final int turns;
  final int toolCalls;
  final int toolFailures;
  final int openCalls;

  /// Summed time the session spent inside tools. Not wall-clock: the model was
  /// thinking in between, and that time belongs to no tool.
  final Duration toolBusy;

  final TokenUsage? usage;
  final DateTime? firstAt;
  final DateTime? lastAt;

  /// The model's context window, when the agent stated one.
  final int? contextWindow;

  /// Wall-clock span, when the transcript carries timestamps at both ends.
  Duration? get span =>
      (firstAt == null || lastAt == null) ? null : lastAt!.difference(firstAt!);
}

/// Folds [turns] into [LedgerSummary].
///
/// [reported] is the agent's own session total when it stated one; it wins over
/// the sum, because a number the agent wrote down is better evidence than one we
/// added up from its parts. [contextWindow] is passed through as-is: a window
/// belongs to the model, and only the agent knows which one was in use.
LedgerSummary summarize(
  List<LedgerTurn> turns, {
  TokenUsage? reported,
  int? contextWindow,
}) {
  var calls = 0;
  var failures = 0;
  var open = 0;
  var busy = Duration.zero;
  TokenUsage? usage;
  DateTime? first;
  DateTime? last;

  for (final turn in turns) {
    if (turn.startedAt != null) {
      first ??= turn.startedAt;
      last = turn.startedAt;
    }
    if (turn.usage case final turnUsage?) {
      usage = usage == null ? turnUsage : usage.merge(turnUsage);
    }
    for (final call in turn.toolCalls) {
      calls++;
      if (call.isError == true) failures++;
      if (call.isOpen) open++;
      if (call.duration case final d?) busy += d;
    }
  }

  return LedgerSummary(
    turns: turns.length,
    toolCalls: calls,
    toolFailures: failures,
    openCalls: open,
    toolBusy: busy,
    usage: reported ?? usage,
    firstAt: first,
    lastAt: last,
    contextWindow: contextWindow ?? usage?.contextWindow,
  );
}
