import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/agent/mcp.dart';

/// Reading MCP servers out of the config files that declare them.
///
/// Three shapes are in the wild and all three are parsed here, with the real
/// files' own spelling as the fixture: `mcpServers` (Claude Code and its forks,
/// pi, Cursor), `mcp` (opencode), and `[mcp_servers.name]` (codex's TOML).
void main() {
  final sources = resolvedMcpSources(home: '/home/u', cwd: '/home/u/proj');

  List<McpEntry> parse(String path, String text) =>
      parseMcpFile(path, text, sources: sources);

  group('JSON', () {
    test('names come from the mcpServers object', () {
      final entries = parse(
        '/home/u/.pi/agent/mcp.json',
        '{"mcpServers":{"vision":{"command":"uv","args":["run"]}}}',
      );
      expect(entries.single.name, 'vision');
      expect(entries.single.detail, 'uv');
      expect(entries.single.source, '~/.pi/agent/mcp.json');
    });

    test('a remote server is described by its url', () {
      final entries = parse(
        '/home/u/proj/.mcp.json',
        '{"mcpServers":{"remote":{"url":"https://mcp.example.com/sse"}}}',
      );
      expect(entries.single.detail, 'https://mcp.example.com/sse');
    });

    test("opencode's own key works too", () {
      final entries = parse(
        '/home/u/.config/opencode/opencode.json',
        '{"mcp":{"tradingview":{"command":"python"}}}',
      );
      expect(entries.single.name, 'tradingview');
    });

    test('an empty object is no servers, not a failure', () {
      expect(parse('/home/u/.cursor/mcp.json', '{"mcpServers":{}}'), isEmpty);
    });

    test('a file cut off by the byte cap yields nothing, and does not throw', () {
      // The real shape of the failure: `head -c` truncates a large config, and
      // a menu that refuses to open because one file is 300 KB is worse than a
      // menu missing one row.
      expect(
        parse('/home/u/.claude.json', '{"mcpServers":{"a":{"command":"x"'),
        isEmpty,
      );
    });

    test('a file with no MCP key at all yields nothing', () {
      expect(parse('/home/u/.claude.json', '{"projects":{}}'), isEmpty);
    });
  });

  group('TOML', () {
    test('a section header declares a server', () {
      final entries = parse(
        '/home/u/.codex/config.toml',
        '[mcp_servers.computer-use]\n'
        'command = "SkyComputerUseClient"\n'
        'args = [ "mcp" ]\n',
      );
      expect(entries.single.name, 'computer-use');
      expect(entries.single.detail, 'SkyComputerUseClient');
    });

    test('a per-server sub-table does not invent a second server', () {
      // `[mcp_servers.node_repl.env]` is a key INSIDE node_repl, and reading the
      // whole dotted path as a name would put `node_repl.env` in the menu.
      final entries = parse(
        '/home/u/.codex/config.toml',
        '[mcp_servers.node_repl]\n'
        'command = "node_repl"\n'
        '[mcp_servers.node_repl.env]\n'
        'NODE_PATH = "/x"\n',
      );
      expect(entries.map((e) => e.name), ['node_repl']);
    });

    test('several servers in one file', () {
      final entries = parse(
        '/home/u/.codex/config.toml',
        '[mcp_servers]\n'
        '[mcp_servers.a]\ncommand = "one"\n'
        '[mcp_servers.b]\ncommand = "two"\n',
      );
      expect(entries.map((e) => e.name), ['a', 'b']);
      expect(entries.map((e) => e.detail), ['one', 'two']);
    });

    test('a server with no command has no detail, and is still listed', () {
      final entries = parse('/home/u/.codex/config.toml', '[mcp_servers.x]\n');
      expect(entries.single.name, 'x');
      expect(entries.single.detail, isEmpty);
    });

    test('unrelated TOML is ignored', () {
      expect(parse('/home/u/.codex/config.toml', '[model]\nname = "x"\n'), isEmpty);
    });
  });

  group('which servers a workspace shows', () {
    test('a project declaration beats the same name in the home directory', () {
      final entries = [
        ...parse('/home/u/.claude.json', '{"mcpServers":{"db":{"command":"user"}}}'),
        ...parse('/home/u/proj/.mcp.json', '{"mcpServers":{"db":{"command":"project"}}}'),
      ];
      final selected = selectMcpServers(entries, agent: 'claude');
      expect(selected.single.detail, 'project');
      expect(selected.single.projectScoped, isTrue);
    });

    test("an agent does not see another agent's config", () {
      final entries = [
        ...parse('/home/u/.codex/config.toml', '[mcp_servers.cx]\ncommand = "c"\n'),
        ...parse('/home/u/.pi/agent/mcp.json', '{"mcpServers":{"pi-only":{}}}'),
      ];
      expect(
        selectMcpServers(entries, agent: 'codex').map((e) => e.name),
        ['cx'],
      );
      expect(
        selectMcpServers(entries, agent: 'pi').map((e) => e.name),
        ['pi-only'],
      );
    });

    test('a project config belongs to every agent', () {
      // `.mcp.json` is the workspace's, not one tool's — a `kinds` list on it
      // would hide it from everyone else.
      final entries = parse('/home/u/proj/.mcp.json', '{"mcpServers":{"shared":{}}}');
      expect(selectMcpServers(entries, agent: 'grok').map((e) => e.name), ['shared']);
    });

    test('a fallback list keeps working when nothing matches', () {
      final entries = parse('/home/u/.pi/agent/mcp.json', '{"mcpServers":{"pi-only":{}}}');
      expect(
        selectMcpServers(entries, agent: 'codex').map((e) => e.name),
        ['pi-only'],
      );
    });
  });
}
