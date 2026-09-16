/// What can be done with a file in the browser, and how it is described.
///
/// Pure on purpose: which rows a file offers, what MIME type its bytes claim,
/// and how its size is phrased are all decisions that can be got wrong in ways
/// a screenshot will not show — and all of them can be tested without a device.
library;

/// The things you can do with one entry in the file browser.
enum FileAction {
  /// Push it to the phone.
  download,
}

/// Which actions [entry] offers.
///
/// A directory offers none: "download a folder" is a recursive archive, which
/// is a different feature with a different failure mode (half a tree), and
/// pretending otherwise would put a button on every row that cannot work.
///
/// A symlink is allowed. It is a regular file's content on the far end — `ls -l`
/// reports `l` because that is what the directory entry says, and SFTP follows
/// the link when it opens it. Refusing it would hide exactly the files build
/// systems like to produce.
List<FileAction> fileActionsFor({required bool isDirectory}) =>
    isDirectory ? const [] : const [FileAction.download];

/// The MIME type to hand Android for [name].
///
/// Android uses this to decide the icon and which apps may open the file after
/// it lands, so `application/octet-stream` for everything would make every
/// download an anonymous blob. The APK case is the one that matters most here:
/// `application/vnd.android.package-archive` is what makes the system offer to
/// INSTALL the thing the agent just built.
///
/// Matched on the lowercased extension, and only the last one — `app.apk.part`
/// is not an APK, and saying it is would have Android offer to install a
/// half-written file.
String mimeTypeForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return _defaultMime;
  return _mimeByExtension[name.substring(dot + 1).toLowerCase()] ?? _defaultMime;
}

const _defaultMime = 'application/octet-stream';

const _mimeByExtension = <String, String>{
  // The one this feature exists for.
  'apk': 'application/vnd.android.package-archive',
  'aab': 'application/octet-stream',
  'ipa': 'application/octet-stream',
  // Media.
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  // Documents and text.
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'log': 'text/plain',
  'json': 'application/json',
  'yaml': 'text/yaml',
  'yml': 'text/yaml',
  'xml': 'application/xml',
  'csv': 'text/csv',
  'html': 'text/html',
  // Archives and the build outputs that show up beside an APK.
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  'jar': 'application/java-archive',
  'so': 'application/octet-stream',
};

/// A byte count in the units an engineer reads.
///
/// BINARY units with their real names. An app that talks to a shell all day and
/// prints `48.3 MB` for a file `ls -l` calls 50331648 is off by 4.9%, and the
/// person most likely to notice is the one this app is for.
///
/// One decimal from MiB up and none below, because the only question a size
/// answers is "roughly how long will this take" — and `1.4 MiB` says that while
/// `1468006 bytes` does not.
String formatByteCount(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}

/// How far along a transfer is, as a 0..1 fraction, or null when it cannot be
/// known.
///
/// Null rather than 0 when [total] is unknown or zero: a bar that never moves
/// because the far end would not say how big the file is reads as a hang, and
/// the honest thing to draw in that case is nothing.
double? transferFraction({required int received, required int? total}) {
  if (total == null || total <= 0) return null;
  final fraction = received / total;
  return fraction.clamp(0, 1).toDouble();
}
