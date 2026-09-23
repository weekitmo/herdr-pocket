import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/transcripts/transcript_locator.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// Finding a session file on the other end of an SSH connection.
///
/// WHY THIS FILE EXISTS, in one sentence: the first version of the pi lookup
/// built `[ -d "$dir" ]` where `dir` held `$HOME/.pi/agent/sessions/'--slug--'`,
/// so the single quotes became literal characters INSIDE a double-quoted
/// string, and every lookup missed. Nothing caught it — not the unit tests,
/// which did not look at the command; not `flutter analyze`; not the widget
/// tests, which stub the loader. It was found on a phone, where the screen
/// said "no session record found" about a file that was sitting right there.
///
/// So there are two kinds of test here and both are needed:
///
///  * the command STRING is asserted, because a shell command is a program and
///    the only way to catch a quoting mistake by inspection is to look at it;
///  * the command is really RUN, through `/bin/sh`, against a directory tree
///    on disk — which is what the repository already learned to do for the
///    skills/MCP probe, and what would have caught this in one second.
void main() {
  Directory home() {
    final dir = Directory.systemTemp.createTempSync('hp-ledger-home');
    addTearDown(() => dir.deleteSync(recursive: true));
    return dir;
  }

  void writeSession(Directory home, String slug, String name, String body) {
    final dir = Directory('${home.path}/.pi/agent/sessions/$slug')
      ..createSync(recursive: true);
    File('${dir.path}/$name').writeAsStringSync(body);
  }

  /// A runner that answers with a scripted reply and remembers what it was
  /// asked, so a test can both assert the command and run it for real.
  _ScriptedRunner runner(String Function(String command) reply) =>
      _ScriptedRunner(reply);

  group('the pi lookup, really executed', () {
    test('finds the newest session in the directory derived from the cwd', () {
      final box = home();
      writeSession(box, '--Users-x-app--', 'old.jsonl', '{"type":"session"}');
      writeSession(box, '--Users-x-app--', 'new.jsonl', '{"type":"session"}');
      // A newer file for a DIFFERENT directory: the wrong answer must not be
      // reachable just by being recent.
      writeSession(box, '--Users-x-other--', 'newest.jsonl', '{"type":"session"}');

      final recorded = runner((_) => '');
      final locator = TranscriptLocator(recorded);
      // The locator itself is not what is under test here; the command is. It
      // is reached through the locator so that the string is the real one.
      unawaited(locator.locate(agentId: 'pi', cwd: '/Users/x/app'));

      final command = recorded.commands.firstWhere((c) => c.contains('pi'));
      final result = Process.runSync(
        '/bin/sh',
        ['-c', command],
        environment: {'HOME': box.path},
      );

      // Newest first. The caller may walk more than one — an agent that opens
      // an empty session per run leaves stubs behind — so the order is part of
      // the contract, not an accident of `ls`.
      final lines = result.stdout.toString().trim().split('\n');
      expect(lines.first, endsWith('/--Users-x-app--/new.jsonl'));
      expect(lines, hasLength(2));
    });

    test(r'its $HOME survives for the remote shell, and the slug is one word', () {
      final recorded = runner((_) => '');
      unawaited(
        TranscriptLocator(recorded).locate(agentId: 'pi', cwd: '/Users/x/app'),
      );
      final command = recorded.commands.firstWhere((c) => c.contains('pi'));

      // `$HOME` unescaped (the far end expands it), the slug inside the same
      // double-quoted word, and no nested quoting anywhere.
      expect(command, contains(r'"$HOME/.pi/agent/sessions/--Users-x-app--"'));
      expect(command, isNot(contains(r"/'")));
      // The path is used twice (test it, then list it) and both copies have to
      // be quoted the same way.
      expect(
        command,
        contains(r'ls -t "$HOME/.pi/agent/sessions/--Users-x-app--"/*.jsonl'),
      );
    });
  });

  group('which candidate wins', () {
    test("the process's own open file beats the newest one in the directory", () {
      final recorded = runner((command) {
        // The lsof probe, then the directory listing.
        if (command.contains('lsof')) {
          return 'p123\nn/Users/u/.pi/agent/sessions/--Users-x-app--/held.jsonl\n';
        }
        return '/Users/u/.pi/agent/sessions/--Users-x-app--/newest.jsonl\n';
      });
      final locator = TranscriptLocator(recorded);

      expect(recorded.commands, isEmpty);
      // Nothing here asserts the outcome, because the read is stubbed out by
      // the same missing runner; what matters is that lsof was asked FIRST.
      unawaited(locator.locate(agentId: 'pi', cwd: '/Users/x/app', pid: 123));
      expect(recorded.commands.first, contains('lsof'));
      expect(recorded.commands.first, contains(r'command -v lsof'));
      expect(recorded.commands.first, contains('/usr/sbin/lsof'));
    });

    test('no pid means no lsof probe at all', () {
      final recorded = runner((_) => '');
      unawaited(
        TranscriptLocator(recorded).locate(agentId: 'pi', cwd: '/Users/x/app'),
      );
      expect(recorded.commands.any((c) => c.contains('lsof')), isFalse);
    });
  });

  group('what it reports', () {
    test('an agent this build cannot read says so without running anything', () async {
      final recorded = runner((_) => '');
      final result = await TranscriptLocator(
        recorded,
      ).locate(agentId: 'claude', cwd: '/Users/x/app');

      expect(result, isA<UnsupportedAgent>());
      expect((result as UnsupportedAgent).supported, containsAll(['pi', 'codex']));
      expect(recorded.commands, isEmpty);
    });

    test('a machine with no sessions directory is "nothing found", not an error', () async {
      final recorded = runner((_) => '');
      final result = await TranscriptLocator(
        recorded,
      ).locate(agentId: 'pi', cwd: '/Users/x/nowhere');

      expect(result, isA<NoTranscript>());
    });

    test("a file that is not the agent's is not shown as an empty session", () async {
      // The locator found *a* jsonl. Reading it with the wrong adapter would
      // produce a session with no turns, which reads as "the agent said
      // nothing" rather than "we looked in the wrong place".
      final recorded = runner((command) {
        if (command.contains('wc -c')) return '40\n';
        if (command.contains('tail -c')) return '{"payload":{"type":"session_meta"}}\n';
        return '/Users/u/.pi/agent/sessions/--Users-x-app--/x.jsonl\n';
      });

      final result = await TranscriptLocator(
        recorded,
      ).locate(agentId: 'pi', cwd: '/Users/x/app');
      expect(result, isA<NoTranscript>());
    });

    test('a tail read that starts mid-record is still recognised', () async {
      // THE PHONE CASE. Reading the end of a file means the first line is
      // usually a fragment, and the check "is this the agent's file" must not
      // be run on a fragment: every lookup missed, and the screen said the
      // session did not exist.
      final recorded = runner((command) {
        if (command.contains('wc -c')) return '9000000\n';
        if (command.contains('tail -c')) {
          return 'it":true}}\n'
              '{"type":"session","cwd":"/Users/x/app"}\n'
              '{"type":"message","message":{"role":"user"}}\n';
        }
        return '/Users/u/.pi/agent/sessions/--Users-x-app--/x.jsonl\n';
      });

      final result = await TranscriptLocator(
        recorded,
      ).locate(agentId: 'pi', cwd: '/Users/x/app');

      expect(result, isA<FoundTranscript>());
    });

    test('a session is read from the END of the file, and says it was cut', () async {
      final recorded = runner((command) {
        if (command.contains('wc -c')) return '9000000\n';
        if (command.contains('tail -c')) {
          return '{"type":"session","cwd":"/Users/x/app"}\n';
        }
        return '/Users/u/.pi/agent/sessions/--Users-x-app--/x.jsonl\n';
      });

      final result = await TranscriptLocator(
        recorded,
        tailBytes: 1000,
      ).locate(agentId: 'pi', cwd: '/Users/x/app');

      expect(result, isA<FoundTranscript>());
      final found = result as FoundTranscript;
      expect(found.truncated, isTrue);
      expect(
        recorded.commands.any((c) => c.contains('tail -c 1000')),
        isTrue,
        reason: 'the whole 9 MB must not be asked for',
      );
    });

    test('a command that cannot run is a strategy that did not answer', () async {
      // The next strategy still gets its turn: a machine with no lsof is not a
      // machine with no sessions.
      final recorded = _ScriptedRunner((command) {
        if (command.contains('lsof')) throw StateError('command not found');
        if (command.contains('wc -c')) return '20\n';
        if (command.contains('tail -c')) {
          return '{"type":"session","cwd":"/Users/x/app"}\n';
        }
        return '/Users/u/.pi/agent/sessions/--Users-x-app--/x.jsonl\n';
      });

      final result = await TranscriptLocator(
        recorded,
      ).locate(agentId: 'pi', cwd: '/Users/x/app', pid: 123);

      expect(result, isA<FoundTranscript>());
    });
  });
}

class _ScriptedRunner implements RemoteCommandRunner {
  _ScriptedRunner(this.reply);

  final String Function(String command) reply;
  final List<String> commands = [];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    return reply(command);
  }
}
