/// The MCP servers a workspace has, read from the files that declare them.
///
/// ## Why config files, and not the agent
///
/// An agent's own `/` menu lists its MCP servers because the agent is the thing
/// that owns them. A composer inverts that: the text goes one way, into a paste,
/// and nothing comes back. There is no question to ask the far end either — the
/// herdr socket has no MCP call, and DSH's own status line is not readable as
/// data.
///
/// What IS readable is the declaration: every one of these tools keeps its
/// servers in a config file, in one of three shapes, and this app already has a
/// shell on that machine. So the menu lists what is declared, and says WHERE
/// each one was declared — a row with a source is a row the user can go and
/// check.
///
/// ## What a pick does
///
/// Inserts the server's NAME as text. There is no portable way to invoke an MCP
/// server from a prompt — the syntax belongs to each agent, and half of them
/// resolve tools rather than servers — so the honest thing a phone can hand over
/// is the exact spelling of the name, in the accent colour that means "this came
/// from your config, not from my imagination".
///
/// PURE DART: the file is read by `data/remote_capabilities.dart`, which hands
/// the text in. See `skills.dart` for the same split.
library;

import 'dart:convert';

/// What a config file looks like, which decides how it is parsed.
enum McpFormat {
  /// `{"mcpServers": {"name": {...}}}`, also matched as `mcp` / `mcp_servers`.
  json,

  /// `[mcp_servers.name]` (codex) or `[mcp.name]` section headers.
  toml,
}

/// One file that may declare MCP servers.
class McpSourceSpec {
  const McpSourceSpec({
    required this.label,
    required this.segments,
    required this.format,
    this.kinds = const {},
    this.projectScoped = false,
  });

  /// What the menu shows as the row's source, e.g. `~/.pi/agent/mcp.json`.
  final String label;

  /// Path segments under the home directory, or under the pane's directory for
  /// a project-scoped spec.
  final List<String> segments;

  final McpFormat format;

  /// Agent ids this file belongs to. Empty means "any agent" — which is what a
  /// shared file like a project's `.mcp.json` is.
  final Set<String> kinds;

  final bool projectScoped;
}

/// Every file worth looking in, project scope first.
const List<McpSourceSpec> mcpSources = [
  // ---- the workspace's own declarations ----------------------------------
  McpSourceSpec(
    label: '.mcp.json',
    segments: ['.mcp.json'],
    format: McpFormat.json,
    projectScoped: true,
  ),
  McpSourceSpec(
    label: '.mcp.json',
    segments: ['.mcp.json'],
    format: McpFormat.json,
    projectScoped: true,
    kinds: {'claude', 'qwen', 'kimi', 'droid', 'hermes', 'copilot'},
  ),
  McpSourceSpec(
    label: '.cursor/mcp.json',
    segments: ['.cursor', 'mcp.json'],
    format: McpFormat.json,
    projectScoped: true,
    kinds: {'cursor'},
  ),
  McpSourceSpec(
    label: '.vscode/mcp.json',
    segments: ['.vscode', 'mcp.json'],
    format: McpFormat.json,
    projectScoped: true,
  ),
  McpSourceSpec(
    label: '.codex/config.toml',
    segments: ['.codex', 'config.toml'],
    format: McpFormat.toml,
    projectScoped: true,
    kinds: {'codex'},
  ),
  McpSourceSpec(
    label: '.pi/mcp.json',
    segments: ['.pi', 'mcp.json'],
    format: McpFormat.json,
    projectScoped: true,
    kinds: {'pi', 'omp'},
  ),

  // ---- the machine's own, per agent --------------------------------------
  McpSourceSpec(
    label: '~/.pi/agent/mcp.json',
    segments: ['.pi', 'agent', 'mcp.json'],
    format: McpFormat.json,
    kinds: {'pi', 'omp'},
  ),
  McpSourceSpec(
    label: '~/.pi/mcp.json',
    segments: ['.pi', 'mcp.json'],
    format: McpFormat.json,
    kinds: {'pi', 'omp'},
  ),
  McpSourceSpec(
    label: '~/.codex/config.toml',
    segments: ['.codex', 'config.toml'],
    format: McpFormat.toml,
    kinds: {'codex'},
  ),
  McpSourceSpec(
    label: '~/.claude.json',
    segments: ['.claude.json'],
    format: McpFormat.json,
    kinds: {'claude', 'qwen', 'kimi', 'droid', 'hermes', 'copilot'},
  ),
  McpSourceSpec(
    label: '~/.cursor/mcp.json',
    segments: ['.cursor', 'mcp.json'],
    format: McpFormat.json,
    kinds: {'cursor'},
  ),
  McpSourceSpec(
    label: '~/.config/opencode/opencode.json',
    segments: ['.config', 'opencode', 'opencode.json'],
    format: McpFormat.json,
    kinds: {'opencode', 'kilo'},
  ),
  McpSourceSpec(
    label: '~/.grok/mcp.json',
    segments: ['.grok', 'mcp.json'],
    format: McpFormat.json,
    kinds: {'grok'},
  ),
  McpSourceSpec(
    label: '~/.gemini/settings.json',
    segments: ['.gemini', 'settings.json'],
    format: McpFormat.json,
  ),
];

/// One declared MCP server.
class McpEntry {
  const McpEntry({
    required this.name,
    required this.source,
    required this.detail,
    required this.projectScoped,
  });

  final String name;

  /// The file it was declared in, as the menu shows it.
  final String source;

  /// `command` or `url` from the declaration, for the row's second line.
  final String detail;

  final bool projectScoped;

  @override
  String toString() => 'McpEntry($name from $source)';
}

/// The absolute path of [spec], or null when its base is unknown.
String? mcpSourcePath(
  McpSourceSpec spec, {
  required String? home,
  required String? cwd,
}) {
  final base = spec.projectScoped ? cwd : home;
  if (base == null || base.isEmpty) return null;
  final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return '$trimmed/${spec.segments.join('/')}';
}

/// Every source that resolves to an absolute path.
List<(McpSourceSpec, String)> resolvedMcpSources({
  required String? home,
  required String? cwd,
}) => [
  for (final spec in mcpSources)
    if (mcpSourcePath(spec, home: home, cwd: cwd) case final path?) (spec, path),
];

/// Reads the servers out of one file's text.
///
/// [path] is only used to find the spec again, so that a file's contents and its
/// label cannot drift.
List<McpEntry> parseMcpFile(
  String path,
  String text, {
  required List<(McpSourceSpec, String)> sources,
}) {
  (McpSourceSpec, String)? match;
  for (final candidate in sources) {
    if (candidate.$2 == path) {
      match = candidate;
      break;
    }
  }
  if (match == null) return const [];

  final (spec, _) = match;
  return switch (spec.format) {
    McpFormat.json => _parseJson(text, spec),
    McpFormat.toml => _parseToml(text, spec),
  };
}

/// The top-level keys of the MCP object in a JSON config.
///
/// Three spellings because three ecosystems wrote one file each: Claude Code and
/// its many forks use `mcpServers`, opencode uses `mcp`, and some tools keep the
/// underscore. A file that is not valid JSON — including one that was TRUNCATED
/// by the byte cap on the way here — yields nothing rather than throwing: a menu
/// that refuses to open because a config file is 300 KB is worse than a menu
/// missing one row.
List<McpEntry> _parseJson(String text, McpSourceSpec spec) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map) return const [];

  const keys = ['mcpServers', 'mcp_servers', 'mcp'];
  for (final key in keys) {
    final value = decoded[key];
    if (value is! Map) continue;
    final entries = <McpEntry>[];
    for (final entry in value.entries) {
      final name = '${entry.key}'.trim();
      if (name.isEmpty) continue;
      entries.add(
        McpEntry(
          name: name,
          source: spec.label,
          detail: _detailOf(entry.value),
          projectScoped: spec.projectScoped,
        ),
      );
    }
    if (entries.isNotEmpty) return entries;
  }
  return const [];
}

/// The server's command or URL, whichever the declaration carries.
String _detailOf(Object? declaration) {
  if (declaration is! Map) return '';
  for (final key in ['command', 'url', 'serverUrl', 'endpoint']) {
    final value = declaration[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

/// `[mcp_servers.name]` and `[mcp.name]` section headers.
///
/// Only the FIRST segment after the prefix is taken, so codex's per-server
/// sub-tables (`[mcp_servers.node_repl.env]`) do not invent a second server
/// called `node_repl.env`. Values are not parsed: a section header is enough to
/// know a server exists, and `command = "…"` directly under it is enough to say
/// what it is.
final _tomlSection = RegExp(
  r'^\[\s*(?:mcp_servers|mcp)\s*\.\s*([^\]\s.]+)\s*(?:\]|\.)',
);

final _tomlValue = RegExp(
  r'^\s*(?:command|url)\s*=\s*["\x27]([^"\x27]*)["\x27]',
);

List<McpEntry> _parseToml(String text, McpSourceSpec spec) {
  final entries = <McpEntry>[];
  final seen = <String>{};
  String? current;
  var detail = '';

  void flush() {
    final name = current;
    if (name == null || name.isEmpty) return;
    if (seen.add(name)) {
      entries.add(
        McpEntry(
          name: name,
          source: spec.label,
          detail: detail,
          projectScoped: spec.projectScoped,
        ),
      );
    }
  }

  for (final line in const LineSplitter().convert(text)) {
    final section = _tomlSection.firstMatch(line);
    if (section != null) {
      flush();
      current = section.group(1);
      detail = '';
      continue;
    }
    if (current == null) continue;
    // Only the first value under the header: `args = [...]` also mentions
    // commands, and the row has one line.
    if (detail.isNotEmpty) continue;
    final value = _tomlValue.firstMatch(line);
    if (value != null) detail = value.group(1)!.trim();
  }
  flush();
  return entries;
}

/// The servers to show for an agent of kind [agent], project scope first.
///
/// Same fallback as the skills menu, for the same reason: if the filter leaves
/// nothing, showing everything found beats showing an empty list on a machine
/// that plainly has servers configured.
List<McpEntry> selectMcpServers(
  List<McpEntry> entries, {
  required String? agent,
}) {
  if (entries.isEmpty) return entries;
  final kind = agent?.trim().toLowerCase();

  // Filtered by SOURCE rather than by entry, so a file that belongs to nobody in
  // particular (a project's `.mcp.json`, a `.vscode/mcp.json`) keeps its rows for
  // every agent — an empty `kinds` means "shared", not "unknown".
  final allowed = {
    for (final spec in mcpSources)
      if (kind == null || kind.isEmpty || spec.kinds.isEmpty || spec.kinds.contains(kind))
        spec.label,
  };
  final filtered = [
    for (final entry in entries)
      if (allowed.contains(entry.source)) entry,
  ];
  return _dedupeMcp(filtered.isEmpty ? entries : filtered);
}

/// One row per name, project first, then alphabetical.
List<McpEntry> _dedupeMcp(List<McpEntry> entries) {
  final byName = <String, McpEntry>{};
  for (final entry in entries) {
    final existing = byName[entry.name];
    if (existing == null || (entry.projectScoped && !existing.projectScoped)) {
      byName[entry.name] = entry;
    }
  }
  return byName.values.toList()
    ..sort((a, b) {
      if (a.projectScoped != b.projectScoped) return a.projectScoped ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
}
