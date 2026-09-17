import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/remote_capabilities.dart';
import 'package:herdr_pocket/data/remote_files.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/domain/agent/skills.dart';

/// The generated shell, run for real.
///
/// WHY THIS EXISTS. `RemoteCapabilities.buildCommand` produces ~30 lines of
/// generated `sh`, and everything else that tests it asserts on the STRING. A
/// string assertion catches an unescaped `$` — which is how the first version of
/// this command came out silently wrong — but it cannot catch a command that
/// quotes correctly and still does not work: a `sed` that is not on this
/// machine's `sed`, a glob whose quoting stops it expanding, an arithmetic
/// expansion `dash` disagrees with.
///
/// So this runs it. The machine is the developer's own, which makes the checks
/// conditional rather than fixed: what is always asserted is the SHAPE of the
/// reply (a home, a sentinel), and what is asserted when the directory exists is
/// that the probe found a skill the test itself listed by reading the
/// filesystem — an independent answer to the same question.
///
/// No daemon, no sshd, no phone: the only requirement is a POSIX shell, so this
/// runs everywhere the rest of the suite does.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final sh = _shellPath('/bin/sh');
  // THE LOGIN SHELL IS THE ONE THAT MATTERS, and this project's own machine runs
  // the whole suite through zsh. sshd runs an `exec` request with the user's
  // login shell, so a script that only works under `sh` is a script that fails
  // on half the machines it will ever meet — measured, see [posixShellCommand].
  final loginShell = Platform.environment['SHELL'] ?? '/bin/sh';

  String? shellProblem(String? path) =>
      path == null || !File(path).existsSync() ? 'no such shell: $path' : null;

  final skipReason = Platform.isWindows
      ? 'this test drives POSIX shells'
      : shellProblem(sh) ?? shellProblem(loginShell);

  /// Runs [command] the way a shell would, from [directory].
  Future<(String, int)> run(
    String command,
    String directory, {
    String? shell,
  }) async {
    final result = await Process.run(
      shell ?? '/bin/sh',
      ['-c', command],
      workingDirectory: directory,
    );
    return ('${result.stdout}', result.exitCode);
  }

  /// The exit sentinel, or null when the command never reached its last line.
  int? sentinelOf(String out) => splitTrailingSentinel(out).$2;

  group('the capability probe', () {
    test('runs under the LOGIN shell, not just under sh', () async {
      // The regression test for the bug the phone found: the first root that
      // does not exist made zsh abort the whole script, sentinel and all, so the
      // menu could only say "the remote shell did not finish". Every other test
      // here runs the command through `/bin/sh` and would have gone on passing.
      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      final command = RemoteCapabilities.buildCommand(cwd: directory.path);
      final (out, _) = await run(command, directory.path, shell: loginShell);
      expect(
        sentinelOf(out),
        isNotNull,
        reason: 'the script has to survive being run by $loginShell',
      );
      expect(out, contains('${RemoteCapabilities.homeMarker}\t'));
    }, skip: skipReason);

    test('two dozen missing directories abort nothing', () async {
      // The shape of the failure, isolated: EVERY user-scoped root is missing in
      // this temp directory, and an unmatched glob is a fatal error in zsh. The
      // wrapper is what makes this test's whole premise untrue.
      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      for (final shell in [loginShell, '/bin/sh']) {
        final (out, _) = await run(
          RemoteCapabilities.buildCommand(cwd: directory.path),
          directory.path,
          shell: shell,
        );
        expect(
          sentinelOf(out),
          isNotNull,
          reason: 'the probe must finish under $shell even with nothing to find',
        );
      }
    }, skip: skipReason);

    test('the generated shell actually runs and reports its home', () async {
      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      final (out, _) = await run(
        RemoteCapabilities.buildCommand(cwd: directory.path),
        directory.path,
        shell: loginShell,
      );

      final (body, exitCode) = splitTrailingSentinel(out);
      expect(
        exitCode,
        isNotNull,
        reason: 'the command has to reach its own last line',
      );
      expect(
        body,
        contains('${RemoteCapabilities.homeMarker}\t'),
        reason: 'the home is what every relative root is resolved against',
      );
      if (home.isNotEmpty) {
        expect(
          body,
          contains('${RemoteCapabilities.homeMarker}\t$home'),
          reason: "and it has to be THIS machine's home",
        );
      }
    }, skip: skipReason);

    test('a skill that is on disk comes back, with its own description',
        () async {
      // The independent half: the test lists the directory itself. If the probe
      // and the filesystem disagree, one of them is wrong and this fails —
      // which a fixture-based test cannot say, because it would be comparing the
      // parser with the parser.
      final skillsDir = Directory('$home/.claude/skills');
      final expected = skillsDir.existsSync()
          ? skillsDir
                .listSync()
                .whereType<Directory>()
                .where((d) => File('${d.path}/SKILL.md').existsSync())
                .map((d) => d.path.split('/').last)
                .toList()
          : const <String>[];

      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      final (out, _) = await run(
        RemoteCapabilities.buildCommand(cwd: directory.path),
        directory.path,
        shell: loginShell,
      );
      final (body, _) = splitTrailingSentinel(out);
      final roots = resolvedSkillRoots(home: home, cwd: directory.path);
      final parsed = parseSkillProbe(body, roots: roots);
      final names = {for (final entry in parsed) entry.name};

      if (expected.isEmpty) {
        // Nothing to compare against on this machine; the shape checks above
        // still ran.
        return;
      }
      expect(
        names.intersection(expected.toSet()),
        isNotEmpty,
        reason: 'the probe has to find skills that are on disk',
      );
      expect(
        expected.toSet().difference(names),
        isEmpty,
        reason: 'and not silently drop any of them',
      );
    }, skip: skipReason);

    test('the shared .agents store is read off a real machine', () async {
      // The store the table was missing, verified against the filesystem the
      // same way as the claude one: if `~/.agents/skills` is there, every skill
      // in it has to come back. It is the user's MAIN store (30 skills on this
      // machine), so "found none" is not a quiet outcome.
      final shared = Directory('$home/.agents/skills');
      final expected = shared.existsSync()
          ? shared
                .listSync()
                .whereType<Directory>()
                .where((d) => File('${d.path}/SKILL.md').existsSync())
                .map((d) => d.path.split('/').last)
                .toSet()
          : const <String>{};

      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      final (out, _) = await run(
        RemoteCapabilities.buildCommand(cwd: directory.path),
        directory.path,
        shell: loginShell,
      );
      final (body, _) = splitTrailingSentinel(out);
      final parsed = parseSkillProbe(
        body,
        roots: resolvedSkillRoots(home: home, cwd: directory.path),
      );
      final fromShared = {
        for (final entry in parsed)
          if (entry.source == 'agents') entry.name,
      };

      if (expected.isEmpty) return; // nothing to compare on this machine
      expect(
        fromShared,
        containsAll(expected),
        reason: 'the .agents store is not optional: it is where the skills are',
      );
    }, skip: skipReason);

    test('one bad root does not stop the rest of the list', () async {
      // The failure that would be invisible in the string: an unmatched glob
      // aborts the shell (or worse, is passed to `sed` as a filename) and every
      // root after it is skipped. Nothing exists under this temp directory, so
      // the whole user-scoped half of the table is in that position.
      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      final (out, _) = await run(
        RemoteCapabilities.buildCommand(cwd: directory.path),
        directory.path,
      );
      expect(
        splitTrailingSentinel(out).$2,
        isNotNull,
        reason: 'the loops have to survive roots that are not there',
      );
    }, skip: skipReason);

    test('a shell with no HOME still produces a valid reply', () async {
      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      addTearDown(() => directory.deleteSync(recursive: true));

      final result = await Process.run(
        loginShell,
        ['-c', RemoteCapabilities.buildCommand(cwd: directory.path)],
        workingDirectory: directory.path,
        environment: {'PATH': Platform.environment['PATH'] ?? '/usr/bin'},
      );
      final (body, exitCode) = splitTrailingSentinel('${result.stdout}');
      expect(exitCode, isNotNull);
      // `cd ~` is the fallback, and it is what keeps the probe useful on the
      // sshd configurations that do not forward HOME.
      expect(body, contains('${RemoteCapabilities.homeMarker}\t'));
    }, skip: skipReason);

    test('the same helper parses what it printed', () async {
      // The reply is read by the real parser, not by a regex of the test's own:
      // a marker that the command writes and the reader does not recognise is
      // exactly the kind of bug that only shows up as "the menu is empty".
      final project = Directory.current.path;
      final (out, _) = await run(
        RemoteFileIndex.buildCommand(cwd: project),
        project,
        shell: loginShell,
      );
      final (body, exitCode) = splitTrailingSentinel(out);
      expect(exitCode, isNotNull);

      final paths = body.split('\n').where((line) => line.isNotEmpty).toList();
      expect(
        paths,
        contains('pubspec.yaml'),
        reason: 'the listing runs inside this repository, which certainly has one',
      );
      expect(
        paths.any((p) => p.startsWith('lib/')),
        isTrue,
        reason: 'and it lists tracked source, not just the root',
      );
      expect(
        paths.any((p) => p.contains('node_modules')),
        isFalse,
        reason: 'the ignored half of a working tree is not worth carrying',
      );
    }, skip: skipReason);

    test('a directory that is gone is reported as gone, not as empty', () async {
      final directory = Directory.systemTemp.createTempSync('herdr-probe');
      final gone = '${directory.path}/gone';
      final (out, _) = await run(
        RemoteFileIndex.buildCommand(cwd: gone),
        directory.path,
      );
      directory.deleteSync(recursive: true);

      final (body, _) = splitTrailingSentinel(out);
      expect(
        body.trim(),
        RemoteFileIndex.noDirectoryMarker,
        reason: '"this folder is empty" and "this folder is gone" are different'
            ' sentences, and a file picker must not confuse them',
      );
    }, skip: skipReason);
  });
}

/// Whether this machine has [path], for an honest skip reason rather than an
/// exception thrown from a test that cannot run.
String? _shellPath(String path) => File(path).existsSync() ? path : null;
