import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/host_store.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loaded once during bootstrap and overridden in `main`.
///
/// Reading shared preferences is async and the app needs the result before the
/// first frame — a board that renders "connecting" and then swaps to a
/// different host is worse than one that waits a few milliseconds.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  ),
);

final hostStoreProvider = Provider<HostStore>(
  (ref) => HostStore(ref.watch(sharedPreferencesProvider)),
);

final hostKeyStoreProvider = Provider<HostKeyStore>((ref) => const HostKeyStore());

final hostSecretsStoreProvider =
    Provider<HostSecretsStore>((ref) => const HostSecretsStore());

/// Every saved host, in the order the user arranged them.
class HostListNotifier extends Notifier<List<HostProfile>> {
  @override
  List<HostProfile> build() => ref.watch(hostStoreProvider).load();

  Future<void> add(HostProfile profile) async {
    state = [...state, profile];
    await ref.read(hostStoreProvider).save(state);
  }

  Future<void> update(HostProfile profile) async {
    state = [
      for (final p in state)
        if (p.id == profile.id) profile else p,
    ];
    await ref.read(hostStoreProvider).save(state);
  }

  Future<void> remove(String id) async {
    state = state.where((p) => p.id != id).toList(growable: false);
    final store = ref.read(hostStoreProvider);
    await store.save(state);
    // Forget the secrets and the pin too. Leaving them behind would mean a
    // re-added host silently trusting a key the user thought they deleted.
    await ref.read(hostSecretsStoreProvider).delete(id);
  }
}

final hostListProvider =
    NotifierProvider<HostListNotifier, List<HostProfile>>(HostListNotifier.new);

/// The host the app is pointed at.
///
/// On desktop the local machine is always available and is the default, so a
/// fresh install is useful immediately. On a phone there is nothing to default
/// to — local means "this phone", which has no daemon — so it starts empty and
/// the board says so rather than failing confusingly.
final selectedHostIdProvider =
    NotifierProvider<SelectedHostIdNotifier, String?>(SelectedHostIdNotifier.new);

class SelectedHostIdNotifier extends Notifier<String?> {
  @override
  String? build() => ref.watch(hostStoreProvider).selectedId();

  Future<void> select(String? id) async {
    state = id;
    await ref.read(hostStoreProvider).select(id);
  }
}

/// The resolved host, local fallback included.
final currentHostProvider = Provider<HostProfile?>((ref) {
  final hosts = ref.watch(hostListProvider);
  final selectedId = ref.watch(selectedHostIdProvider);

  final selected = hosts.where((h) => h.id == selectedId).firstOrNull;
  if (selected != null) return selected;

  // No explicit choice: prefer a saved host.
  if (hosts.isNotEmpty) return hosts.first;

  // Otherwise fall back to "this machine" ONLY where a daemon could actually be
  // running on it. A phone defaulting to localhost is a phone that tries to
  // open a socket path that cannot exist and then shows the user a failure on
  // first launch — which is a worse first impression than an honest empty
  // board telling them to add a machine.
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    return HostStore.localProfile;
  }
  return null;
});

/// Whether the user has asked for a connection in this session.
///
/// A COUNTER rather than a bool, because "connect" is an action and not a
/// state: pressing it twice means "try again", and a bool would swallow the
/// second press as a no-op. Every increment re-runs the connection provider's
/// build, which is exactly one fresh dial.
///
/// It starts at zero, which is what makes launching the app quiet. The
/// alternative — dialling on launch and disabling the button — would put the
/// decision somewhere the user cannot see it.
class ConnectRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Asks for a connection (or another attempt at one).
  void request() => state = state + 1;
}

final connectRequestProvider =
    NotifierProvider<ConnectRequestNotifier, int>(ConnectRequestNotifier.new);

/// A host key the user is being asked about, and the answer channel.
class PendingHostKeyPrompt {
  PendingHostKeyPrompt({
    required this.prompt,
    required this.previous,
    required this.completer,
  });

  final HostKeyPrompt prompt;

  /// The pin we already hold, when the key CHANGED. Null on first contact.
  final HostKeyRecord? previous;

  final Completer<HostKeyDecision> completer;
}

/// Carries host-key questions from the SSH handshake to the UI.
///
/// The handshake is blocked on the answer, and the answer can only come from a
/// human, so this is a request/response pair rather than a stream: the transport
/// awaits [Completer.future] while the UI shows a sheet, and whichever of the
/// two finishes first resolves it.
class HostKeyApprovalNotifier extends Notifier<PendingHostKeyPrompt?> {
  @override
  PendingHostKeyPrompt? build() => null;

  Future<HostKeyDecision> request(
    HostKeyPrompt prompt,
    HostKeyRecord? previous,
  ) {
    // A second connection racing the first must not leave the first awaiting
    // forever; the earlier question is answered by refusing it.
    final existing = state;
    if (existing != null && !existing.completer.isCompleted) {
      existing.completer.complete(HostKeyDecision.reject);
    }

    final pending = PendingHostKeyPrompt(
      prompt: prompt,
      previous: previous,
      completer: Completer<HostKeyDecision>(),
    );
    state = pending;
    return pending.completer.future;
  }

  /// Called by the sheet.
  void resolve(HostKeyDecision decision) {
    final pending = state;
    if (pending == null) return;
    if (!pending.completer.isCompleted) pending.completer.complete(decision);
    state = null;
  }
}

final hostKeyApprovalProvider =
    NotifierProvider<HostKeyApprovalNotifier, PendingHostKeyPrompt?>(
  HostKeyApprovalNotifier.new,
);

/// The same verifier, bound to a provider's own [Ref].
///
/// Exists because [verifyHostKeyWithStores] takes a [Ref] and a
/// `ConsumerState`'s `ref` is a `WidgetRef` — two types that both mean "ask
/// Riverpod" and do not convert. Anything that is not itself a provider (the
/// shell page, which resolves keystore secrets before it can dial) reads this
/// instead of re-implementing the policy.
final hostKeyVerifierProvider = Provider<HostKeyVerifier>(
  (ref) => (prompt) => verifyHostKeyWithStores(ref, prompt),
);

/// The host-key verifier the SSH transport calls.
///
/// Implements the policy: a matching pin is trusted silently, an unknown host
/// asks, and a CHANGED key asks but is presented as the security event it is —
/// the UI is told which of the two it is so it cannot render them the same way.
Future<HostKeyVerdict> verifyHostKeyWithStores(
  Ref ref,
  HostKeyPrompt prompt,
) async {
  final store = ref.read(hostKeyStoreProvider);
  final pinKey = '${prompt.host}:${prompt.port}';

  final check = await checkHostKey(
    store,
    pinKey: pinKey,
    presentedType: prompt.keyType,
    presentedFingerprint: prompt.fingerprint,
  );

  if (check.verdict == HostKeyPinVerdict.trusted) {
    return HostKeyVerdict.trust;
  }

  final decision = await ref
      .read(hostKeyApprovalProvider.notifier)
      .request(prompt, check.pinned);

  switch (decision) {
    case HostKeyDecision.reject:
      return HostKeyVerdict.reject;
    case HostKeyDecision.approveAndRemember:
      await store.save(
        pinKey,
        HostKeyRecord(
          keyType: prompt.keyType,
          fingerprint: prompt.fingerprint,
          approvedAt: DateTime.now(),
        ),
      );
      return HostKeyVerdict.trust;
    case HostKeyDecision.approveOnce:
      return HostKeyVerdict.trust;
  }
}

/// A pane the user asked to open by tapping a notification, waiting for the UI
/// to be in a position to show it.
///
/// A notification tap can arrive before any navigator exists (a cold start) or
/// while a terminal is already open. Holding the request in state rather than
/// navigating from the callback means the shell decides WHEN it can be
/// honoured, instead of a platform callback reaching into the widget tree.
class PendingPaneNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// The pane requested, if any. Paired with the setter so the request reads
  /// as a property rather than a one-armed mutator.
  String? get open => state;

  set open(String paneId) => state = paneId;

  /// Consumes the request, so it is acted on exactly once.
  String? take() {
    final paneId = state;
    state = null;
    return paneId;
  }
}

final pendingPaneProvider =
    NotifierProvider<PendingPaneNotifier, String?>(PendingPaneNotifier.new);
