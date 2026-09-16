import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/connection.dart';

import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/attachment.dart';

/// What was uploaded, and where it landed.
class UploadedAttachment {
  const UploadedAttachment({
    required this.remotePath,
    required this.fileName,
    required this.byteCount,
    required this.kind,
  });

  /// Absolute path on the remote machine — what the agent is told about.
  final String remotePath;
  final String fileName;
  final int byteCount;
  final AttachmentKind kind;
}

/// Raised when the upload could not be completed.
class UploadException implements Exception {
  const UploadException(this.reason, {this.detail});

  final UploadFailure reason;
  final String? detail;

  @override
  String toString() => 'UploadException($reason${detail == null ? '' : ': $detail'})';
}

enum UploadFailure {
  /// Refused before any bytes moved — too big, or nothing to send.
  refused,

  /// The remote home could not be determined, so there is no safe place to put
  /// the file.
  noHome,

  /// The directory could not be created.
  noDirectory,

  /// The bytes did not make it.
  transfer,
}

/// Puts bytes on the remote machine where an agent will find them.
///
/// Two legs, because they are two different jobs: a shell `mkdir -p` for the
/// directory (SFTP's mkdir does not create parents, and the path has three
/// levels), then SFTP for the bytes themselves. A shell command is the wrong
/// tool for bytes and SFTP is the wrong tool for "make me this path", so each
/// does the half it is good at.
class RemoteUploader {
  RemoteUploader({required this.porter, required this.runner});

  final RemoteFilePorter porter;
  final RemoteCommandRunner runner;

  /// The remote home directory, resolved once per uploader.
  ///
  /// Asked for rather than assumed: SFTP needs an absolute path, `~` is not
  /// expanded by SFTP, and the login user's home is the one fact the protocol
  /// never tells us.
  Future<String>? _home;

  Future<String> remoteHome() => _home ??= _resolveHome();

  Future<String> _resolveHome() async {
    // `$HOME` first, then the passwd entry: a bare `sh -c` inherits HOME only
    // sometimes (some sshd configurations drop it), and `getent`/`dscl` differ
    // by platform — `cd` prints the answer on both.
    final output = await runner.runCommand(
      r'printf %s "${HOME:-$(cd ~ && pwd)}"',
    );
    final home = output.trim();
    if (home.isEmpty || !home.startsWith('/')) {
      throw const UploadException(UploadFailure.noHome);
    }
    return home;
  }

  /// Uploads [bytes] and answers where they went.
  ///
  /// Throws [UploadException] for every failure — including the refusal, which
  /// is a decision rather than an error but has to reach the same place in the
  /// UI: nothing was sent, and here is why.
  Future<UploadedAttachment> upload({
    required List<int> bytes,
    required AttachmentKind kind,
    AttachmentSource source = AttachmentSource.file,
    String? originalName,
    DateTime? now,
  }) async {
    final refusal = checkAttachment(kind: kind, byteCount: bytes.length);
    if (refusal != null) {
      throw UploadException(UploadFailure.refused, detail: refusal.name);
    }

    final home = await remoteHome();
    final directory = uploadDirectory(home: home);
    final name = attachmentFileName(
      kind: kind,
      source: source,
      now: now ?? DateTime.now(),
      originalName: originalName,
    );
    final path = joinRemotePath(directory, name);

    await _ensureDirectory(directory);

    try {
      await porter.uploadBytes(absolutePath: path, bytes: bytes);
    } on Object catch (e) {
      throw UploadException(UploadFailure.transfer, detail: '$e');
    }

    return UploadedAttachment(
      remotePath: path,
      fileName: name,
      byteCount: bytes.length,
      kind: kind,
    );
  }

  /// `mkdir -p`, with the exit code read rather than assumed.
  ///
  /// The command runner returns stdout and nothing else, so the code travels as
  /// a trailing marker — the same shape [RemoteFs] uses, and the reason
  /// [remoteExitMarkerEscape] exists.
  Future<void> _ensureDirectory(String directory) async {
    final quoted = quoteRemotePath(directory);
    final output = await runner.runCommand(
      'mkdir -p -- $quoted 2>/dev/null; '
      "printf '$remoteExitMarkerEscape%s' \"\$?\"",
    );
    final (_, code) = splitTrailingSentinel(output);
    if (code != 0) {
      throw UploadException(
        UploadFailure.noDirectory,
        detail: '$directory (exit $code)',
      );
    }
  }

  /// Removes an upload. Best effort: a cache file that outlives its use costs
  /// kilobytes, and failing to delete it is not worth an error dialog.
  Future<void> discard(UploadedAttachment attachment) async {
    try {
      await runner.runCommand(
        'rm -f -- ${quoteRemotePath(attachment.remotePath)} 2>/dev/null; true',
      );
    } on Object {
      // Ignored on purpose — see above.
    }
  }

  /// Text from the phone's clipboard, as an upload.
  ///
  /// UTF-8, with no BOM: an agent reading a file with a BOM sees a stray
  /// character at the start of the first line, which is the kind of detail that
  /// makes it misread the first token.
  Future<UploadedAttachment> uploadText(
    String text, {
    AttachmentSource source = AttachmentSource.clipboard,
    String? originalName,
  }) =>
      upload(
        bytes: utf8.encode(text),
        kind: AttachmentKind.text,
        source: source,
        originalName: originalName,
      );
}

/// The uploader for the live connection, or null when there is none.
///
/// Null rather than an exception-throwing stub: the pure-socket transport (used
/// on desktop against a local daemon) genuinely cannot move bytes, and a feature
/// that says "not available here" is better than one that fails at the last
/// step.
final remoteUploaderProvider = Provider<RemoteUploader?>((ref) {
  final status = ref.watch(connectionProvider).value;
  if (status is! Online) return null;
  // Two independent interfaces. Dart cannot promote across two unrelated
  // interfaces — the same limitation `terminal_page.dart` documents — so these
  // are casts, and the `is` checks above them are what make the casts safe.
  final transport = status.client.transport;
  if (transport is! RemoteFilePorter) return null;
  if (transport is! RemoteCommandRunner) return null;
  final porter = transport as RemoteFilePorter;
  final runner = transport as RemoteCommandRunner;
  return RemoteUploader(porter: porter, runner: runner);
});
