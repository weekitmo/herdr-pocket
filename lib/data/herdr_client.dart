import 'dart:async';
import 'dart:convert';

import 'package:herdr_pocket/data/protocol/herdr_message.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/agent_info.dart';
import 'package:herdr_pocket/domain/agent/agent_list.dart';
import 'package:herdr_pocket/domain/git/worktree.dart';
import 'package:herdr_pocket/domain/workspace/agent_launch.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/pane_layout.dart';
import 'package:herdr_pocket/domain/workspace/pane_process.dart';
import 'package:herdr_pocket/domain/workspace/tab_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';

/// What the daemon said about itself.
class HerdrHello {
  const HerdrHello({
    required this.version,
    required this.protocol,
    this.capabilities = const {},
  });

  /// herdr's own version, e.g. `0.9.0`.
  final String version;

  /// Wire protocol number. The live 0.9.0 daemon reports 22 while the newest
  /// schema the reference clients ship is 20 — the number moves independently
  /// of the app version, which is exactly why nothing here branches on it.
  final int protocol;

  final Set<String> capabilities;
}

/// What creating a workspace or worktree produced.
///
/// herdr answers both `workspace.create` and `worktree.create` with the whole
/// new structure — workspace, its first tab, and that tab's root pane — which
/// is the only way to learn the new pane id. Without it the caller would have
/// to re-list everything and guess which pane was just made.
class CreatedWorkspace {
  const CreatedWorkspace({this.workspace, this.tab, this.rootPane, this.worktree});

  factory CreatedWorkspace.fromResult(HerdrSuccess result) {
    final map = result.resultMap ?? const <String, Object?>{};
    final workspace = map['workspace'];
    final tab = map['tab'];
    final pane = map['root_pane'];
    final worktree = map['worktree'];
    return CreatedWorkspace(
      workspace: workspace is Map
          ? WorkspaceInfo.fromJson(workspace.cast<String, Object?>())
          : null,
      tab: tab is Map ? TabInfo.fromJson(tab.cast<String, Object?>()) : null,
      rootPane:
          pane is Map ? PaneInfo.fromJson(pane.cast<String, Object?>()) : null,
      worktree: worktree is Map
          ? WorktreeInfo.fromJson(worktree.cast<String, Object?>())
          : null,
    );
  }

  final WorkspaceInfo? workspace;
  final TabInfo? tab;

  /// The pane the new workspace starts with — where an agent would be started.
  final PaneInfo? rootPane;

  /// Present only for a worktree creation.
  final WorktreeInfo? worktree;

  String? get workspaceId => workspace?.workspaceId;
  String? get paneId => rootPane?.paneId;
}

/// What `agent.read` handed back.
///
/// The schema carries more than the text — `truncated` in particular is a real
/// field, and dropping it would make a clipped screen look like a complete one.
/// That matters here more than anywhere: this text is what a person decides to
/// press a key on. A silently truncated question is a question answered wrong.
class AgentReadResult {
  const AgentReadResult({
    required this.text,
    this.truncated = false,
    this.paneId,
    this.revision,
    this.source,
  });

  /// The lines, already stripped of ANSI when the daemon honoured the flag.
  final String text;

  /// True when the daemon cut the buffer at the requested line count.
  final bool truncated;

  final String? paneId;
  final int? revision;
  final String? source;

  /// The text as lines, with any trailing blank line removed.
  List<String> get lines {
    if (text.isEmpty) return const [];
    final split = text.split('\n');
    if (split.isNotEmpty && split.last.isEmpty) split.removeLast();
    return split;
  }

  @override
  String toString() =>
      'AgentReadResult(${text.length} chars, truncated: $truncated)';
}

/// The herdr socket API, typed.
///
/// Deliberately thin: it maps method names to decoded results and nothing else.
/// Policy — reconnection, backoff, which snapshot to trust — belongs a layer
/// up, where it can be tested without a socket.
class HerdrClient {
  HerdrClient(this._transport);

  final HerdrTransport _transport;

  /// Request ids are per-client and only need to be unique on the wire. Note
  /// that the daemon does NOT echo them on errors (see [HerdrFailure.id]), so
  /// these are for logging rather than correlation.
  int _seq = 0;

  HerdrTransport get transport => _transport;

  Future<HerdrSuccess> _call(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    final id = 'hp${_seq++}';
    final line = await _transport.roundTrip(
      HerdrRequest(method, params).encode(id),
    );

    final reply = HerdrReply.decode(line);
    return switch (reply) {
      HerdrSuccess() => reply,
      HerdrFailure(:final code, :final message) =>
        throw HerdrApiException(code: code, message: message),
    };
  }

  /// Availability handshake.
  ///
  /// Also the ONLY honest capability probe: herdr has no version negotiation,
  /// so a feature is detected by attempting it and reading the error.
  Future<HerdrHello> ping() async {
    final result = await _call(HerdrMethod.ping);
    final map = result.resultMap ?? const <String, Object?>{};

    return HerdrHello(
      version: map['version'] is String ? map['version']! as String : '',
      protocol: _asInt(map['protocol']) ?? 0,
      capabilities: switch (map['capabilities']) {
        final List<Object?> list => list.whereType<String>().toSet(),
        _ => const <String>{},
      },
    );
  }

  /// Every agent the daemon knows about.
  Future<List<AgentInfo>> agentList() async {
    final result = await _call(HerdrMethod.agentList);
    final map = result.resultMap;
    final agents = map?['agents'];
    if (agents is! List) return const [];

    return agents
        .whereType<Map<Object?, Object?>>()
        .map((e) => AgentInfo.fromJson(e.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// The screen an agent is showing right now, as text.
  ///
  /// [source] is one of `visible`, `recent`, `recent-unwrapped`, `detection`.
  /// `recent` (the default) is the buffer's tail — which for a TUI agent is
  /// mostly its own status bar, so the caller still has to find the question
  /// inside it. See `domain/agent/agent_question.dart`.
  Future<AgentReadResult> agentRead({
    required String target,
    String source = 'recent',
    int? lines,
    String format = 'text',
    bool stripAnsi = true,
  }) async {
    final result = await _call(HerdrMethod.agentRead, {
      'target': target,
      'source': source,
      'format': format,
      'strip_ansi': stripAnsi,
      'lines': ?lines,
    });

    final read = result.resultMap?['read'];
    final map =
        read is Map ? read.cast<String, Object?>() : const <String, Object?>{};
    return AgentReadResult(
      text: map['text'] is String ? map['text']! as String : '',
      truncated: map['truncated'] == true,
      paneId: map['pane_id'] is String ? map['pane_id']! as String : null,
      revision: _asInt(map['revision']),
      source: map['source'] is String ? map['source']! as String : null,
    );
  }

  /// Presses keys on an agent: menu options, Enter, Escape.
  ///
  /// This is the ONLY way to answer an agent that is showing a menu —
  /// [agentPrompt] is refused outright while it is blocked, and sends nothing.
  Future<void> agentSendKeys({
    required String target,
    required List<String> keys,
  }) =>
      _call(HerdrMethod.agentSendKeys, {'target': target, 'keys': keys});

  /// Submits text as a prompt, exactly as the desktop composer would.
  ///
  /// Honours bracketed paste, so multi-line text is fine here — unlike typing
  /// into a pane, where a newline IS a submission.
  ///
  /// Passing [waitUntil] makes it one server-side request that submits AND
  /// waits, which is the point: two round trips would race the agent's own
  /// state change in between.
  Future<AgentInfo?> agentPrompt({
    required String target,
    required String text,
    List<String>? waitUntil,
    int? timeoutMs,
  }) async {
    final result = await _call(HerdrMethod.agentPrompt, {
      'target': target,
      'text': text,
      if (waitUntil != null || timeoutMs != null)
        'wait': {
          'until': ?waitUntil,
          'timeout_ms': ?timeoutMs,
        },
    });

    final agent = result.resultMap?['agent'];
    return agent is Map
        ? AgentInfo.fromJson(agent.cast<String, Object?>())
        : null;
  }

  /// Focuses an agent's pane AND marks its completion seen.
  ///
  /// The second half is the reason this exists as its own call: `agent.read`
  /// deliberately does NOT clear a `done` state, so reading a finished agent
  /// from a list leaves it finished forever.
  Future<void> agentFocus(String target) =>
      _call(HerdrMethod.agentFocus, {'target': target});

  /// Every agent herdr can start, with whether its binary is present.
  ///
  /// Exists on protocol 22 (verified live: 17 entries). The list belongs to the
  /// daemon, and that matters — the target is not the command (`cursor` runs
  /// `cursor-agent`, `antigravity_cli` runs `agy`), and a new upstream agent
  /// should appear here without a client release.
  Future<List<AgentIntegration>> integrationList() async {
    final result = await _call(HerdrMethod.integrationList);
    return _decodeList(result, 'integrations', AgentIntegration.fromJson);
  }

  /// What is actually running inside a pane.
  ///
  /// The question `agent.start` depends on: it needs a pane whose SHELL owns
  /// the foreground, which `agent.list` cannot answer.
  Future<PaneProcessInfo?> paneProcessInfo({required String paneId}) async {
    final result = await _call(
      HerdrMethod.paneProcessInfo,
      {'pane_id': paneId},
    );
    final info = result.resultMap?['process_info'];
    return info is Map
        ? PaneProcessInfo.fromJson(info.cast<String, Object?>())
        : null;
  }

  /// Creates a workspace, which brings its first tab and root pane with it.
  ///
  /// Focus defaults to true HERE while the daemon's own default is false: this
  /// is only ever called because the user just asked for a new workspace, and
  /// leaving them looking at the old one would look like nothing happened.
  Future<CreatedWorkspace> workspaceCreate({
    String? cwd,
    String? label,
    bool focus = true,
    Map<String, String>? env,
  }) async {
    final result = await _call(HerdrMethod.workspaceCreate, {
      'cwd': ?cwd,
      'label': ?label,
      'focus': focus,
      'env': ?env,
    });
    return CreatedWorkspace.fromResult(result);
  }

  /// Opens a git worktree as a workspace.
  ///
  /// The isolated-checkout path: a branch of its own, so an agent working there
  /// cannot touch what the user is looking at. [path] is deliberately left to
  /// the daemon unless the caller knows better — the daemon owns the convention
  /// for where worktrees live.
  Future<CreatedWorkspace> worktreeCreate({
    String? cwd,
    String? branch,
    String? base,
    String? label,
    String? path,
    bool focus = true,
  }) async {
    final result = await _call(HerdrMethod.worktreeCreate, {
      'cwd': ?cwd,
      'branch': ?branch,
      'base': ?base,
      'label': ?label,
      'path': ?path,
      'focus': focus,
    });
    return CreatedWorkspace.fromResult(result);
  }

  /// Every worktree herdr can see in the repository that CONTAINS [cwd].
  ///
  /// Throws [HerdrApiException] with `not_git_worktree` when there is no
  /// repository there — a normal answer to a normal question, and the reason
  /// the UI asks before offering the option.
  Future<WorktreeListing> worktreeList({
    String? cwd,
    String? workspaceId,
  }) async {
    final result = await _call(HerdrMethod.worktreeList, {
      'cwd': ?cwd,
      'workspace_id': ?workspaceId,
    });
    return WorktreeListing.fromJson(
      result.resultMap ?? const <String, Object?>{},
    );
  }

  /// Starts a supported agent in an EXISTING idle shell pane.
  ///
  /// The daemon refuses with `agent_not_ready` when the pane's foreground is
  /// occupied, which is why [evaluateLaunchSurface] exists: the client can say
  /// which condition failed instead of relaying a bare refusal.
  Future<AgentInfo?> agentStart({
    required String name,
    required String kind,
    required String paneId,
    List<String>? args,
    int? timeoutMs,
  }) async {
    final result = await _call(HerdrMethod.agentStart, {
      'name': name,
      'kind': kind,
      'pane_id': paneId,
      'args': ?args,
      'timeout_ms': ?timeoutMs,
    });
    final agent = result.resultMap?['agent'];
    return agent is Map
        ? AgentInfo.fromJson(agent.cast<String, Object?>())
        : null;
  }

  /// Writes literal text into a pane WITHOUT submitting it.
  ///
  /// The safe half of input: nothing here can execute, so a person can see
  /// exactly what landed before deciding to run it. Enter is a separate call —
  /// see [agentSendKeys].
  Future<void> paneSendText({
    required String paneId,
    required String text,
  }) =>
      _call(HerdrMethod.paneSendText, {'pane_id': paneId, 'text': text});

  /// Names an already-detected agent; a null [name] clears it.
  Future<void> agentRename({required String target, String? name}) =>
      _call(HerdrMethod.agentRename, {'target': target, 'name': name});

  /// Pane ids the daemon currently reports.
  ///
  /// This is the liveness census the board needs: without it, a row whose pane
  /// has gone is indistinguishable from one that is merely idle. Returning
  /// null on failure is the honest answer — inferring death from missing
  /// evidence would paint the whole board red the moment a request failed.
  Future<Set<String>?> livePaneIds() async {
    try {
      final result = await _call(HerdrMethod.paneList);
      final panes = result.resultMap?['panes'];
      if (panes is! List) return null;
      return panes
          .whereType<Map<Object?, Object?>>()
          .map((p) => p['pane_id'])
          .whereType<String>()
          .toSet();
    } on Object {
      return null;
    }
  }

  /// The board, ready to render.
  Future<AgentList> board() async {
    final agents = await agentList();
    final census = await livePaneIds();
    return AgentList(agents: agents, livePaneIds: census);
  }

  /// Every workspace the daemon knows about.
  Future<List<WorkspaceInfo>> workspaceList() async {
    final result = await _call(HerdrMethod.workspaceList);
    return _decodeList(result, 'workspaces', WorkspaceInfo.fromJson);
  }

  /// Tabs, optionally narrowed to one workspace.
  ///
  /// The filter is the daemon's, not ours: passing it means the reply cannot
  /// disagree with itself about which workspace a tab is in.
  Future<List<TabInfo>> tabList({String? workspaceId}) async {
    final result = await _call(HerdrMethod.tabList, {
      'workspace_id': ?workspaceId,
    });
    return _decodeList(result, 'tabs', TabInfo.fromJson);
  }

  /// Panes, optionally narrowed to one workspace.
  Future<List<PaneInfo>> paneList({String? workspaceId}) async {
    final result = await _call(HerdrMethod.paneList, {
      'workspace_id': ?workspaceId,
    });
    return _decodeList(result, 'panes', PaneInfo.fromJson);
  }

  /// The whole navigation tree, in one round of three requests.
  ///
  /// Sequential rather than concurrent, and that is a deliberate trade: the
  /// socket accepts exactly one request per connection, so three parallel calls
  /// are three SSH channels competing with the event subscription for the same
  /// link. Three short round trips on a LAN is not the bottleneck; a saturated
  /// channel that makes the terminal stutter is.
  Future<WorkspaceTree> workspaceTree() async {
    final workspaces = await workspaceList();
    final tabs = await tabList();
    final panes = await paneList();
    return WorkspaceTree.join(
      workspaces: workspaces,
      tabs: tabs,
      panes: panes,
    );
  }

  /// One tab's split geometry, as the daemon computed it.
  ///
  /// [paneId] is only an address: the reply describes the WHOLE tab the pane
  /// lives in, in the daemon's own cells. Passing null asks about whatever pane
  /// the machine currently has focused, which is not the same question.
  Future<TabLayout> paneLayout({String? paneId}) async {
    final result = await _call(HerdrMethod.paneLayout, {
      'pane_id': ?paneId,
    });
    final layout = result.resultMap?['layout'];
    if (layout is! Map) return TabLayout.empty();
    return TabLayout.fromJson(layout.cast<String, Object?>());
  }

  /// Moves the daemon's own focus to a pane, tab, or workspace.
  ///
  /// These change the state of the machine the user is looking at elsewhere —
  /// the desktop herdr UI follows them — so they are explicit actions in the UI
  /// rather than a side effect of opening a terminal here.
  Future<void> focusPane(String paneId) =>
      _call(HerdrMethod.paneFocus, {'pane_id': paneId});

  Future<void> focusTab(String tabId) =>
      _call(HerdrMethod.tabFocus, {'tab_id': tabId});

  Future<void> focusWorkspace(String workspaceId) =>
      _call(HerdrMethod.workspaceFocus, {'workspace_id': workspaceId});

  List<T> _decodeList<T>(
    HerdrSuccess result,
    String key,
    T Function(Map<String, Object?>) fromJson,
  ) {
    final raw = result.resultMap?[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((e) => fromJson(e.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// Whether the daemon implements a method.
  ///
  /// Attempts it once and reads the error. That is the supported contract —
  /// herdr's docs say to ignore unknown fields and treat unsupported methods as
  /// ordinary errors — and it beats comparing version numbers, which the daemon
  /// does not negotiate at all.
  Future<bool> supports(String method, [Map<String, Object?>? params]) async {
    try {
      await _call(method, params);
      return true;
    } on HerdrApiException catch (e) {
      if (e.isUnknownMethod) return false;
      // Reachable method, rejected arguments: the feature exists.
      return true;
    }
  }

  /// Subscribes to events, returning the ack plus the live event stream.
  ///
  /// The caller MUST handle the bootstrap gap: events that arrive while a
  /// snapshot is in flight have to be buffered and replayed over it, or a
  /// change that lands mid-refresh is lost. That ordering lives one layer up;
  /// this only opens the channel.
  Future<({String? ackType, Stream<String> events})> subscribe(
    List<Map<String, Object?>> subscriptions,
  ) async {
    final id = 'hp-sub${_seq++}';
    final duplex = await _transport.openDuplex(
      HerdrRequest(HerdrMethod.eventsSubscribe, {
        'subscriptions': subscriptions,
      }).encode(id),
    );

    final first = Completer<String?>();
    final broadcast = duplex.lines.asBroadcastStream();

    final sub = broadcast.listen((line) {
      if (first.isCompleted) return;
      try {
        final reply = HerdrReply.decode(line);
        if (reply is HerdrSuccess) {
          first.complete(reply.resultType);
        } else if (reply is HerdrFailure) {
          first.completeError(
            HerdrApiException(code: reply.code, message: reply.message),
          );
        }
      } on Object {
        // Not an envelope — leave the completer open for the real ack.
      }
    });

    // If the stream ends before an ack, do not hang forever.
    unawaited(
      duplex.done.whenComplete(() {
        if (!first.isCompleted) {
          first.completeError(
            HerdrTransportException(
              TransportFailure.streamClosed,
              'the event stream closed before acknowledging',
            ),
          );
        }
        unawaited(sub.cancel());
      }),
    );

    final ackType = await first.future.timeout(const Duration(seconds: 15));
    return (ackType: ackType, events: broadcast);
  }

  Future<void> close() => _transport.close();

  static int? _asInt(Object? v) => switch (v) {
        int() => v,
        String() => int.tryParse(v),
        _ => null,
      };
}

/// Extracts the agent-status change carried by an event line, if any.
///
/// Event envelopes arrive in more than one shape across daemon versions — a
/// string `event` with a `data` object, an object `event`, or a bare `type` —
/// and names appear both dotted and snake_case. Normalising all of that here
/// means the layer above sees one shape and cannot be surprised by a rename.
({String kind, String? paneId})? parseEventEnvelope(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;

  final rawKind = decoded['event'] ?? decoded['type'] ?? decoded['kind'];
  final kind = switch (rawKind) {
    final String s => s,
    final Map<Object?, Object?> m when m['type'] is String =>
      m['type']! as String,
    _ => null,
  };
  if (kind == null) return null;

  // Dotted on `events.subscribe`, snake_case on `events.wait`.
  final normalised = kind.replaceAll('_', '.');

  String? paneId;
  for (final source in [decoded, decoded['data']]) {
    if (source is Map && source['pane_id'] is String) {
      paneId = source['pane_id']! as String;
      break;
    }
  }

  return (kind: normalised, paneId: paneId);
}
