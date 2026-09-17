import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/remote_capabilities.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/mcp.dart';
import 'package:herdr_pocket/domain/agent/skills.dart';

/// The one command that answers both menus, and the reply it has to understand.
///
/// Two things are being tested here and they fail differently.
///
/// The GENERATED SHELL is tested by asserting on the exact text, because that is
/// where a bug cannot be caught by anything else: `$f` that Dart interpolates
/// becomes an empty string, the command still runs, and the menu still opens —
/// just missing everything. `transport_test`-style fakes cannot see it; only a
/// string assertion can.
///
/// The REPLY is tested against a scripted one, because the parsing rules — the
/// markers, the split between skill lines and config file contents, the
/// three-way outcome — are what the menu's honesty rests on.
class _FakeRunner implements RemoteCommandRunner {
  _FakeRunner(this.stdout);

  String stdout;
  final List<String> commands = <String>[];

  @override
  Future<String> runCommand(String command) async {
    commands.add(command);
    return stdout;
  }
}

/// A reply the way the shell writes one.
String _reply({
  String? home = '/home/u',
  List<String> skillLines = const [],
  Map<String, String> files = const {},
}) {
  final buffer = StringBuffer();
  if (home != null) buffer.writeln('${RemoteCapabilities.homeMarker}\t$home');
  skillLines.forEach(buffer.writeln);
  files.forEach((path, contents) {
    buffer.writeln('${RemoteCapabilities.fileMarker}$path');
    buffer.writeln(contents);
  });
  // The sentinel the real command ends with, plus an exit code: without it the
  // reply reads as truncated, which is a different (and tested) outcome.
  buffer.write('${remoteExitMarker}0');
  return buffer.toString();
}

void main() {
  group('the generated script', () {
    final command = RemoteCapabilities.buildScript(cwd: '/home/u/my project');

    test('is handed to a POSIX shell, whatever the login shell is', () {
      // The bug a real phone found: sshd runs an `exec` request with the
      // user's LOGIN shell, and zsh aborts the whole script on the first
      // unmatched glob. Every root in this command's table is a directory that
      // may not exist, so the wrapper is what makes the command work at all on
      // a zsh machine.
      final wrapped = RemoteCapabilities.buildCommand(cwd: '/home/u');
      expect(wrapped, startsWith('/bin/sh -c '));
      expect(wrapped, contains('SKILL.md'));
      expect(
        wrapped,
        isNot(contains('\n/bin/sh')),
        reason: 'one shell, one level of quoting',
      );
    });

    test('marks config file boundaries with an ESCAPE, not a control byte', () {
      // `printf '\001…'` on the far side. A literal U+0001 in the command string
      // would be printed by printf a second time, and the marker would come back
      // doubled — a menu with no MCP rows and nothing in the log to say why.
      expect(command, contains(r'\001HERDR-FILE\001'));
      expect(command.contains('\u0001'), isFalse);
    });

    test('every number is substituted, and no shell variable is', () {
      expect(command, contains('head -c 262144'));
      expect(command, contains(r'[ "$m" -lt 262144 ]'));
      expect(command, contains(r'[ "$n" -lt 400 ]'));
      // The failure mode this pins: a raw Dart string leaves `$maxConfigBytes`
      // in the command, where the shell expands it to nothing and `head -c ""`
      // errors — silently, because stderr is discarded.
      expect(command, isNot(contains(r'$maxConfigBytes')));
      expect(command, isNot(contains(r'$maxSkills')));
    });

    test('the directory is quoted, so a space in it is not a word break', () {
      expect(command, contains("'/home/u/my project'"));
    });

    test('the project roots are dropped when there is no directory', () {
      // A project glob resolved in the login shell's own directory would list a
      // DIFFERENT project's skills with no sign that anything was wrong.
      final blind = RemoteCapabilities.buildScript(cwd: null);
      expect(blind, isNot(contains("'/'")));
      expect(blind, isNot(contains('.mcp.json')));
      expect(blind, contains('.claude/skills'));
      expect(blind, contains(r'"$H"'));
    });

    test('one command asks for everything, and ends with the sentinel', () {
      // The whole point of the design: two menus, one round trip.
      expect(command, contains('SKILL.md'));
      expect(command, contains('mcp.json'));
      expect(command, contains('config.toml'));
      expect(command, endsWith("printf '$remoteExitMarkerEscape%s' \"\$?\""));
    });
  });

  group('reading the reply', () {
    test('skills become entries, and the home directory rides along', () async {
      final runner = _FakeRunner(
        _reply(
          skillLines: [
            '/home/u/.claude/skills/oh-mem/SKILL.md\tRemember things',
          ],
        ),
      );
      final result = await RemoteCapabilities(runner).probe(
        cwd: '/home/u/proj',
        agent: 'claude',
      );
      expect(result, isA<ProbeFound>());
      final found = result as ProbeFound;
      expect(found.skills.single.name, 'oh-mem');
      expect(found.skills.single.description, 'Remember things');
      expect(found.mcp, isEmpty);
      // The home is never WRITTEN into the command: the roots are relative and
      // the machine supplies its own base, which is what makes the same table
      // work on a machine this app has never seen. The pane's own directory, by
      // contrast, has to be passed — and quoted.
      final sent = runner.commands.single;
      expect(sent, contains(r'"$H"'));
      expect(sent, contains("'/home/u/proj'"));
    });

    test('config contents are attributed and parsed', () async {
      final runner = _FakeRunner(
        _reply(
          files: {
            '/home/u/.pi/agent/mcp.json':
                '{"mcpServers":{"vision":{"command":"uv"}}}',
          },
        ),
      );
      final result =
          await RemoteCapabilities(runner).probe(cwd: null, agent: 'pi')
              as ProbeFound;
      expect(result.mcp.single.name, 'vision');
      expect(result.mcp.single.detail, 'uv');
    });

    test('TWO config files stay two files', () async {
      // The bug this pins was found by running the command against a real
      // machine and reading its output, and no fixture had caught it: the marker
      // was only tested while no file was open, so every config after the first
      // was appended to the first — `jsonDecode` then saw two files in one
      // string, failed, and the menu listed NO MCP servers, on every machine,
      // from a reply that looked perfectly well formed.
      final runner = _FakeRunner(
        _reply(
          files: {
            '/home/u/.pi/agent/mcp.json':
                '{"mcpServers":{"vision":{"command":"uv"}}}',
            '/home/u/.codex/config.toml':
                '[mcp_servers.tradingview]\ncommand = "python"\n',
          },
        ),
      );
      final result = await RemoteCapabilities(runner).probe(
        cwd: null,
        agent: null,
      );
      final found = result as ProbeFound;
      expect(
        found.mcp.map((e) => e.name).toSet(),
        {'vision', 'tradingview'},
        reason: 'one file per marker, not one file holding all of them',
      );
      expect(
        found.mcp.map((e) => e.source).toSet(),
        {'~/.pi/agent/mcp.json', '~/.codex/config.toml'},
      );
    });

    test('a reply that never finished is unreadable, not empty', () {
      // Everything arrived except the sentinel, i.e. the answer is a PREFIX.
      // Reporting it as a complete list is the one thing a menu must not do.
      final runner = _FakeRunner(
        '${RemoteCapabilities.homeMarker}\t/home/u\n'
        '/home/u/.claude/skills/a/SKILL.md\td\n',
      );
      return RemoteCapabilities(runner)
          .probe(cwd: null, agent: 'claude')
          .then((result) => expect(result, isA<ProbeUnreadable>()));
    });

    test('a machine that will not say where its home is is not "empty"', () async {
      final runner = _FakeRunner(_reply(home: null));
      final result = await RemoteCapabilities(runner).probe(cwd: null, agent: null);
      expect(result, isA<ProbeUnreadable>());
    });

    test('nothing found anywhere is ProbeNone, which is its own sentence', () async {
      final runner = _FakeRunner(_reply());
      final result = await RemoteCapabilities(runner).probe(cwd: null, agent: null);
      expect(result, isA<ProbeNone>());
    });

    test('a transport failure is reported, not thrown at the page', () async {
      final result = await RemoteCapabilities(_ThrowingRunner()).probe(
        cwd: null,
        agent: null,
      );
      expect(result, isA<ProbeUnreadable>());
    });

    test('the config of an agent with no skills still opens the menu', () async {
      // The two lists are filtered separately: a codex pane still sees a project
      // `.mcp.json` even though codex has no skills on this machine.
      final runner = _FakeRunner(
        _reply(
          files: {
            '/home/u/proj/.mcp.json': '{"mcpServers":{"shared":{}}}',
          },
        ),
      );
      final result =
          await RemoteCapabilities(runner).probe(cwd: '/home/u/proj', agent: 'codex')
              as ProbeFound;
      expect(result.skills, isEmpty);
      expect(result.mcp.single.name, 'shared');
    });
  });

  group('the table itself', () {
    test('every source is under the home or the project directory', () {
      for (final spec in mcpSources) {
        expect(spec.segments, isNotEmpty);
        expect(
          spec.segments.any((s) => s.isEmpty),
          isFalse,
          reason: '${spec.label} has an empty segment',
        );
      }
    });

    test('skill roots resolve for a project, a home, or both', () {
      final both = resolvedSkillRoots(home: '/h', cwd: '/c');
      expect(both.any((r) => r.$1.projectScoped), isTrue);
      expect(both.any((r) => !r.$1.projectScoped), isTrue);

      final homeOnly = resolvedSkillRoots(home: '/h', cwd: null);
      expect(homeOnly.every((r) => !r.$1.projectScoped), isTrue);
      expect(homeOnly, isNotEmpty);

      expect(resolvedSkillRoots(home: null, cwd: null), isEmpty);
    });
  });
}

class _ThrowingRunner implements RemoteCommandRunner {
  @override
  Future<String> runCommand(String command) async {
    throw HerdrTransportException(
      TransportFailure.unknown,
      'the channel died',
    );
  }
}
