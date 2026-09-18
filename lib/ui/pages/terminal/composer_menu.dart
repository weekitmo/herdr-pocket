import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:herdr_pocket/data/remote_capabilities.dart';
import 'package:herdr_pocket/data/remote_files.dart';
import 'package:herdr_pocket/domain/agent/mcp.dart';
import 'package:herdr_pocket/domain/agent/skills.dart';
import 'package:herdr_pocket/domain/terminal/menu.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/pages/terminal/menu_panel.dart';

/// What the `/` and `@` menus are showing, and where they got it.
///
/// ## The two questions this answers
///
/// The composer sends one PASTE, so the agent's TUI never sees a keystroke and
/// never opens its own `/` menu or its `@` completion. Both have to be drawn
/// here — and drawn from real data, because a menu of made-up entries is worse
/// than no menu at all. The data is the machine's own: the skills in its
/// directories, the MCP servers in its config files, the files in the pane's
/// directory.
///
/// ## One read per menu, not one per keystroke
///
/// Everything is fetched when a menu is first opened and then filtered on the
/// phone. Re-reading the machine per character would put a round trip behind
/// every keystroke — the exact cost the composer exists to remove, reintroduced
/// in the menu that is supposed to make it usable. The cost is stated rather
/// than hidden: a file created after the menu opened is not in it until the menu
/// is reopened, which is what [reload] is for.
///
/// ## Three outcomes, not one empty list
///
/// "Nothing found", "could not look" and "still loading" are three sentences
/// with three different next steps. Only the first is a fact about the machine;
/// the second is a fact about the connection; the third is a fact about the
/// phone. Collapsing them into an empty list would be the menu lying.
class ComposerMenuController extends ChangeNotifier {
  ComposerMenuController({
    required this.l10n,
    this.capabilities,
    this.fileIndex,
    this.cache,
    this.paneId,
    this.cwd,
    this.agent,
  });

  final AppLocalizations l10n;
  final RemoteCapabilities? capabilities;
  final RemoteFileIndex? fileIndex;

  /// Where the `/` answer is remembered between openings of this screen.
  ///
  /// THE CONTROLLER IS REBUILT EVERY TIME THE CHAT WINDOW OPENS, which is why
  /// the cache cannot live in a field here: the first version of this file
  /// cached `_probe` in the instance, and every open of the composer paid for
  /// the probe again (0.4 s, 54 KB and one `sh -c` on the machine this was
  /// measured on). See [ComposerCapabilityCache].
  final ComposerCapabilityCache? cache;

  /// Which pane this menu belongs to — the cache's key. See the cache's own
  /// docs for why a pane and not the app.
  final String? paneId;

  /// The pane's own directory — the workspace whose skills, MCP servers and
  /// files these menus are about.
  ///
  /// Not final: a tree read that arrives late re-points it. See [updateContext].
  String? cwd;

  /// What the pane is running, used to filter the two capability lists.
  String? agent;

  MenuToken? _token;
  bool _loading = false;
  ProbeResult? _probe;
  FileIndexResult? _files;

  /// Bumped on every read, so a late reply cannot repopulate a menu that has
  /// since closed or moved to another pane.
  int _generation = 0;

  /// Built once per change rather than in a getter: a getter that also decides
  /// the message would be mutating state during a build.
  ({List<ComposerMenuRow> rows, String? message, bool isError}) _view = (
    rows: const [],
    message: null,
    isError: false,
  );

  /// Whether this pane is running something that understands `/` and `@`.
  ///
  /// `pane.list` leaves `agent` empty for a plain shell, which is the difference
  /// between a pane whose `/` opens a menu and one whose `/` is a path
  /// separator.
  bool get hasAgent => (agent ?? '').trim().isNotEmpty;

  MenuToken? get token => _token;
  bool get isOpen => _token != null;
  bool get isLoading => _loading;
  List<ComposerMenuRow> get rows => _view.rows;
  String? get message => _view.message;
  bool get isError => _view.isError;

  /// Reads the field's new state: what is typed, and where the caret is.
  ///
  /// Called on every edit AND every caret move, because the query is the text
  /// between the trigger and the caret — tapping elsewhere in the line changes
  /// it just as surely as typing does.
  void sync({required String text, required int caret}) {
    var next = readMenuToken(text: text, caret: caret);
    // A path is not a command, and a shell has no skills: see [shouldOpenMenu].
    if (next != null && !shouldOpenMenu(next, agentPane: hasAgent)) next = null;
    if (next == _token) return;
    _token = next;
    if (next == null) {
      _view = (rows: const [], message: null, isError: false);
      _loading = false;
      notifyListeners();
      return;
    }
    _recompute();
    notifyListeners();
    unawaited(_load(next.trigger));
  }

  /// Opens a menu from a BUTTON rather than from typing a trigger.
  ///
  /// The caller inserts the trigger character into the field first and then
  /// calls this, so there is exactly one kind of open menu — a second path for
  /// the button would be a second place for the query, the caret and the pick to
  /// disagree.
  void openAt({required String text, required int caret}) =>
      sync(text: text, caret: caret);

  void close() {
    if (_token == null && _view.message == null) return;
    _token = null;
    _view = (rows: const [], message: null, isError: false);
    _loading = false;
    _generation++;
    notifyListeners();
  }

  /// Re-points the menus at a directory that arrived late.
  ///
  /// The pane's own details come from a tree that may not have been read when
  /// the composer opened, and the difference is not cosmetic: the project-shaped
  /// roots are resolved under the pane's directory, so a menu built without one
  /// silently lists only the user's own skills.
  void updateContext({required String? cwd, required String? agent}) {
    if (cwd == this.cwd && agent == this.agent) return;
    this.cwd = cwd;
    this.agent = agent;
    final open = _token;
    reset();
    if (open == null) return;
    sync(text: open.query.isEmpty ? '/' : '/${open.query}', caret: open.query.length + 1);
  }

  /// Forgets everything, because the screen is now about another directory.
  ///
  /// What switching panes does: the caches are per pane, and a stale list of
  /// another project's skills is worse than an empty one.
  void reset() {
    _generation++;
    _probe = null;
    _files = null;
    _token = null;
    _view = (rows: const [], message: null, isError: false);
    _loading = false;
    notifyListeners();
  }

  /// Reads the machine again for whatever the open menu is about.
  ///
  /// [force] bypasses the cache — the "read the machine again" affordance a
  /// stale list needs. Everything else uses it, which is the point: the lists
  /// are the machine's files, and re-running a 54 KB probe behind every
  /// keystroke-triggered menu would put a round trip where the composer exists
  /// to remove one.
  void reload() {
    _generation++;
    _probe = null;
    _files = null;
    final open = _token;
    if (open == null) {
      notifyListeners();
      return;
    }
    unawaited(_load(open.trigger, force: true));
  }

  Future<void> _load(MenuTrigger trigger, {bool force = false}) async {
    // ADOPTING THE CACHED ANSWER INTO `_probe`, not merely reading it, is what
    // makes the cache visible: the view is recomputed from `_probe`, so a hit
    // that did not land there would leave the menu empty with the answer
    // sitting in a map next to it.
    if (!force) {
      if (trigger == MenuTrigger.slash) {
        final cached = _probe ?? _cachedProbe;
        if (cached != null) {
          _probe = cached;
          _loading = false;
          _recompute();
          notifyListeners();
          return;
        }
      } else if (_files != null) {
        _loading = false;
        _recompute();
        notifyListeners();
        return;
      }
    }

    // A menu that cannot be filled on this connection says why, once, and stops
    // pretending to be loading.
    if (!_canRead(trigger)) {
      _loading = false;
      _view = (
        rows: const [],
        message: l10n.composerUnavailable,
        isError: true,
      );
      notifyListeners();
      return;
    }

    final generation = ++_generation;
    _loading = true;
    _recompute();
    notifyListeners();

    // The two reads are named rather than reached through a shared local: they
    // have different types and different answers, and `_canRead` above is what
    // makes each cast safe.
    switch (trigger) {
      case MenuTrigger.slash:
        final result = await capabilities!.probe(cwd: cwd, agent: agent);
        _probe = result;
        // REMEMBERED BEFORE THE GENERATION CHECK, deliberately: the answer is
        // about the pane and directory captured above, so it stays true even if
        // this controller has since been reset by a pane switch. Dropping it
        // would mean paying for the same probe again on the way back.
        _rememberProbe(result);
      case MenuTrigger.at:
        _files = await fileIndex!.list(cwd!);
    }

    if (generation != _generation) return;
    _loading = false;
    _recompute();
    notifyListeners();
  }

  /// The probe this pane's cache holds for the current context, if any.
  ProbeResult? get _cachedProbe {
    final cache = this.cache;
    final paneId = this.paneId;
    if (cache == null || paneId == null) return null;
    return cache.probeFor(paneId: paneId, cwd: cwd, agent: agent);
  }

  void _rememberProbe(ProbeResult result) {
    final cache = this.cache;
    final paneId = this.paneId;
    if (cache == null || paneId == null) return;
    cache.remember(paneId: paneId, cwd: cwd, agent: agent, result: result);
  }

  bool _canRead(MenuTrigger trigger) => switch (trigger) {
    MenuTrigger.slash => capabilities != null,
    MenuTrigger.at => fileIndex != null && cwd != null,
  };

  void _recompute() {
    final token = _token;
    if (token == null) {
      _view = (rows: const [], message: null, isError: false);
      return;
    }
    _view = switch (token.trigger) {
      MenuTrigger.slash => _capabilityView(token.query),
      MenuTrigger.at => _fileView(token.query),
    };
  }

  ({List<ComposerMenuRow> rows, String? message, bool isError}) _capabilityView(
    String query,
  ) {
    final probe = _probe;
    // Still loading: no message, so the panel shows its spinner rather than a
    // sentence about an answer that has not arrived.
    if (probe == null) return _pending;

    switch (probe) {
      case ProbeUnreadable(:final detail):
        return (rows: const [], message: '${l10n.composerUnreadable} $detail', isError: true);
      case ProbeNone():
        return (rows: const [], message: l10n.composerNothingFound, isError: false);
      case ProbeFound(:final skills, :final mcp):
        final rows = <ComposerMenuRow>[
          // No agent, no skills: the list would be a menu of things this pane
          // cannot do. `selectSkills` already filters by agent, and this is the
          // stronger statement — for a plain terminal there is no list at all.
          if (hasAgent)
            for (final skill in rankByName(skills, query, _skillName))
              ComposerMenuRow(
                insert: '/${skill.name}',
                title: skill.name,
                subtitle: skill.description,
                kind: l10n.composerSectionSkills,
                tag: skill.source,
              ),
          if (hasAgent)
            for (final server in rankByName(mcp, query, _serverName))
              ComposerMenuRow(
                // The NAME rather than an invocation: there is no portable way
                // to call an MCP server from a prompt, and inventing syntax
                // would put plausible-looking nonsense on the user's screen.
                // What is worth handing over is the exact spelling.
                insert: server.name,
                title: server.name,
                subtitle: server.detail,
                kind: l10n.composerSectionMcp,
                tag: server.source,
              ),
        ];
        if (rows.isEmpty) {
          return (rows: const [], message: l10n.composerNoMatch, isError: false);
        }
        return (rows: _cap(rows), message: null, isError: false);
    }
  }

  ({List<ComposerMenuRow> rows, String? message, bool isError}) _fileView(
    String query,
  ) {
    final index = _files;
    if (index == null) return _pending;

    switch (index) {
      case FileIndexUnreadable(:final detail):
        return (rows: const [], message: '${l10n.composerUnreadable} $detail', isError: true);
      case FileIndexEmpty():
        return (rows: const [], message: l10n.composerEmptyDir, isError: false);
      case FileIndexFound(:final paths):
        // Ranked on the WHOLE path, so `lib/main` finds `lib/main.dart`: files in
        // a workspace are addressed by their shape, not by their last segment.
        final ranked = rankByName(paths, query, (path) => path);
        final rows = [
          for (final path in ranked)
            ComposerMenuRow(
              insert: fileReferenceText(path, agentPane: hasAgent),
              title: _baseName(path),
              subtitle: _directoryOf(path),
              kind: l10n.composerSectionFiles,
            ),
        ];
        if (rows.isEmpty) {
          return (rows: const [], message: l10n.composerNoMatch, isError: false);
        }
        return (rows: _cap(rows), message: null, isError: false);
    }
  }

  static const ({List<ComposerMenuRow> rows, String? message, bool isError})
  _pending = (rows: <ComposerMenuRow>[], message: null, isError: false);

  /// How many rows are worth building. A monorepo's listing is thousands of
  /// paths and the list is rebuilt on every keystroke; past a few dozen the user
  /// is typing more, not scrolling.
  static const int maxRows = 60;

  List<ComposerMenuRow> _cap(List<ComposerMenuRow> rows) =>
      rows.length <= maxRows ? rows : rows.sublist(0, maxRows);
}

/// The `/` probe, remembered for as long as one visit to a terminal lasts.
///
/// ## Why it exists
///
/// The skills and MCP lists are read from the MACHINE (there is no herdr API
/// for them — see `remote_capabilities.dart`), and the read is one `sh -c`
/// that walks 27 skill roots and 14 MCP config files: measured at 0.4 s and
/// 54 KB on the developer's machine. The menu controller is rebuilt every time
/// the chat window opens, so without this the price was paid on every open.
///
/// ## Why per pane, and why the context is part of the key
///
/// The lists are the machine's files under the PANE's directory. Two panes in
/// two projects have two different sets of skills and MCP servers, so one
/// shared answer would hand project A's menu to project B — the same mistake
/// the menus' own context handling exists to avoid. The directory and the agent
/// are part of the key for the same reason: a file is project-scoped and a
/// skill list is filtered by what the pane is running, so an answer only counts
/// while both are unchanged.
///
/// ## Why it is a plain object on the page
///
/// The lifetime is the point: "once per visit to the terminal, not once per
/// chat window". The page owns it, the widgets read it, and leaving the
/// terminal and coming back is what clears it. No provider, no invalidation
/// graph — a page-scoped map is the whole requirement.
class ComposerCapabilityCache {
  final Map<String, _CachedProbe> _byPane = {};

  /// The answer [paneId] already has for this exact context, if any.
  ProbeResult? probeFor({required String paneId, String? cwd, String? agent}) {
    final entry = _byPane[paneId];
    if (entry == null) return null;
    if (entry.cwd != cwd || entry.agent != agent) return null;
    return entry.result;
  }

  /// Remembers an answer for [paneId].
  void remember({
    required String paneId,
    required ProbeResult result,
    String? cwd,
    String? agent,
  }) {
    _byPane[paneId] = _CachedProbe(cwd: cwd, agent: agent, result: result);
  }
}

/// One pane's answer, and the context it was made in.
class _CachedProbe {
  const _CachedProbe({required this.cwd, required this.agent, required this.result});

  final String? cwd;
  final String? agent;
  final ProbeResult result;
}

String _skillName(SkillEntry entry) => entry.name;
String _serverName(McpEntry entry) => entry.name;

String _baseName(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? path : path.substring(cut + 1);
}

String _directoryOf(String path) {
  final cut = path.lastIndexOf('/');
  if (cut < 0) return '';
  return cut == 0 ? '/' : path.substring(0, cut);
}
