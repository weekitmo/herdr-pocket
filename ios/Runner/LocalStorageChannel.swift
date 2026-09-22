import Flutter
import UIKit

/// The phone's own document picker, and the copy it leaves behind.
///
/// ## Why this is hand-written rather than a package
///
/// The iOS half of "attach a file from this phone". Android's half lives in
/// `MainActivity.kt` behind the SAF `ACTION_OPEN_DOCUMENT` intent, and the two
/// have exactly the same job: put ONE file where Dart can read it as an ordinary
/// path, or say why not. That is a `UIDocumentPickerViewController` and a copy —
/// a package would add a dependency, a plugin registrant entry and its own
/// opinion about the answer's shape, for something the platform already does.
///
/// ## Why the answer is a PATH, and why the copy is bounded
///
/// The alternative — streaming the document across the channel in chunks —
/// would be a hand-written read protocol mirroring the write one, for no
/// benefit: the bytes have to exist somewhere before they go up the wire
/// anyway. So the picker copies into this app's cache and hands back a real
/// path, and everything after that is ordinary Dart file IO and the ordinary
/// SFTP upload.
///
/// The copy is BOUNDED, and it is bounded WHILE COPYING rather than by narrowing
/// the picker. A document picker will happily hand over a 4 GB video, and a
/// phone that freezes while copying one into its own cache is a worse outcome
/// than a refusal. Greying the file out instead would be a worse explanation
/// than "that one is too big" — the user cannot tell a size limit from a
/// permissions problem from a corrupt file.
enum LocalStorageChannel {
  /// Must match `channelName` in `lib/data/local/file_pick.dart` and `CHANNEL`
  /// in `MainActivity.kt`. One channel, two native sides, one Dart client.
  static let name = "dev.maddax.herdrpocket/download_dir"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let handler = Handler()
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "pickFile":
        let maxBytes = (call.arguments as? [String: Any])?["maxBytes"] as? Int ?? 0
        handler.pickFile(maxBytes: maxBytes, result: result)
      default:
        // Everything else on this channel is Android's — the SAF download
        // directory. iOS saves into its own `Documents` folder in pure Dart
        // (`lib/data/local/apple_download_target.dart`), so there is nothing to
        // answer here, and pretending otherwise would be a second, worse way to
        // reach the same folder.
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Holds the presenter so the handler is not deallocated while a picker is up.
  ///
  /// A `setMethodCallHandler` closure is retained by the channel, but the
  /// delegate below is only retained by UIKit through `delegate` — a weak
  /// reference — so without this the answer would be dropped the moment the
  /// picker opened.
  private final class Handler: NSObject, UIDocumentPickerDelegate {
    private var pending: FlutterResult?
    private var maxBytes = 0

    func pickFile(maxBytes: Int, result: @escaping FlutterResult) {
      guard pending == nil else {
        // The same answer Android gives: two pickers would leave the first
        // result unreachable, and the Dart side reports this as a UI bug rather
        // than as a user-facing condition.
        result(FlutterError(code: "busy", message: "a file picker is already open", details: nil))
        return
      }
      guard let presenter = Self.topViewController() else {
        result(FlutterError(code: "pick", message: "no view controller to present from", details: nil))
        return
      }

      pending = result
      self.maxBytes = maxBytes

      // `asCopy: true` is the important argument: it makes the picker hand over
      // a file this app can read directly, instead of a security-scoped URL that
      // needs `startAccessingSecurityScopedResource` and has to be given back.
      // The copy is in a temporary directory iOS owns, so it is copied AGAIN,
      // into our own cache, before the delegate returns — see `ingest`.
      let picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.item],
        asCopy: true
      )
      picker.delegate = self
      picker.allowsMultipleSelection = false
      presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      guard let result = take() else { return }
      guard let url = urls.first else {
        // Documented as "at least one", so this is a platform surprise rather
        // than a user action. Cancellation has its own callback.
        result(FlutterError(code: "pick", message: "the picker returned no document", details: nil))
        return
      }

      // OFF THE MAIN THREAD, like Android's `Thread { }`. A copy of a few
      // hundred megabytes on the main thread is a frozen app, and the file this
      // is most likely to be is a video.
      DispatchQueue.global(qos: .userInitiated).async {
        let answer: Result<[String: Any]?, Error>
        do {
          answer = .success(try self.ingest(url))
        } catch {
          answer = .failure(error)
        }

        // The channel's result must be answered on the thread it was created on.
        DispatchQueue.main.async {
          switch answer {
          case .success(let value):
            result(value)
          case .failure(let error):
            let code = (error as? IngestError)?.channelCode ?? "pick"
            result(FlutterError(code: code, message: error.localizedDescription, details: nil))
          }
        }
      }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      // A cancellation is an ANSWER, not a failure: Dart returns null, the
      // composer stays as it was, and no error is shown.
      take()?(nil)
    }

    /// Clears the pending result and hands it back, so a callback that fires
    /// twice cannot answer the same request twice.
    private func take() -> FlutterResult? {
      let result = pending
      pending = nil
      return result
    }

    /// Copies the picked document into this app's cache.
    ///
    /// Returns nil for a genuine cancellation upstream, which the Dart side
    /// already treats as "the user backed out".
    private func ingest(_ url: URL) throws -> [String: Any]? {
      let name = url.lastPathComponent
      guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      else {
        throw IngestError.unreadable("this app has no cache directory")
      }

      // A subdirectory rather than the cache root: `picked-<name>` would collide
      // with anything else in there, and iOS may purge the cache at any time,
      // which is exactly the lifetime this copy wants.
      let directory = cache.appendingPathComponent("picked", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      // Anything already there under this name is a previous pick of a file with
      // the same name. Replacing it is right: the Dart side reads it
      // immediately, and the alternative is a directory that grows forever.
      let destination = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: destination.path) {
        try? FileManager.default.removeItem(at: destination)
      }

      guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw IngestError.unreadable("could not create \(name) in the cache")
      }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }

      let input = try FileHandle(forReadingFrom: url)
      defer { try? input.close() }

      // CHUNKED, so the bound below is enforced on a file of any size without
      // ever holding it in memory. `maxBytes` of 0 means "no cap" and matches
      // Android, where the same argument is read the same way.
      var written = 0
      while true {
        let chunk = try input.read(upToCount: 1 << 20) ?? Data()
        if chunk.isEmpty { break }
        written += chunk.count
        if maxBytes > 0 && written > maxBytes {
          // Remove the partial copy before reporting: a file left in the cache
          // under the name the user picked is one that looks picked.
          try? FileManager.default.removeItem(at: destination)
          throw IngestError.tooLarge(bytes: written, limit: maxBytes)
        }
        try output.write(contentsOf: chunk)
      }

      return [
        "path": destination.path,
        "name": name,
        "size": written,
      ]
    }

    /// The view controller to present from.
    ///
    /// Found through the ACTIVE SCENE rather than
    /// `UIApplication.shared.keyWindow`, which is deprecated and, under the
    /// scene lifecycle this app uses, returns nil often enough to be useless.
    private static func topViewController() -> UIViewController? {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

      var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        ?? scene?.windows.first?.rootViewController
      while let presented = controller?.presentedViewController {
        controller = presented
      }
      return controller
    }
  }

  /// Why a pick produced no file, in the shape the Dart side reads.
  ///
  /// CONFORMING TO `LocalizedError` RATHER THAN SHADOWING `localizedDescription`.
  /// `Error` already has one, supplied by a protocol extension, and a type that
  /// declares its own property of that name compiles while the extension's is
  /// what `catch` handlers and `FlutterError` actually read — so the message
  /// would silently be "The operation couldn't be completed".
  private enum IngestError: LocalizedError {
    case tooLarge(bytes: Int, limit: Int)
    case unreadable(String)

    /// The `PlatformException.code` Dart switches on in
    /// `lib/data/local/file_pick.dart`. Kept beside the cases so a new one
    /// cannot be added without deciding what the other side calls it.
    var channelCode: String {
      switch self {
      case .tooLarge: return "too_large"
      case .unreadable: return "pick"
      }
    }

    var errorDescription: String? {
      switch self {
      case .tooLarge(let bytes, let limit):
        return "the picked file is \(bytes) bytes, over the \(limit) byte limit"
      case .unreadable(let what):
        return what
      }
    }
  }
}
