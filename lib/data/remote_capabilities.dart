import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/mcp.dart';
import 'package:herdr_pocket/domain/agent/skills.dart';

/// What the workspace behind a pane can be asked to do: its skills, and its MCP
/// servers.
///
/// ## One command, one round trip
///
/// The two menus (`/` and `@`) are opened on a phone, often on a bad link, and
/// the whole point of the composer is that the network is not part of typing. So
/// asking the machine twice — once for skills, once for MCP — would put two
/// waits behind one keystroke. The command below does both: a `for` loop per
/// skill directory, then a bounded `head -c` of each MCP config, in a single
/// shell invocation whose reply is split on markers.
///
/// ## The three markers
///
///  1. `HERDR_HOME\t<path>` — the home directory, first line. It rides along
///     because the roots are stored RELATIVE to it, and asking in a second round
///     trip for one line would be absurd.
///  2. `<path>\t<description>` — one skill per line, until the first file marker.
///  3. `\u0001HERDR-FILE\u0001<path>` — starts a config file's contents. The
///     control characters are there because a JSON file may legitimately contain
///     the word HERDR-FILE, and a marker that a config file can forge is a
///     marker that splits a file in half.
///
/// Everything that decides what any of it MEANS lives in `domain/agent/`, so the
/// shell half stays loops and `sed` and the naming rules are testable without a
/// machine.
///
/// ## What a failure looks like
///
/// [CapabilitiesUnreadable] rather than an empty list: a menu that shows nothing
/// when it could not look is a menu that lies. See [ProbeResult].
class RemoteCapabilities {
  const RemoteCapabilities(this._runner);

  final RemoteCommandRunner _runner;

  /// Printed as the first line of the reply.
  static const String homeMarker = 'HERDR_HOME';

  /// Starts a config file's contents. See the class comment for why it is not
  /// plain text.
  static const String fileMarker = '\u0001HERDR-FILE\u0001';

  /// The same marker the way `printf` writes it: the control characters are
  /// produced BY printf's `\001` escape rather than carried in the command
  /// string, because a control byte in the middle of a shell command is a byte
  /// nothing else in the chain expects — and because interpolating [fileMarker]
  /// here would print it TWICE (once literally, once from the escape).
  static const String _fileMarkerEscape = r'\001HERDR-FILE\001';

  /// How many skills to take. Past a few hundred the user is typing a query
  /// anyway, and this reply crosses a phone's link.
  static const int maxSkills = 400;

  /// The most bytes of config to read, in total and per file.
  ///
  /// A config can be arbitrarily large (`~/.claude.json` grows with every
  /// project). A truncated JSON file parses as nothing, which costs one roW of
  /// the menu — an acceptable price, and a far better one than pulling megabytes
  /// across a cellular link to populate a list.
  static const int maxConfigBytes = 256 * 1024;

  Future<ProbeResult> probe({required String? cwd, required String? agent}) async {
    final String out;
    try {
      out = await _runner.runCommand(buildCommand(cwd: cwd));
    } on HerdrTransportException catch (e) {
      return ProbeUnreadable(e.message);
    } on Object catch (e) {
      return ProbeUnreadable('$e');
    }

    final (body, exitCode) = splitTrailingSentinel(out);
    if (exitCode == null) {
      // The shell never reached its last line: the reply is a prefix, and a
      // prefix of a capability list is exactly the kind of answer that reads as
      // complete.
      return const ProbeUnreadable('the remote shell did not finish');
    }

    String? home;
    final skillLines = StringBuffer();
    // path -> contents, in the order the files were read.
    final files = <String, StringBuffer>{};
    String? openFile;

    for (final line in body.split('\n')) {
      // THE MARKER IS CHECKED FIRST AND UNCONDITIONALLY. Testing it only while
      // no file was open was a real bug, and one no fixture caught: every config
      // after the first was appended to the first, so `jsonDecode` saw two files
      // in one string and the menu listed no MCP servers at all — on every
      // machine, silently, with a reply that looked perfectly well formed.
      if (line.startsWith(fileMarker)) {
        openFile = line.substring(fileMarker.length).trim();
        files[openFile] = StringBuffer();
        continue;
      }
      if (openFile != null) {
        files[openFile]!.writeln(line);
        continue;
      }
      if (home == null && line.startsWith('$homeMarker\t')) {
        final value = line.substring(homeMarker.length + 1).trim();
        if (value.startsWith('/')) home = value;
        continue;
      }
      skillLines.writeln(line);
    }

    if (home == null) {
      return const ProbeUnreadable('the machine did not say where its home is');
    }

    final skillRootsResolved = resolvedSkillRoots(home: home, cwd: cwd);
    final skills = selectSkills(
      parseSkillProbe(
        skillLines.toString(),
        roots: skillRootsResolved,
      ),
      agent: agent,
    );

    final mcpSourcesResolved = resolvedMcpSources(home: home, cwd: cwd);
    final mcp = <McpEntry>[];
    for (final file in files.entries) {
      mcp.addAll(
        parseMcpFile(file.key, file.value.toString(), sources: mcpSourcesResolved),
      );
    }
    final servers = selectMcpServers(mcp, agent: agent);

    if (skills.isEmpty && servers.isEmpty) return const ProbeNone();
    return ProbeFound(skills: skills, mcp: servers);
  }

  /// The one command this class runs.
  ///
  /// The command as the machine receives it: [buildScript] inside a POSIX shell.
  ///
  /// See `posixShellCommand` for why the wrapper is not optional.
  static String buildCommand({required String? cwd, int maxSkills = maxSkills}) =>
      posixShellCommand(buildScript(cwd: cwd, maxSkills: maxSkills));

  /// The script itself, before the wrapper.
  ///
  /// Split out for the tests: asserting on the script is how the two kinds of
  /// dollar sign stay told apart (`$maxSkills` is Dart's, `$n` is the remote
  /// shell's), and asserting on the command is how the wrapper stays wrapped.
  static String buildScript({required String? cwd, int maxSkills = maxSkills}) {
    final projectDir = _absolute(cwd);
    final buffer = StringBuffer()
      // `cd ~` is the fallback for the sshd configurations that drop HOME — the
      // same two steps the uploader resolves its upload directory with.
      ..writeln(r'H=${HOME:-$(cd ~ && pwd)}')
      ..writeln("printf '$homeMarker\\t%s\\n' \"\$H\"")
      ..writeln('n=0');

    for (final root in skillRoots) {
      // A project root with no usable directory is not probed at all: the
      // command runs in the login shell's own directory, so a `.claude/skills`
      // glob resolving against THAT would list a different project's skills with
      // no sign that anything was wrong.
      if (root.projectScoped && projectDir == null) continue;
      final base = root.projectScoped ? quoteRemotePath(projectDir!) : r'"$H"';
      final dir = '$base/${root.segments.join('/')}';
      final glob = switch (root.shape) {
        SkillShape.skillDir => '$dir/*/SKILL.md',
        SkillShape.commandFile => '$dir/*.md',
      };

      buffer
        ..writeln('for f in $glob; do')
        ..writeln(r'  [ -f "$f" ] || continue')
        // `$n` is the SHELL's counter and is escaped; `$maxSkills` is Dart's and
        // is not. This is Dart before it is shell, and the two kinds of dollar
        // sign have to be told apart inside one string.
        ..writeln('  [ "\$n" -lt $maxSkills ] || break')
        ..writeln(r'  n=$((n+1))');
      if (root.shape == SkillShape.commandFile) {
        buffer.writeln(r'''  printf '%s\t\n' "$f"''');
      } else {
        buffer
          // Only the first `description:` line: a front-matter block that
          // continues on the next line is a paragraph, and a menu row is not a
          // paragraph.
          ..writeln(
            r'''  d=$(sed -n -e 's/^[Dd]escription:[[:space:]]*//p' "$f" 2>/dev/null | head -n 1)''',
          )
          ..writeln(r'''  printf '%s\t%s\n' "$f" "$d"''');
      }
      buffer.writeln('done');
    }

    // ---- MCP configs --------------------------------------------------------
    //
    // The word list is generated, so each path is written the way the shell
    // needs to see it: an absolute project path in single quotes, and a home
    // path with `$H` in double quotes (so a home with a space in it stays one
    // word). `"$H"` is a RAW fragment here — Dart must not interpolate it.
    buffer.write('m=0\nfor f in');
    for (final spec in mcpSources) {
      if (spec.projectScoped && projectDir == null) continue;
      final path = spec.projectScoped
          ? '${quoteRemotePath(projectDir!)}/${spec.segments.join('/')}'
          : '"${r'$H'}"/${spec.segments.join('/')}';
      buffer.write(' $path');
    }
    buffer
      ..writeln('; do')
      ..writeln(r'  [ -f "$f" ] || continue')
      ..writeln('  [ "\$m" -lt $maxConfigBytes ] || break')
      // `tr` because BSD `wc` pads its number with spaces, and the arithmetic
      // below is happier without them.
      ..writeln(r"""  s=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]' || echo 0)""")
      ..writeln(r'  m=$((m+s))')
      ..writeln("  printf '$_fileMarkerEscape%s\\n' \"\$f\"")
      ..writeln('  head -c $maxConfigBytes "\$f" 2>/dev/null')
      ..writeln(r"  printf '\n'")
      ..writeln('done')
      // `true` so the sentinel's exit code is always zero: its PRESENCE is the
      // signal here, because a run of globs and `continue`s has no meaningful
      // code to report.
      ..writeln('true')
      ..write("printf '$remoteExitMarkerEscape%s' \"\$?\"");

    return buffer.toString();
  }
}

/// What the workspace has.
sealed class ProbeResult {
  const ProbeResult();
}

/// At least one of the two lists has something in it.
final class ProbeFound extends ProbeResult {
  const ProbeFound({required this.skills, required this.mcp});

  final List<SkillEntry> skills;
  final List<McpEntry> mcp;

  bool get isEmpty => skills.isEmpty && mcp.isEmpty;
}

/// The machine answered, and there is nothing in either list.
final class ProbeNone extends ProbeResult {
  const ProbeNone();
}

/// The question could not be asked, or the answer did not arrive whole.
final class ProbeUnreadable extends ProbeResult {
  const ProbeUnreadable(this.detail);

  final String detail;
}

/// A directory path, or null when there is nothing to run a glob against.
String? _absolute(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (!trimmed.startsWith('/')) return null;
  return trimmed.endsWith('/') && trimmed.length > 1
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// The probe, wired to the live connection.
///
/// Null is a real answer rather than a loading state, the same way
/// `remoteRunnerProvider` treats a transport that cannot run commands.
final capabilityProvider = Provider<RemoteCapabilities?>(
  (ref) {
    final runner = ref.watch(remoteRunnerProvider);
    return runner == null ? null : RemoteCapabilities(runner);
  },
);
