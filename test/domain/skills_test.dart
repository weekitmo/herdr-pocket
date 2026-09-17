import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/skills.dart';

/// Reading a machine's skills out of its directories.
///
/// The rules under test are the ones a probe cannot check by itself: which root
/// a file belongs to (roots nest), what the skill is called (it depends on the
/// shape the root was declared with), and what happens when the agent the pane
/// runs has nothing of its own.
void main() {
  const home = '/home/u';
  const cwd = '/home/u/proj';
  final roots = resolvedSkillRoots(home: home, cwd: cwd);

  List<SkillEntry> parse(String stdout) =>
      parseSkillProbe(stdout, roots: roots);

  group('naming and attribution', () {
    test('a skill directory is named by its directory', () {
      final entries = parse('/home/u/.claude/skills/oh-mem/SKILL.md\tRemember\n');
      expect(entries.single.name, 'oh-mem');
      expect(entries.single.description, 'Remember');
      expect(entries.single.source, 'claude');
      expect(entries.single.projectScoped, isFalse);
    });

    test('a command file is named by its basename', () {
      final entries = parse('/home/u/.claude/commands/review.md\t\n');
      expect(entries.single.name, 'review');
      expect(entries.single.description, isEmpty);
    });

    test('nested roots do not steal each other', () {
      // `.pi/skills` and `.pi/agent/skills` are both live, and longest-prefix
      // attribution is what stops the second one's files being read as if the
      // first one's; a name read from the wrong segment would be `agent`.
      final entries = parse('/home/u/.pi/agent/skills/oh-mem/SKILL.md\td\n');
      expect(entries.single.name, 'oh-mem');
      expect(entries.single.source, 'pi');
    });

    test('a project skill is labelled as one', () {
      final entries = parse('/home/u/proj/.claude/skills/deploy/SKILL.md\td\n');
      expect(entries.single.name, 'deploy');
      expect(entries.single.source, 'claude · project');
      expect(entries.single.projectScoped, isTrue);
    });

    test('a file under no known root is dropped, not guessed at', () {
      expect(parse('/somewhere/else/skills/x/SKILL.md\td\n'), isEmpty);
    });

    test('a file that does not match its root shape is dropped', () {
      // A `SKILL.md` one level too high, or a stray file in a command directory.
      expect(parse('/home/u/.claude/skills/README.md\td\n'), isEmpty);
      expect(parse('/home/u/.claude/commands/sub/x.md\td\n'), isEmpty);
    });

    test('a relative path is refused', () {
      // Everything the probe prints is absolute; anything else is a reply we do
      // not understand, and a guessed source is worse than a missing row.
      expect(parse('.claude/skills/x/SKILL.md\td\n'), isEmpty);
    });

    test('a long description is clipped', () {
      final entries = parseSkillProbe(
        '/home/u/.claude/skills/x/SKILL.md\t${'a' * 400}\n',
        roots: roots,
        maxDescription: 20,
      );
      expect(entries.single.description.length, 21);
      expect(entries.single.description, endsWith('…'));
    });

    test('blank lines and a trailing newline change nothing', () {
      expect(parse('\n\n'), isEmpty);
    });
  });

  group('the shared store', () {
    test('.agents/skills belongs to EVERY agent', () {
      // It is the agent-agnostic convention — no `kinds` in the table — and on
      // this machine it is the user's main store (30 skills, all with a
      // SKILL.md). The first version of the filter dropped it for every NAMED
      // agent, which is a whole store invisible for no stated reason.
      final entries = parse('/home/u/.agents/skills/code-review/SKILL.md\td\n');
      expect(entries.single.source, 'agents');
      for (final agent in ['claude', 'codex', 'dsh', 'pi', 'grok', 'unknown-cli']) {
        expect(
          selectSkills(entries, agent: agent).map((e) => e.name),
          ['code-review'],
          reason: '$agent must see the shared store',
        );
      }
    });

    test('a project .agents store beats the user one', () {
      final entries = parse(
        '/home/u/.agents/skills/deploy/SKILL.md\tuser copy\n'
        '/home/u/proj/.agents/skills/deploy/SKILL.md\tproject copy\n',
      );
      final selected = selectSkills(entries, agent: 'codex');
      expect(selected.single.description, 'project copy');
      expect(selected.single.projectScoped, isTrue);
    });

    test('dsh reads its own project directory too', () {
      // Two entries on purpose: with only the .dsh one there is nothing for a
      // non-dsh agent to see, and the "show everything rather than an empty
      // menu" fallback would answer for the filter instead of it being tested.
      final entries = parse(
        '/home/u/.agents/skills/shared/SKILL.md\td\n'
        '/home/u/proj/.dsh/skills/thing/SKILL.md\td\n',
      );
      expect(
        selectSkills(entries, agent: 'dsh').map((e) => e.name),
        ['thing', 'shared'],
        reason: "a project skill sorts first, and the shared store is dsh's too",
      );
      expect(
        selectSkills(entries, agent: 'codex').map((e) => e.name),
        ['shared'],
        reason: "the .dsh root names its owners, and codex is not one",
      );
    });
  });

  group('which skills an agent sees', () {
    test("the pane's own agent wins", () {
      final entries = parse(
        '/home/u/.claude/skills/alpha/SKILL.md\t\n'
        '/home/u/.pi/agent/skills/beta/SKILL.md\t\n',
      );
      expect(selectSkills(entries, agent: 'pi').map((e) => e.name), ['beta']);
      expect(selectSkills(entries, agent: 'claude').map((e) => e.name), ['alpha']);
    });

    test('an agent with nothing of its own shows everything else', () {
      // The fallback: agent detection lags, and an empty menu on a machine full
      // of skills reads as "this app cannot find your skills".
      final entries = parse('/home/u/.claude/skills/alpha/SKILL.md\t\n');
      expect(selectSkills(entries, agent: 'grok').map((e) => e.name), ['alpha']);
    });

    test('an unknown agent kind shows everything', () {
      final entries = parse('/home/u/.claude/skills/alpha/SKILL.md\t\n');
      expect(selectSkills(entries, agent: null).map((e) => e.name), ['alpha']);
    });

    test('a project skill beats a user skill of the same name', () {
      final entries = parse(
        '/home/u/.claude/skills/deploy/SKILL.md\tuser copy\n'
        '/home/u/proj/.claude/skills/deploy/SKILL.md\tproject copy\n',
      );
      final selected = selectSkills(entries, agent: 'claude');
      expect(selected, hasLength(1));
      expect(selected.single.description, 'project copy');
      expect(selected.single.projectScoped, isTrue);
    });

    test('the empty query order is stable and project-first', () {
      final entries = parse(
        '/home/u/.claude/skills/zeta/SKILL.md\t\n'
        '/home/u/.claude/skills/alpha/SKILL.md\t\n'
        '/home/u/proj/.claude/skills/omega/SKILL.md\t\n',
      );
      expect(
        selectSkills(entries, agent: 'claude').map((e) => e.name),
        ['omega', 'alpha', 'zeta'],
      );
    });
  });
}
