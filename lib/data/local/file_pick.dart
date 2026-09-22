import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Getting a file off the PHONE, for the composer's `+`.
///
/// ## Why this is a native picker and not a file browser of our own
///
/// The other half of this app reads the machine's filesystem over SSH, and it
/// would be tempting to reuse that browser here. It would also be wrong: the
/// `+` button means "this file, on the phone in my hand" — a screenshot, a
/// photo, a PDF someone sent me — and the phone's own document picker is the
/// only thing that knows where those live. Android calls it SAF, and the app
/// already talks to it for the download directory.
///
/// ## Why the answer is a PATH
///
/// The native side copies the picked document into the app's cache and hands
/// back a real filesystem path, so the rest of the flow is ordinary Dart file
/// IO and then the ordinary SFTP upload. The alternative — streaming the
/// document across the channel in chunks — would be a hand-written read protocol
/// mirroring the write one, for no benefit: the file has to exist in memory (or
/// on disk) before it goes up the wire anyway.
///
/// The copy is bounded by [pick]'s own [maxBytes], enforced while reading rather
/// than by narrowing the picker: a picker that greys out the file the user meant
/// is a worse explanation than "that one is too big".
class PickedFile {
  const PickedFile({
    required this.path,
    required this.name,
    required this.byteCount,
  });

  /// Where the copy landed, on this phone.
  final String path;

  /// The document's own display name, for the file name we upload it as.
  final String name;

  final int byteCount;
}

/// Why a pick did not produce a file.
enum PickFailure {
  /// A picker is already open. A UI bug rather than a user-facing condition.
  busy,

  /// Larger than the caller's cap.
  tooLarge,

  /// No document picker is wired up on this platform — desktop, or anywhere
  /// the channel has no native side. A real answer rather than an error, and
  /// deliberately not a failure: there is nothing the user did wrong and
  /// nothing they could do differently.
  unsupported,

  /// The picker returned something that could not be read.
  unreadable,

  /// Anything else, with the message kept for diagnostics.
  unknown,
}

class PickException implements Exception {
  const PickException(this.reason, {this.detail});

  final PickFailure reason;
  final String? detail;

  @override
  String toString() =>
      'PickException(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// Opens the system document picker.
abstract interface class PhoneFilePicker {
  /// Returns null when the user backed out — a real answer, not a failure.
  ///
  /// Throws [PickException] when the picker opened and the file could not be
  /// used, because that is a different sentence: "you cancelled" needs no
  /// message, "that file is 400 MB" does.
  Future<PickedFile?> pick({required int maxBytes});
}

/// The implementation, for every platform that has this channel.
///
/// NAMED AFTER THE CHANNEL'S JOB, NOT AFTER ANDROID'S PART OF IT. It used to be
/// `SafFilePicker`, which was accurate while Android was the only side that
/// answered: SAF is Android's Storage Access Framework, and there is no iOS
/// equivalent to name. But the CONTRACT is not Android's — it is "hand back a
/// path to one file on this phone", and both native sides implement exactly
/// that (`MainActivity.kt` with `ACTION_OPEN_DOCUMENT`, `LocalStorageChannel.swift`
/// with `UIDocumentPickerViewController`). One Dart client, because there is one
/// shape of answer.
///
/// Shares `download_dir`'s channel, which is the app's one local-storage
/// channel: it owns the picker in both directions, and a second channel would
/// mean a second place for the pending-picker bookkeeping.
class SystemFilePicker implements PhoneFilePicker {
  SystemFilePicker({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The name every picker call in this app goes through — the same one the
  /// download directory uses, on purpose: one local-storage channel with one
  /// piece of pending-picker bookkeeping behind it.
  static const String channelName = 'dev.maddax.herdrpocket/download_dir';

  final MethodChannel _channel;

  @override
  Future<PickedFile?> pick({required int maxBytes}) async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>(
        'pickFile',
        {'maxBytes': maxBytes},
      );
    } on PlatformException catch (e) {
      throw PickException(_reasonOf(e.code), detail: e.message);
    } on MissingPluginException catch (e) {
      // No handler: a platform without the picker wired up, rather than a bug in
      // the call.
      throw PickException(PickFailure.unsupported, detail: e.message);
    }

    if (answer == null) return null;
    final path = answer['path'];
    final name = answer['name'];
    final size = answer['size'];
    if (path is! String || path.isEmpty) {
      throw const PickException(PickFailure.unreadable);
    }
    return PickedFile(
      path: path,
      name: name is String && name.isNotEmpty ? name : 'file',
      byteCount: size is int ? size : 0,
    );
  }

  static PickFailure _reasonOf(String code) => switch (code) {
    'busy' => PickFailure.busy,
    'too_large' => PickFailure.tooLarge,
    'pick' => PickFailure.unreadable,
    _ => PickFailure.unknown,
  };
}

/// The picker the composer uses.
///
/// A provider rather than a bare constructor so a test can hand the page a fake:
/// a platform channel cannot run under `flutter test`, and the composer's
/// attachment path is worth exercising without a phone.
final phoneFilePickerProvider = Provider<PhoneFilePicker>(
  (ref) => SystemFilePicker(),
);
