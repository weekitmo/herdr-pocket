import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/transcript/session_trace.dart';
import 'package:herdr_pocket/domain/transcript/trace_stats.dart';
import 'package:herdr_pocket/domain/transcript/trace_text.dart';

/// The trace's arithmetic.
///
/// WHAT THIS FILE PROTECTS: the honesty of the numbers, not their formatting.
/// Three properties matter and each is checkable without a widget:
///
///   * a tool that has no result contributes no time — it is not a zero;
///   * "unknown" and "zero" survive the fold as different things;
///   * tokens are summed at the turn, which is the unit the agents bill.
void main() {
  group('tool stats', () {
    test('count, failures and busy time come from the calls themselves', () {
      final turns = [
        _turn(1, [
          _call('a', 'bash', const Duration(seconds: 4)),
          _call('b', 'bash', const Duration(seconds: 2)),
          _call('c', 'bash', const Duration(seconds: 6), isError: true),
        ]),
      ];

      final row = toolStats(turns).single;
      expect(row.name, 'bash');
      expect(row.count, 3);
      expect(row.failures, 1);
      expect(row.total, const Duration(seconds: 12));
      expect(row.median, const Duration(seconds: 4));
    });

    test('an open call is counted and contributes no time', () {
      final turns = [
        _turn(1, [_call('a', 'bash', const Duration(seconds: 4)), _open('b', 'bash')]),
      ];

      final row = toolStats(turns).single;
      expect(row.count, 2);
      expect(row.measured, 1);
      expect(row.open, 1);
      expect(row.total, const Duration(seconds: 4));
    });

    test('the table is ordered by time spent, not by number of calls', () {
      // Forty fast greps did not spend the session; one slow build did.
      final turns = [
        _turn(1, [
          for (var i = 0; i < 40; i++) _call('g$i', 'grep', const Duration(milliseconds: 5)),
          _call('b', 'build', const Duration(seconds: 30)),
        ]),
      ];

      expect(toolStats(turns).map((r) => r.name), ['build', 'grep']);
    });

    test('the median of an even number of calls is a duration that happened', () {
      final turns = [
        _turn(1, [
          _call('a', 'bash', const Duration(seconds: 1)),
          _call('b', 'bash', const Duration(seconds: 2)),
          _call('c', 'bash', const Duration(seconds: 3)),
          _call('d', 'bash', const Duration(seconds: 10)),
        ]),
      ];

      // Not the average of 2 and 3 — nobody measured 2.5 seconds.
      expect(toolStats(turns).single.median, const Duration(seconds: 2));
    });
  });

  group('summary', () {
    test('tokens are summed across turns and never across tools', () {
      final turns = [
        _turn(1, [_call('a', 'bash', Duration.zero)], usage: const TokenUsage(input: 10, output: 2)),
        _turn(2, [_call('b', 'bash', Duration.zero)], usage: const TokenUsage(input: 5, output: 1)),
      ];

      final summary = summarize(turns);
      expect(summary.usage?.input, 15);
      expect(summary.usage?.output, 3);
      // The per-tool row has no token column at all, and this is why: one
      // inference can emit several calls, so the number has no owner.
      expect(toolStats(turns).map((r) => r.count), [2]);
    });

    test('a reported total wins over the sum', () {
      final turns = [
        _turn(1, const [], usage: const TokenUsage(input: 10, total: 10)),
      ];

      final summary = summarize(
        turns,
        reported: const TokenUsage(input: 9000, total: 9000),
      );
      expect(summary.usage?.input, 9000);
    });

    test('a session with no timestamps reports no span rather than zero', () {
      final summary = summarize([_turn(1, const [])]);
      expect(summary.span, isNull);
    });

    test('the span is the first to the last turn', () {
      final summary = summarize([
        TraceTurn(index: 1, startedAt: DateTime.utc(2026, 9, 23, 10)),
        TraceTurn(index: 2, startedAt: DateTime.utc(2026, 9, 23, 10, 30)),
      ]);

      expect(summary.span, const Duration(minutes: 30));
    });

    test('merging usage keeps "not reported" separate from zero', () {
      const one = TokenUsage(input: 10);
      const two = TokenUsage(output: 4);
      final merged = one.merge(two);

      expect(merged.input, 10);
      expect(merged.output, 4);
      expect(merged.cacheRead, isNull);
      expect(merged.reasoning, isNull);
    });
  });

  group('text', () {
    test('big numbers get one unit, and keep a decimal only where it means something', () {
      expect(compactCount(999), '999');
      expect(compactCount(1200), '1.2k');
      expect(compactCount(262000), '262k');
      expect(compactCount(1700000), '1.7M');
      expect(compactCount(12000000), '12M');
    });

    test('durations stay comparable down a column', () {
      expect(formatDuration(const Duration(milliseconds: 8)), '8ms');
      expect(formatDuration(const Duration(milliseconds: 340)), '340ms');
      expect(formatDuration(const Duration(milliseconds: 3400)), '3.4s');
      expect(formatDuration(const Duration(seconds: 42)), '42s');
      expect(formatDuration(const Duration(minutes: 1, seconds: 4)), '1m04s');
      expect(formatDuration(const Duration(hours: 2, minutes: 5)), '2h05m');
    });

    test('a preview collapses whitespace and says when it cut', () {
      expect(oneLinePreview('{\n  "a": 1\n}'), '{ "a": 1 }');
      expect(oneLinePreview('   '), '');
      expect(oneLinePreview('abcdefghij', maxChars: 4), 'abcd…');
    });

    test('a long result keeps its tail as well as its head', () {
      // A failing test says what broke at the END of its output far more often
      // than at the start.
      final trimmed = trimResult('START${'x' * 9000}THE-REASON', maxChars: 100);
      expect(trimmed, contains('START'));
      expect(trimmed, contains('THE-REASON'));
      expect(trimmed.length, lessThan(200));
    });
  });
}

TraceTurn _turn(int index, List<TraceItem> items, {TokenUsage? usage}) =>
    TraceTurn(index: index, items: items, usage: usage);

TraceToolCall _call(
  String id,
  String name,
  Duration duration, {
  bool isError = false,
}) => TraceToolCall(
  id: id,
  name: name,
  duration: duration,
  isError: isError,
  result: '',
);

TraceToolCall _open(String id, String name) => TraceToolCall(id: id, name: name);
