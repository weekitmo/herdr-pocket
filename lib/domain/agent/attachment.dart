/// Turning something on the phone into a file the agent can read.
///
/// The channel is one-way and deliberately dumb: bytes go up over SFTP, and
/// what reaches the agent is a PATH. That is the whole trick — and it is the
/// same one the established clients use, because it is the only one that needs
/// nothing installed on the host: an agent already knows how to read a file.
///
/// Everything here is pure so the decisions can be tested: where the file goes,
/// what it is called, whether it is too big, and what the sentence that mentions
/// it says.
library;

/// What kind of thing is being sent. Decides the extension and the wording.
enum AttachmentKind {
  /// A screenshot or photo.
  image('png'),

  /// Text from the clipboard, written out as a file.
  text('txt'),

  /// Anything else.
  other('bin');

  AttachmentKind(this.defaultExtension);

  final String defaultExtension;
}

/// Why an attachment was refused before any bytes moved.
enum AttachmentRefusal {
  /// Larger than we are willing to push over a phone connection.
  tooLarge,

  /// Nothing to send.
  empty,
}

/// Where an attachment came from. Only used for the file NAME, so the user can
/// tell two screenshots apart in a directory listing.
enum AttachmentSource {
  camera('photo'),
  gallery('image'),
  clipboard('paste'),
  file('file');

  AttachmentSource(this.slug);

  final String slug;
}

/// Size ceilings, per kind.
///
/// Client-side and deliberately low. A phone on cellular pushing 40 MB fails
/// halfway, and a truncated file that keeps its name is worse than a refusal:
/// the agent reads it and answers confidently about half a screenshot.
abstract final class AttachmentLimits {
  /// Screenshots are a few hundred KB; a modern camera photo is a few MB.
  static const int image = 8 * 1024 * 1024;

  /// Clipboard text. Small on purpose — if it is bigger than this, it is not a
  /// snippet, and a file is the wrong shape for it.
  static const int text = 256 * 1024;

  static const int other = 8 * 1024 * 1024;

  static int forKind(AttachmentKind kind) => switch (kind) {
        AttachmentKind.image => image,
        AttachmentKind.text => text,
        AttachmentKind.other => other,
      };
}

/// The directory uploads land in, relative to the remote home.
///
/// Under the CACHE directory, not the repository and not the home root. We are
/// a guest on that machine: dropping files into somebody's working tree would
/// show up in their `git status`, and dropping them in `$HOME` would be clutter
/// they never agreed to. `$XDG_CACHE_HOME` is honoured when it is set, because
/// that is what it is for.
const uploadDirSegments = ['.cache', 'herdr-pocket', 'uploads'];

/// The absolute directory, given the remote home and an optional XDG override.
String uploadDirectory({required String home, String? xdgCacheHome}) {
  final base = (xdgCacheHome?.trim().isNotEmpty ?? false)
      ? xdgCacheHome!.trim()
      : '${_trimSlash(home)}/.cache';
  // `.cache/herdr-pocket/uploads` is rebuilt from the XDG base so the two paths
  // cannot drift into `~/.cache/.cache/...`.
  return '${_trimSlash(base)}/herdr-pocket/uploads';
}

/// The file's name, made safe to paste into a sentence.
///
/// The original name is UNTRUSTED input on its way into an agent's composer:
/// it can carry a path separator, a quote, or a newline (which in a composer is
/// a submission). So it is reduced to a conservative alphabet and given a
/// timestamp prefix, which also makes two screenshots a second apart distinct
/// without a random source.
String attachmentFileName({
  required AttachmentKind kind,
  required AttachmentSource source,
  required DateTime now,
  String? originalName,
}) {
  final extension = _extensionOf(originalName) ?? kind.defaultExtension;
  final slug = _slug(_baseName(originalName)) ?? source.slug;
  final stamp = _stamp(now);
  return '$stamp-$slug.$extension';
}

/// The sentence that tells the agent where the file is.
///
/// Says "local path" in as many words, because an agent that thinks it was
/// handed a URL will try to fetch it. Kept short: this lands in a composer the
/// user is going to send, and a paragraph of preamble per screenshot is noise
/// on every message.
String attachmentPrompt({required String remotePath, required bool isZh}) =>
    isZh
        ? '已保存到你机器上的本地文件：$remotePath —— 请读这个文件。'
        : 'Saved as a local file on your machine: $remotePath — please read it.';

/// Whether these bytes may be sent at all.
AttachmentRefusal? checkAttachment({
  required AttachmentKind kind,
  required int byteCount,
}) {
  if (byteCount <= 0) return AttachmentRefusal.empty;
  if (byteCount > AttachmentLimits.forKind(kind)) {
    return AttachmentRefusal.tooLarge;
  }
  return null;
}

/// Joins a directory and a name into the absolute path SFTP needs.
///
/// SFTP resolves a relative path against the login user's home, which makes
/// "where did my file go" unanswerable — so the caller is given an absolute one
/// and [RemoteFilePorter] rejects anything else.
String joinRemotePath(String directory, String name) =>
    '${_trimSlash(directory)}/${_trimSlash(name, leading: true)}';

String _trimSlash(String s, {bool leading = false}) {
  var out = s.trim();
  if (out.isEmpty) return out;
  if (!leading) {
    while (out.endsWith('/') && out.length > 1) {
      out = out.substring(0, out.length - 1);
    }
  } else {
    while (out.startsWith('/')) {
      out = out.substring(1);
    }
  }
  return out;
}

String? _baseName(String? path) {
  if (path == null) return null;
  final cut = path.split(RegExp(r'[/\\]')).last;
  return cut.isEmpty ? null : cut;
}

String? _extensionOf(String? name) {
  final base = _baseName(name);
  if (base == null) return null;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  final raw = base.substring(dot + 1).toLowerCase();
  // A conservative alphabet only: an extension is used verbatim to build a
  // path, so nothing exotic survives.
  final safe = RegExp(r'^[a-z0-9]{1,5}$').hasMatch(raw) ? raw : null;
  return safe;
}

/// Reduces a name to `[a-z0-9-]`, collapsing runs.
///
/// Returns null when nothing usable is left, so the caller falls back to the
/// source's own slug rather than building a file called `--`.
String? _slug(String? name) {
  if (name == null) return null;
  var stem = name;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  final cleaned = stem
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (cleaned.isEmpty) return null;
  return cleaned.length <= 40 ? cleaned : cleaned.substring(0, 40);
}

/// `20260914-153012`, in LOCAL time.
String _stamp(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
