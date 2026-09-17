/// Where the agents on the user's machine keep their skills, and how the list
/// is read off that machine.
///
/// ## Why the filesystem
///
/// herdr has no skills API — enumerated against 0.9.0, its whole method surface
/// has `agent.prompt`, `agent.read` and a plugin-command call, and nothing that
/// lists what an agent can be asked to do (`server.agent_manifests` returns
/// detection rules only). The skills are FILES on the machine, in per-agent
/// directories, and this app already has a shell on that machine. So the menu
/// reads the directories.
///
/// ## And why that is not a hack
///
/// It is the same channel and the same reasoning as the Files and Git pages: the
/// daemon has no filesystem API either, and the answer there was to run the same
/// commands the desktop tools run. A skill is a directory with a `SKILL.md` in
/// it; listing it is `ls`, and no one needs an interface for `ls`.
///
/// ## Unknown agents are cheap, wrong ones are not
///
/// The roots below are grouped by the agent they belong to, and the composer
/// asks for the pane's own agent first. Several entries are for agents this
/// workspace has never had installed — an absent directory costs one failed glob
/// inside a single round trip, so probing for them is free, and it is what makes
/// the menu work on a machine nobody here has seen. What would NOT be free is
/// guessing at a path that exists and holds something else, so an unverified
/// root is only ever added with the agent's own directory as its parent.
library;

/// How the entries under a root are shaped.
enum SkillShape {
  /// `<root>/<name>/SKILL.md` — the convention every one of these agents
  /// follows, verified on disk for claude, dsh, pi, codex, grok, cursor and
  /// opencode.
  skillDir,

  /// `<root>/<name>.md` — an older convention that predates skills and is still
  /// where hand-written slash commands live.
  commandFile,
}

/// One directory that may hold skills.
class SkillRoot {
  const SkillRoot({
    required this.id,
    required this.segments,
    required this.shape,
    this.kinds = const {},
    this.projectScoped = false,
    this.verified = false,
  });

  /// What the menu shows as the entry's origin, e.g. `claude`.
  final String id;

  /// Path segments under the base directory — the home for a user root, the
  /// pane's working directory for a project root.
  final List<String> segments;

  final SkillShape shape;

  /// Agent ids (`pane.list`'s `agent`) this root belongs to. Empty means "any
  /// agent" — used for the roots that are shared, not for ones we are guessing
  /// at.
  final Set<String> kinds;

  /// Resolved under the pane's directory rather than the user's home. Project
  /// skills win over user ones with the same name — that is what a project
  /// override means everywhere else.
  final bool projectScoped;

  /// Seen on a real machine while writing this. The unverified ones are for
  /// agents nobody here runs; they are probed anyway because a missing
  /// directory is free, and they are commented as what they are.
  final bool verified;

  String get label => projectScoped ? '$id · project' : id;
}

/// Every root, project-scoped first in source order.
///
/// The order is the tie-break when the probe is sorted, so a project skill and a
/// user skill with one name both stay visible rather than one silently winning.
const List<SkillRoot> skillRoots = [
  // ---- project-scoped: the pane's own working directory -------------------
  SkillRoot(
    // THE SHARED ONE, and the one that was missing. `.agents/skills` is the
    // agent-agnostic convention — no `kinds`, so it belongs to every agent —
    // and on this machine it is the user's MAIN store: 30 skills, every single
    // one of them a `<name>/SKILL.md`. Measured before it was added, which is
    // the only reason this table is allowed to have rows in it.
    id: 'agents',
    segments: ['.agents', 'skills'],
    shape: SkillShape.skillDir,
    projectScoped: true,
    verified: true,
  ),
  SkillRoot(
    id: 'claude',
    segments: ['.claude', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'claude', 'qwen', 'kimi', 'droid', 'hermes', 'copilot'},
    projectScoped: true,
  ),
  SkillRoot(
    id: 'dsh',
    segments: ['.dsh', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'dsh'},
    projectScoped: true,
  ),
  SkillRoot(
    id: 'pi',
    segments: ['.pi', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'pi', 'omp'},
    projectScoped: true,
  ),
  SkillRoot(
    id: 'codex',
    segments: ['.codex', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'codex'},
    projectScoped: true,
  ),
  SkillRoot(
    id: 'grok',
    segments: ['.grok', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'grok'},
    projectScoped: true,
  ),
  SkillRoot(
    id: 'cursor',
    segments: ['.cursor', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'cursor'},
    projectScoped: true,
    verified: true,
  ),
  SkillRoot(
    id: 'opencode',
    segments: ['.opencode', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'opencode', 'kilo'},
    projectScoped: true,
  ),
  SkillRoot(
    id: 'claude',
    segments: ['.claude', 'commands'],
    shape: SkillShape.commandFile,
    kinds: {'claude', 'qwen', 'kimi', 'droid', 'hermes', 'copilot'},
    projectScoped: true,
  ),

  // ---- user-scoped: the home directory -----------------------------------
  SkillRoot(
    // The shared store again, one level up. Same convention as the project
    // root, and the same 30 skills when nothing in the project overrides them.
    id: 'agents',
    segments: ['.agents', 'skills'],
    shape: SkillShape.skillDir,
    verified: true,
  ),
  SkillRoot(
    id: 'claude',
    segments: ['.claude', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'claude', 'qwen', 'kimi', 'droid', 'hermes', 'copilot'},
    verified: true,
  ),
  SkillRoot(
    // The older half of the same idea: hand-written slash commands, one file
    // each. Still where a lot of people keep the one they use every day.
    id: 'claude',
    segments: ['.claude', 'commands'],
    shape: SkillShape.commandFile,
    kinds: {'claude', 'qwen', 'kimi', 'droid', 'hermes', 'copilot'},
    verified: true,
  ),
  SkillRoot(
    id: 'dsh',
    segments: ['.dsh', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'dsh'},
    verified: true,
  ),
  SkillRoot(
    id: 'pi',
    segments: ['.pi', 'agent', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'pi', 'omp'},
    verified: true,
  ),
  SkillRoot(
    id: 'pi',
    segments: ['.pi', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'pi', 'omp'},
  ),
  SkillRoot(
    id: 'codex',
    segments: ['.codex', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'codex'},
    verified: true,
  ),
  SkillRoot(
    id: 'codex',
    segments: ['.codex', 'prompts'],
    shape: SkillShape.commandFile,
    kinds: {'codex'},
  ),
  SkillRoot(
    id: 'grok',
    segments: ['.grok', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'grok'},
    verified: true,
  ),
  SkillRoot(
    id: 'cursor',
    segments: ['.cursor', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'cursor'},
    verified: true,
  ),
  SkillRoot(
    id: 'opencode',
    segments: ['.config', 'opencode', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'opencode', 'kilo'},
    verified: true,
  ),
  SkillRoot(
    id: 'opencode',
    segments: ['.config', 'opencode', 'skill'],
    shape: SkillShape.skillDir,
    kinds: {'opencode', 'kilo'},
  ),
  // Agents nobody here runs. Each parent directory is the tool's own, so a hit
  // is either a real skill or nothing at all.
  SkillRoot(
    id: 'copilot',
    segments: ['.copilot', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'copilot'},
  ),
  SkillRoot(
    id: 'hermes',
    segments: ['.hermes', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'hermes'},
  ),
  SkillRoot(
    id: 'qwen',
    segments: ['.qwen', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'qwen'},
  ),
  SkillRoot(
    id: 'kimi',
    segments: ['.kimi', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'kimi'},
  ),
  SkillRoot(
    id: 'droid',
    segments: ['.droid', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'droid'},
  ),
  SkillRoot(
    id: 'omp',
    segments: ['.omp', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'omp'},
  ),
  SkillRoot(
    id: 'mastracode',
    segments: ['.mastracode', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'mastracode'},
  ),
  SkillRoot(
    id: 'antigravity',
    segments: ['.antigravity', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'antigravity-cli'},
  ),
  SkillRoot(
    id: 'qoder',
    segments: ['.qoder', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'qodercli'},
  ),
  SkillRoot(
    id: 'devin',
    segments: ['.devin', 'skills'],
    shape: SkillShape.skillDir,
    kinds: {'devin'},
  ),
];

/// One skill, as the menu shows it.
class SkillEntry {
  const SkillEntry({
    required this.name,
    required this.description,
    required this.source,
    required this.path,
    required this.projectScoped,
  });

  /// The name a pick inserts after the slash.
  final String name;

  /// The `description:` line from the skill's front matter, or empty.
  final String description;

  /// Where it came from, for the row's secondary text (`claude · project`).
  final String source;

  /// The file it was read from. Kept because a menu row that cannot be traced
  /// back to a file is a row nobody can debug.
  final String path;

  final bool projectScoped;

  @override
  String toString() => 'SkillEntry($name, $source)';
}

/// The absolute root directory for [root], given the two base directories.
String? skillRootPath(
  SkillRoot root, {
  required String? home,
  required String? cwd,
}) {
  final base = root.projectScoped ? cwd : home;
  if (base == null || base.isEmpty) return null;
  final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return '$trimmed/${root.segments.join('/')}';
}

/// Every root that resolves to an absolute path, in table order.
List<(SkillRoot, String)> resolvedSkillRoots({
  required String? home,
  required String? cwd,
}) => [
  for (final root in skillRoots)
    if (skillRootPath(root, home: home, cwd: cwd) case final path?) (root, path),
];

/// Parses the probe's output into entries.
///
/// One line per skill: `<absolute path of the file>\t<description>`. The path
/// carries everything else — which root found it, and therefore its name and its
/// origin — so the shell side stays a `for` loop with a `sed` in it and all the
/// interpretation happens here where it can be tested.
///
/// A line whose path belongs to none of [roots] is DROPPED rather than shown
/// with a guessed origin: the command only ever globs the roots we asked for,
/// so such a line means the two sides disagree about the table, and inventing a
/// source for it would hide that.
List<SkillEntry> parseSkillProbe(
  String stdout, {
  required List<(SkillRoot, String)> roots,
  int maxDescription = 160,
  int maxEntries = 400,
}) {
  final entries = <SkillEntry>[];
  for (final raw in stdout.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;

    final tab = line.indexOf('\t');
    final path = tab < 0 ? line : line.substring(0, tab);
    final description = tab < 0 ? '' : line.substring(tab + 1);
    if (!path.startsWith('/')) continue;

    final match = _rootOf(path, roots);
    if (match == null) continue;
    final (root, rootPath) = match;

    final name = _nameWithinShape(path, rootPath, root.shape);
    if (name == null || name.isEmpty) continue;
    if (entries.length >= maxEntries) break;

    entries.add(
      SkillEntry(
        name: name,
        description: _clip(_cleanDescription(description), maxDescription),
        source: root.label,
        path: path,
        projectScoped: root.projectScoped,
      ),
    );
  }
  return entries;
}

/// The root a file path belongs to, longest prefix first.
///
/// Longest first because roots nest: `.pi/skills` and `.pi/agent/skills` are
/// both live, and a file under the second one must not be attributed to the
/// first (which would also mangle its name, since the name is read from the
/// segment that follows the root).
(SkillRoot, String)? _rootOf(String path, List<(SkillRoot, String)> roots) {
  (SkillRoot, String)? best;
  for (final candidate in roots) {
    if (!path.startsWith('${candidate.$2}/')) continue;
    if (best == null || candidate.$2.length > best.$2.length) best = candidate;
  }
  return best;
}

/// The skill's name, read out of the path according to the root's shape.
String? _nameWithinShape(String path, String rootPath, SkillShape shape) {
  final relative = path.substring(rootPath.length + 1);
  final parts = relative.split('/');
  return switch (shape) {
    // `<name>/SKILL.md`
    SkillShape.skillDir =>
      parts.length >= 2 && parts.last == 'SKILL.md' ? parts[parts.length - 2] : null,
    // `<name>.md`
    SkillShape.commandFile =>
      parts.length == 1 && parts.first.endsWith('.md')
          ? parts.first.substring(0, parts.first.length - 3)
          : null,
  };
}

/// The description, as written in a front-matter block.
///
/// YAML allows the value to be quoted, and half the skills in the wild are
/// (`description: "…"`) — a menu row that shows the author's quote marks is a row
/// that looks broken. A BLOCK SCALAR (`description: >` with the prose on the
/// lines below) has no single-line value at all, so it reads as the punctuation
/// it is and is dropped rather than shown as a stray `>`.
String _cleanDescription(String raw) {
  final value = _clip(raw, 1 << 20).trim();
  if (value.isEmpty) return value;
  if (RegExp(r'^[|>][+-]?$').hasMatch(value)) return '';
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1).trim();
    }
  }
  return value;
}

String _clip(String value, int max) {
  final trimmed = value.trim();
  if (trimmed.length <= max) return trimmed;
  return '${trimmed.substring(0, max)}…';
}

/// The list the menu shows for an agent of kind [agent].
///
/// Filtered by the roots that belong to that agent, deduped by name, project
/// entries first. WHEN THE FILTER LEAVES NOTHING, everything found is returned
/// instead: agent detection can lag (herdr reports the focused pane's process),
/// and an empty menu on a machine full of skills would read as "this app cannot
/// find your skills" — which would be worse than showing a list from a
/// differently-named directory.
List<SkillEntry> selectSkills(
  List<SkillEntry> entries, {
  required String? agent,
}) {
  final wanted = entries.isEmpty
      ? const <SkillEntry>[]
      : _filterByAgent(entries, agent);
  return _dedupe(wanted.isEmpty ? entries : wanted);
}

List<SkillEntry> _filterByAgent(List<SkillEntry> entries, String? agent) {
  final kind = agent?.trim().toLowerCase();
  if (kind == null || kind.isEmpty) return entries;
  final ids = {
    for (final root in skillRoots)
      // AN EMPTY `kinds` MEANS SHARED, not unknown. `.agents/skills` is the
      // agent-agnostic convention, and the first version of this filter dropped
      // it for every named agent — a whole store of skills invisible because the
      // root declined to name an owner. Same rule as the MCP table.
      if (root.kinds.isEmpty || root.kinds.contains(kind)) root.id,
  };
  if (ids.isEmpty) return entries;
  return [
    for (final entry in entries)
      // The source carries ` · project` for project rows; the id is the first
      // word.
      if (ids.contains(entry.source.split(' ').first)) entry,
  ];
}

/// One entry per name, project first, then alphabetical.
///
/// Alphabetical rather than probe order for the empty query, because the probe
/// order is a property of how the shell loop was written and the user's mental
/// model is "a list of names". The ranking takes over the moment a query is
/// typed.
List<SkillEntry> _dedupe(List<SkillEntry> entries) {
  final byName = <String, SkillEntry>{};
  for (final entry in entries) {
    final existing = byName[entry.name];
    if (existing == null || (entry.projectScoped && !existing.projectScoped)) {
      byName[entry.name] = entry;
    }
  }
  final out = byName.values.toList()
    ..sort((a, b) {
      if (a.projectScoped != b.projectScoped) return a.projectScoped ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  return out;
}
