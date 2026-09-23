/// Runs the transcript adapters over real session files on this machine.
///
/// WHY THIS EXISTS: the formats are another program's private files, and the
/// only way to know an adapter still reads them is to point it at a real one.
/// This is the check to run after an agent updates — a fixture can only prove
/// the parser handles what we already knew about.
///
///   dart run tool/ledger_probe.dart            # newest file per agent
///   dart run tool/ledger_probe.dart PATH       # one file, whatever it is
library;

import 'dart:io';
import 'package:herdr_pocket/data/transcripts/transcript_adapter.dart';
import 'package:herdr_pocket/data/transcripts/transcript_locator.dart';
import 'package:herdr_pocket/data/transcripts/transcript_registry.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/transcript/ledger_stats.dart';
import 'package:herdr_pocket/domain/transcript/ledger_text.dart';
import 'package:herdr_pocket/domain/transcript/session_ledger.dart';

void main(List<String> args) async {
  if (args.length >= 2 && args.first == '--locate') {
    await locate(args[1], args.length > 2 ? args[2] : 'pi');
    return;
  }
  if (args.isNotEmpty) {
    for (final path in args) {
      final file = File(path);
      if (!file.existsSync()) {
        stderr.writeln('no such file: $path');
        continue;
      }
      report(path, file.readAsLinesSync());
    }
    return;
  }

  final home = Platform.environment['HOME'] ?? '';
  for (final adapter in transcriptAdapters) {
    final newest = _newestFor(adapter, home);
    if (newest == null) {
      stdout.writeln('${adapter.agentId}: no session file found under $home');
      continue;
    }
    report('${adapter.agentId}  ${newest.path}', newest.readAsLinesSync());
  }
}

File? _newestFor(TranscriptAdapter adapter, String home) {
  final roots = switch (adapter.agentId) {
    'pi' => ['$home/.pi/agent/sessions'],
    'codex' => ['$home/.codex/sessions'],
    _ => <String>[],
  };
  File? newest;
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      if (newest == null || entity.statSync().modified.isAfter(newest.statSync().modified)) {
        newest = entity;
      }
    }
  }
  return newest;
}

/// Runs the locator exactly as the app does, but against the local machine.
Future<void> locate(String cwd, String agent) async {
  final shell = _LocalShell();
  final result = await TranscriptLocator(shell).locate(agentId: agent, cwd: cwd);
  stdout.writeln('locate agent=$agent cwd=$cwd');
  for (final command in shell.commands) {
    stdout.writeln('  \$ $command');
  }
  switch (result) {
    case UnsupportedAgent(:final agentId):
      stdout.writeln('  => unsupported agent $agentId');
    case NoTranscript():
      stdout.writeln('  => nothing found');
    case UnreadableTranscript():
      stdout.writeln('  => the lookup itself went wrong');
    case FoundTranscript(:final location, :final parse, :final truncated):
      stdout.writeln('  => ${location.path} (${location.source.name})'
          ' truncated=$truncated');
      switch (parse) {
        case UnusableTranscript(:final detail):
          stdout.writeln('     unusable: $detail');
        case ParsedTranscript(:final session):
          stdout.writeln('     turns=${session.turns.length} '
              'skipped=${session.skippedLines} model=${session.model}');
      }
  }
}

/// Prints what the ledger would draw, as text.
void report(String label, List<String> lines) {
  final adapter = adapterForLines(lines);
  stdout.writeln('\n${'=' * 72}\n$label');
  if (adapter == null) {
    stdout.writeln('  !! no adapter recognises this file');
    return;
  }

  final parse = adapter.parse(lines);
  switch (parse) {
    case UnusableTranscript(:final detail):
      stdout.writeln('  !! unusable: $detail');
    case ParsedTranscript(:final session):
      final summary = summarize(
        session.turns,
        reported: session.reportedUsage,
      );
      stdout
        ..writeln('  agent=${session.agentId} model=${session.model ?? '?'} '
            'cwd=${session.cwd ?? '?'}')
        ..writeln('  turns=${summary.turns} calls=${summary.toolCalls} '
            'failures=${summary.toolFailures} open=${summary.openCalls} '
            'busy=${formatDuration(summary.toolBusy)} '
            'skipped=${session.skippedLines}')
        ..writeln('  usage=${_usage(summary.usage)} '
            'window=${summary.contextWindow ?? '?'}');

      final rows = toolStats(session.turns);
      if (rows.isNotEmpty) {
        stdout.writeln('  ${'tool'.padRight(34)}n     median  busy     ✗');
        for (final row in rows.take(12)) {
          stdout.writeln(
            '  ${row.name.padRight(34)}'
            '${row.count.toString().padLeft(3)}  '
            '${formatDuration(row.median).padLeft(7)} '
            '${formatDuration(row.total).padLeft(8)} '
            '${row.failures == 0 ? '' : row.failures}',
          );
        }
      }

      for (final turn in session.turns.take(3)) {
        stdout.writeln('  ── turn ${turn.index} '
            '${turn.startedAt == null ? '' : formatClock(turn.startedAt!)} '
            '${turn.usage == null ? '' : _usage(turn.usage)}');
        if (turn.prompt case final prompt?) {
          stdout.writeln('     user: ${oneLinePreview(prompt, maxChars: 60)}');
        }
        for (final item in turn.items.take(6)) {
          stdout.writeln('     ${_item(item)}');
        }
        if (turn.items.length > 6) {
          stdout.writeln('     … ${turn.items.length - 6} more');
        }
      }
  }
}

String _item(LedgerItem item) => switch (item) {
  LedgerText(:final text) => 'assistant: ${oneLinePreview(text, maxChars: 60)}',
  LedgerThinking(:final text) => 'thinking ${text.length} chars',
  LedgerNote(:final text) => 'note: ${oneLinePreview(text, maxChars: 60)}',
  LedgerToolCall(:final name, :final duration, :final isError, :final arguments) =>
    'tool $name  ${duration == null ? 'open' : formatDuration(duration)}'
        '${isError == true ? ' FAILED' : ''}'
        '${arguments.isEmpty ? '' : '  ${oneLinePreview(arguments, maxChars: 40)}'}',
};

String _usage(TokenUsage? usage) {
  if (usage == null) return '—';
  final parts = <String>[
    if (usage.input case final v?) 'in ${compactCount(v)}',
    if (usage.output case final v?) 'out ${compactCount(v)}',
    if (usage.cacheRead case final v?) 'cache ${compactCount(v)}',
    if (usage.reasoning case final v?) 'reason ${compactCount(v)}',
    if (usage.total case final v?) 'total ${compactCount(v)}',
  ];
  return parts.join(' ');
}

// --- `dart run tool/ledger_probe.dart --locate <cwd> [agent]` ---------------
//
// Runs the REAL locator against this machine, with a local shell standing in
// for the SSH connection, and prints every command it issued. This is the tool
// for "the phone says it found nothing" — it reproduces the app's own code path
// without a phone, a daemon or a network.

/// A runner that shells out locally instead of over SSH.
class _LocalShell implements RemoteCommandRunner {
  final List<String> commands = [];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    final result = Process.runSync('/bin/sh', ['-c', command]);
    return result.stdout.toString();
  }
}
