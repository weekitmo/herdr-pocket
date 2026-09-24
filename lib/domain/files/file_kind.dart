/// What kind of file a NAME says it is, from the extension alone.
///
/// Pure, and separate from `file_transfer.dart` because that file answers "what
/// can be DONE with this file" — a question about the far end — while this one
/// answers "does this app know how to read it", which is a question about a
/// string. The tree asks the first one for its trailing button and the second
/// one for its long press, and keeping them apart is what stops a `.md` file
/// from being offered a download because it happened to be previewable.
library;

/// Whether [name] is a Markdown document this app can render.
///
/// The LAST extension only: `README.md.txt` is a text file, and `notes.md.bak`
/// is a backup. Case-insensitive, because `README.MD` is the same document and
/// a phone keyboard produces capitals by accident.
///
/// `.mdx` is deliberately absent. It is Markdown plus JSX — usually with
/// import statements and components at the top — and rendering it as plain
/// Markdown would show a page of `import` lines and unexpanded component tags
/// under a heading that looks right, which is worse than not offering the
/// preview at all.
bool isMarkdownName(String name) {
  final extension = extensionOf(name);
  return extension == 'md' || extension == 'markdown';
}

/// The lowercased last extension of [name], or null when it has none.
///
/// Null for a dotfile: `.gitignore` is a file whose NAME starts with a dot, not
/// a file of type `gitignore`, and telling those apart matters to every caller
/// that would otherwise look `gitignore` up in a grammar table. Null for a
/// trailing dot too — `notes.` is a name, not an extension.
///
/// One function rather than one per caller because the rule is subtle and the
/// callers disagree loudly when they drift: a `.md` file that the tree offers a
/// preview for and the preview page refuses to render is a bug with two halves.
String? extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}
