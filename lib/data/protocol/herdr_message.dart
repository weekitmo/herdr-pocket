/// Wire types for herdr's socket API.
///
/// Verified against a live herdr 0.9.0 (protocol 22):
///
///   * Requests are NDJSON: `{"id","method","params"}`.
///   * **`params` must be present even when empty** — omitting it is rejected.
///   * A COMMAND connection answers with exactly one line and then closes.
///   * **An error envelope comes back with `id: ""`** — the server does NOT
///     echo the request id. That is why responses are correlated by
///     *connection*, not by id, and why one request per channel is mandatory
///     rather than merely tidy.
///   * There is NO version negotiation. The contract is: ignore unknown
///     fields, and treat an unsupported method as an ordinary error.
library;

import 'dart:convert';

/// Channel/stream kinds the daemon exposes on the same NDJSON framing.
abstract final class HerdrEventType {
  static const subscriptionStarted = 'subscription_started';
  static const terminalFrame = 'terminal.frame';
  static const terminalClosed = 'terminal.closed';
}

/// Methods used by this client. Kept as constants so a typo is a compile error
/// at the call site rather than an `unknown method` from the daemon at runtime.
abstract final class HerdrMethod {
  static const ping = 'ping';
  static const sessionSnapshot = 'session.snapshot';
  static const agentList = 'agent.list';
  static const agentGet = 'agent.get';
  static const agentRead = 'agent.read';
  static const agentStart = 'agent.start';
  static const agentPrompt = 'agent.prompt';
  static const agentSendKeys = 'agent.send_keys';
  static const agentRename = 'agent.rename';
  static const agentFocus = 'agent.focus';
  static const paneRead = 'pane.read';
  static const paneProcessInfo = 'pane.process_info';
  static const paneSendText = 'pane.send_text';
  static const workspaceCreate = 'workspace.create';
  static const worktreeCreate = 'worktree.create';
  static const integrationList = 'integration.list';
  static const paneList = 'pane.list';
  static const paneFocus = 'pane.focus';
  static const paneLayout = 'pane.layout';
  static const workspaceList = 'workspace.list';
  static const workspaceFocus = 'workspace.focus';
  static const tabList = 'tab.list';
  static const tabFocus = 'tab.focus';
  static const worktreeList = 'worktree.list';
  static const eventsSubscribe = 'events.subscribe';
  static const serverReloadConfig = 'server.reload_config';
}

/// A request line awaiting a reply.
class HerdrRequest {
  HerdrRequest(this.method, [this.params]);

  final String method;

  /// Omitted from the wire as `{}` when null — never dropped entirely.
  final Map<String, Object?>? params;

  /// Encodes WITHOUT the trailing newline; the transport adds framing.
  String encode(String id) => jsonEncode({
        'id': id,
        'method': method,
        // `params` is mandatory. Sending `{}` rather than omitting the key is
        // the difference between a reply and a rejection.
        'params': params ?? const <String, Object?>{},
      });

  @override
  String toString() => 'HerdrRequest($method)';
}

/// A decoded reply line.
///
/// Sealed so the success/error split is exhaustive at the call site: a caller
/// cannot accidentally treat an error as a result.
sealed class HerdrReply {
  const HerdrReply();

  /// Parses one NDJSON line into a reply.
  ///
  /// Throws [HerdrProtocolException] when the line is not a JSON object at all,
  /// which means the channel is carrying something other than the API protocol.
  factory HerdrReply.decode(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      throw HerdrProtocolException('reply is not JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw HerdrProtocolException('reply is not a JSON object: $line');
    }

    // An error envelope carries id:"" — accept whatever it says.
    final id = decoded['id'] is String ? decoded['id'] as String : '';

    final error = decoded['error'];
    if (error is Map) {
      return HerdrFailure(
        id: id,
        code: error['code'] is String ? error['code'] as String : 'unknown',
        message: error['message'] is String ? error['message'] as String : '',
      );
    }

    return HerdrSuccess(id: id, result: decoded['result']);
  }
}

class HerdrSuccess extends HerdrReply {
  const HerdrSuccess({required this.id, required this.result});

  final String id;
  final Object? result;

  /// The `type` discriminator most herdr results carry, e.g. `agent_list`.
  String? get resultType {
    final r = result;
    if (r is Map && r['type'] is String) return r['type']! as String;
    return null;
  }

  Map<String, Object?>? get resultMap {
    final r = result;
    return r is Map ? r.cast<String, Object?>() : null;
  }

  @override
  String toString() => 'HerdrSuccess($id, type=$resultType)';
}

class HerdrFailure extends HerdrReply {
  const HerdrFailure({
    required this.id,
    required this.code,
    required this.message,
  });

  /// Always empty in practice: the daemon does not echo the request id on
  /// errors.
  final String id;

  /// Machine-readable code, e.g. `invalid_params`, `server_unavailable`.
  final String code;

  final String message;

  @override
  String toString() => 'HerdrFailure($code: $message)';
}

/// The line was not a herdr API message.
class HerdrProtocolException implements Exception {
  HerdrProtocolException(this.message);
  final String message;
  @override
  String toString() => 'HerdrProtocolException: $message';
}

/// A typed error response from the daemon.
class HerdrApiException implements Exception {
  HerdrApiException({required this.code, required this.message});

  final String code;
  final String message;

  /// True when the daemon does not implement the method at all.
  ///
  /// Measured against a live herdr 0.9.0 (protocol 22). Calling an unknown
  /// method returns:
  ///
  /// ```json
  /// {"id":"","error":{"code":"invalid_request",
  ///  "message":"invalid request: unknown variant `pane.stream`, expected one
  ///   of `ping`, `server.stop`, ..."}}
  /// ```
  ///
  /// Two things worth noting. First, the discriminator is the phrase
  /// **`unknown variant`** in the message — the CODE is `invalid_request`,
  /// which the daemon also uses for perfectly valid methods with bad
  /// arguments, so keying on the code alone would report every argument error
  /// as a missing feature. Second, the message enumerates every method the
  /// daemon does support (104 of them on protocol 22), which makes it a free
  /// capability listing.
  ///
  /// This is the ONLY honest way to detect an unsupported feature: herdr has no
  /// version negotiation and its docs say to treat unsupported methods as
  /// ordinary errors. Feature-detect by *attempting*, never by version number.
  bool get isUnknownMethod => message.contains('unknown variant');

  /// The methods the daemon listed as valid, when the error was an unknown
  /// variant. Empty otherwise.
  ///
  /// The FIRST backtick-quoted token in the message is the offending method
  /// itself; everything after it is the daemon's own list of what it does
  /// support, so it is dropped.
  List<String> get knownMethods {
    if (!isUnknownMethod) return const [];
    final all = RegExp('`([^`]+)`')
        .allMatches(message)
        .map((m) => m.group(1)!)
        .toList(growable: false);
    return all.length <= 1 ? const [] : all.sublist(1);
  }

  @override
  String toString() => 'HerdrApiException($code: $message)';
}
