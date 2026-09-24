/// What kind of thing a file NAME says it is, for the preview page to open.
///
/// Pure, and separate from `file_kind.dart` (which answers "does this app
/// render Markdown?") and from `file_transfer.dart` (which answers "what can be
/// done with this on the far end"). This one answers the question the preview
/// page asks first: **how do I read this file at all**. A `.png` is not read as
/// text — the read decides, because a JPEG's bytes have no text in them; a `.md`
/// is read as text and then rendered; a `.pdf` is read by neither.
library;

import 'package:herdr_pocket/domain/files/file_kind.dart';

/// How a file's bytes become a screen.
enum FilePreviewKind {
  /// Read as text, shown as text. The default, and the answer for every
  /// extension this app has never heard of — a wrong guess here would be a
  /// refusal to open a file the user can plainly see.
  text,

  /// Read as text, rendered as a document.
  markdown,

  /// Read as BYTES, decoded as an image.
  image,

  /// Not opened at all. Shown as an explanation with the way out.
  pdf,
}

/// The kind [name] says it is.
///
/// Case-insensitive, and only the LAST extension: `README.md.txt` is a text
/// file and `photo.jpg.bak` is not a photo, exactly as in [isMarkdownName].
FilePreviewKind previewKindFor(String name) {
  if (isMarkdownName(name)) return FilePreviewKind.markdown;
  if (isPdfName(name)) return FilePreviewKind.pdf;
  // SVG counts as an image even though its bytes are text: the picture is what
  // the reader asked for. Which CHANNEL reads it is a different question, and
  // `isRasterImageName` is where that one is answered.
  if (isSvgName(name) || isRasterImageName(name)) {
    return FilePreviewKind.image;
  }
  return FilePreviewKind.text;
}

/// Whether [name] is an image whose BYTES are the picture.
///
/// SVG is deliberately not in this list even though it is an image: its bytes
/// are XML text, so it is read over the TEXT channel and drawn by the SVG
/// renderer. The distinction is not academic — the byte channel is SFTP (and
/// refuses on a host without it), while the text channel is a shell command.
bool isRasterImageName(String name) {
  final extension = extensionOf(name);
  return extension != null && _imageExtensions.contains(extension);
}

/// Whether [name] is an SVG, which is a picture written in text.
bool isSvgName(String name) => extensionOf(name) == 'svg';

/// Whether [name] is a PDF.
bool isPdfName(String name) => extensionOf(name) == 'pdf';

/// Extensions whose bytes are an image this app can decode.
///
/// The formats `dart:ui` decodes on both platforms: PNG, JPEG, GIF, animated
/// WebP, BMP and WBMP. HEIC is absent on purpose — it decodes on iOS and not
/// reliably on Android's Skia path, and an image that shows on one phone and
/// errors on the other is a bug report nobody can reproduce. It stays a binary
/// file, which at least says so.
///
/// `ico` is absent for the same reason as HEIC but with the opposite result:
/// `dart:ui` does NOT decode it, and a `.ico` that always fails is worse than
/// one that is honestly reported as a binary.
const _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'wbmp',
};
