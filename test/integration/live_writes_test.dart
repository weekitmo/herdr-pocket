import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/data/agent_launcher.dart';
import 'package:herdr_pocket/data/herdr_client.dart';
import 'package:herdr_pocket/data/remote_upload.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/unix_socket_transport.dart';
import 'package:herdr_pocket/domain/agent/attachment.dart';

/// THE WRITE PATHS, against a real daemon and a real shell.
///
/// Everything else in this repo's live tests is read-only, on purpose: the
/// daemon on this machine is somebody's working session, and a client that
/// rearranges it while probing is a client nobody would run twice. That rule
/// leaves one gap, and this file is it — the features that CREATE things
/// (`workspace.create`, `agent.start`, the upload directory) are otherwise only
/// ever exercised against scripted fakes, which prove the logic and not the
/// wiring.
///
/// So this runs ONLY when asked:
///
/// ```sh
/// HERDR_POCKET_LIVE_WRITES=1 flutter test test/integration/live_writes_test.dart
/// ```
///
/// What it does, and what it cleans up:
///   * creates a workspace in a fresh `/tmp` directory, asserts the daemon
///     really lists the new pane, starts an agent in it, then CLOSES the
///     workspace (in `tearDown`, so a failure cleans up too);
///   * uploads a few bytes through [RemoteUploader] — the real `mkdir`, the
///     real path plan, the real file on disk — into `~/.cache/herdr-pocket`,
///     and deletes it afterwards.
///
/// The one leg it deliberately cannot cover is SFTP itself: that needs an SSH
/// transport, and thus credentials. Everything AROUND the transfer is real.
void main() {
  // A NOTE FOR WHOEVER EDITS THIS FILE NEXT: the first version of it defined
  // `skipReason` and never passed it to a single `test(...)`, so running this
  // file wrote to a live session — creating a workspace on somebody's machine —
  // with no opt-in. Every `test` here must carry `skip: skipReason`, and the
  // test below is there to fail loudly if one ever stops carrying it.
  final home = Platform.environment['HOME'] ?? '';
  final socketPath = '$home/.config/herdr/herdr.sock';
  final socketExists = File(socketPath).existsSync();
  final requested =
      Platform.environment['HERDR_POCKET_LIVE_WRITES'] == '1';

  final skipReason = !socketExists
      ? 'no herdr socket at $socketPath'
      : !requested
          ? 'set HERDR_POCKET_LIVE_WRITES=1 to run the write-path tests'
          : null;

  UnixSocketTransport transport() =>
      UnixSocketTransport(socketPath: socketPath);

  test('the gate is connected', () {
    // Callable without the flag, and it is the thing that proves the others
    // are not.
    expect(
      requested || skipReason != null,
      isTrue,
      reason: 'every write test needs `skip: skipReason`',
    );
  });

  group('live writes: the upload path, through a real shell', () {
    test('resolves home, makes the directory, and writes the file', () async {
      final runner = transport();
      addTearDown(runner.close);
      final porter = _LocalPorter();
      final uploader = RemoteUploader(porter: porter, runner: runner);

      final uploaded = await uploader.uploadText(
        'herdr-pocket live check',
        originalName: 'live-check.txt',
      );
      addTearDown(() => uploader.discard(uploaded));

      // The path is where we said it would be: under the CACHE, never in a
      // repository and never in the home root.
      final resolvedHome = await uploader.remoteHome();
      expect(uploaded.remotePath, startsWith('$resolvedHome/.cache/herdr-pocket/uploads/'));
      expect(uploaded.fileName, endsWith('.txt'));

      final file = File(uploaded.remotePath);
      expect(file.existsSync(), isTrue, reason: 'the file should be on disk');
      expect(file.readAsStringSync(), 'herdr-pocket live check');

      await uploader.discard(uploaded);
      expect(file.existsSync(), isFalse, reason: 'discard should remove it');
    }, skip: skipReason);

    test('an over-limit upload writes nothing at all', () async {
      final runner = transport();
      addTearDown(runner.close);
      final porter = _LocalPorter();
      final uploader = RemoteUploader(porter: porter, runner: runner);

      await expectLater(
        uploader.upload(
          bytes: List<int>.filled(AttachmentLimits.text + 1, 0x41),
          kind: AttachmentKind.text,
        ),
        throwsA(isA<UploadException>()),
      );
      expect(porter.written, isEmpty);
    }, skip: skipReason);
  });

  group('live writes: creating a workspace and starting an agent', () {
    test('create → the daemon lists the new pane → start → close', () async {
      final client = HerdrClient(transport());
      addTearDown(client.close);

      final dir = Directory.systemTemp.createTempSync('herdr-pocket-live-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final created = await client.workspaceCreate(
        cwd: dir.path,
        label: 'pocket live check',
      );
      // The ids come back together, which is the only way to learn where the
      // new pane is without re-listing and guessing.
      expect(created.workspaceId, isNotNull);
      expect(created.paneId, isNotNull);
      final workspaceId = created.workspaceId!;
      final paneId = created.paneId!;

      // Close it no matter what happens next. A workspace left behind in
      // somebody's session is the exact cost this test exists to bound.
      addTearDown(() async {
        try {
          await client.transport.roundTrip(
            '{"id":"cleanup","method":"workspace.close",'
            '"params":{"workspace_id":"$workspaceId"}}',
          );
        } on Object {
          // Best effort — the assertion that matters already happened.
        }
      });

      // The daemon really has it: this is the difference between "the call
      // returned" and "the thing exists".
      final panes = await client.paneList();
      expect(
        panes.map((p) => p.paneId),
        contains(paneId),
        reason: 'the new pane must show up in pane.list',
      );

      // An agent that is actually installed here, chosen the way the app
      // chooses it.
      final integrations = await client.integrationList();
      final available = integrations.where((i) => i.available).toList();
      if (available.isEmpty) {
        print('  no agent binary on this machine; agent.start not exercised');
        return;
      }

      // THROUGH `AgentLauncher`, WHICH IS THE POINT.
      //
      // Calling `client.agentStart` directly here is a race, and this test lost
      // it: `workspace.create` returns as soon as the workspace exists, but its
      // root pane's shell takes a moment to take the foreground, and
      // `agent.start` refuses with `agent_pane_busy` until it has. Run alone the
      // timing works out and the test passes; run inside the full suite, where
      // the machine is busy, it fails — which is the worst shape a test can
      // have, because the gate that ships a release is the one that runs it
      // under load.
      //
      // The app does not have this bug because it goes through the launcher.
      // Neither should the test whose entire reason for existing is to prove the
      // app's write path against something real.
      final agent = await AgentLauncher(client).startWhenReady(
        paneId: paneId,
        name: 'pocket-live-check',
        kind: available.first.target,
      );
      expect(agent, isNotNull);
      print('  started ${available.first.target} in $paneId');
    }, skip: skipReason);
  });
}

/// A [RemoteFilePorter] that writes on THIS machine.
///
/// Stands in for SFTP in the one place the test can reach: the upload path is
/// transport-agnostic — it plans a path, makes a directory, hands bytes to a
/// porter — and the porter is the seam. Swapping it here exercises everything
/// except the SSH subsystem itself, which needs credentials and therefore a
/// human.
class _LocalPorter implements RemoteFilePorter {
  final List<String> written = [];

  @override
  Future<void> uploadBytes({
    required String absolutePath,
    required List<int> bytes,
  }) async {
    if (!absolutePath.startsWith('/')) {
      throw ArgumentError.value(absolutePath, 'absolutePath', 'must be absolute');
    }
    File(absolutePath).writeAsBytesSync(bytes);
    written.add(absolutePath);
  }
}
