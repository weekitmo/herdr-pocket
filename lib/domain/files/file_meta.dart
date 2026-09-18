/// Metadata about one file on the far end, and how to read it off a `stat`.
///
/// Pure on purpose. The COMMAND lives in `RemoteFs`; what arrives back is a
/// record whose shape differs between the two `stat` dialects on this project's
/// supported machines, and getting the parse wrong produces a sheet that is
/// confidently wrong — a size of 0, a date in 1970, a birth time that was never
/// recorded shown as the epoch. All of that is testable with a string, so it is
/// tested with a string.
library;

/// What kind of thing a path is, as the permission string's first character
/// says.
enum RemoteFileKind {
  /// A regular file.
  file,

  /// A directory.
  directory,

  /// A symbolic link, when the far end reported one without following it.
  link,

  /// A socket, a device, a fifo — anything else.
  other,
}

/// One file's metadata.
class RemoteFileMeta {
  /// Holds one record.
  const RemoteFileMeta({
    required this.sizeBytes,
    required this.modified,
    this.created,
    this.permissions,
    this.owner,
    this.group,
    this.kind = RemoteFileKind.other,
  });

  /// The file's size in bytes. For a directory this is the directory record's
  /// own size, which is why the info sheet does not offer it for folders.
  final int sizeBytes;

  /// Last modification time, in the phone's own time zone.
  ///
  /// `stat` reports epoch seconds, which have no zone; rendering them in the
  /// phone's zone is the only answer available without asking the far end for
  /// its own, and for a phone talking to its owner's machine the two agree.
  final DateTime modified;

  /// When the file was created, or null when the filesystem does not record it.
  ///
  /// NULL IS THE COMMON CASE, not an error: GNU `stat`'s `%W` prints 0 on every
  /// filesystem that does not carry a birth time (ext4 without `statx` support,
  /// most older Linux filesystems), and 1970-01-01 is not an answer to "when
  /// was this created" — it is the absence of one. The sheet says so in words.
  final DateTime? created;

  /// The symbolic permission string, e.g. `-rw-r--r--`. Null if absent.
  final String? permissions;

  /// Owning user name. Null if absent.
  final String? owner;

  /// Owning group name. Null if absent.
  final String? group;

  /// What the path is, from the permission string's first character.
  final RemoteFileKind kind;

  /// Whether this is a directory.
  bool get isDirectory => kind == RemoteFileKind.directory;
}

/// Parses the body of the metadata command.
///
/// The record is SIX tab-separated fields, in an order this file owns:
///
/// ```text
/// size  mtime  birth  permissions  owner  group
/// ```
///
/// TAB rather than a space, because an owner or a group can contain one and a
/// size cannot contain a tab. Both dialects emit the tab literally (see the
/// command in `RemoteFs`), so this split is exact rather than a guess.
///
/// Returns null when the record is not there or does not have the shape this
/// parser promises — the sheet then says it could not read the metadata, which
/// is true, instead of showing a row of zeroes.
RemoteFileMeta? parseFileMeta(String output) {
  final line = output
      .split('\n')
      .map((l) => l.trimRight())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.isEmpty) return null;

  final fields = line.split('\t');
  if (fields.length < 6) return null;

  final size = int.tryParse(fields[0]);
  final modifiedSeconds = int.tryParse(fields[1]);
  if (size == null || size < 0 || modifiedSeconds == null) return null;

  // 0 is what GNU prints for "this filesystem has no birth time", and it is
  // also what some `stat` builds print for an unreadable one. Neither is a
  // date, so both become null.
  final birthSeconds = int.tryParse(fields[2]);
  final created = birthSeconds == null || birthSeconds <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(birthSeconds * 1000);

  final permissions = fields[3].isEmpty ? null : fields[3];
  final owner = fields[4].isEmpty ? null : fields[4];
  final group = fields[5].isEmpty ? null : fields[5];

  return RemoteFileMeta(
    sizeBytes: size,
    modified: DateTime.fromMillisecondsSinceEpoch(modifiedSeconds * 1000),
    created: created,
    permissions: permissions,
    owner: owner,
    group: group,
    kind: kindFromPermissions(permissions),
  );
}

/// The kind of entry a permission string describes.
///
/// The first character is the file type in every `ls -l`-shaped string: `d` for
/// a directory, `l` for a link, `-` for a regular file. Anything else (`s`, `b`,
/// `c`, `p`) is a real kind of file that this app has nothing useful to say
/// about, so it is [RemoteFileKind.other] rather than a guess.
RemoteFileKind kindFromPermissions(String? permissions) {
  if (permissions == null || permissions.isEmpty) return RemoteFileKind.other;
  return switch (permissions[0]) {
    'd' => RemoteFileKind.directory,
    'l' => RemoteFileKind.link,
    '-' => RemoteFileKind.file,
    _ => RemoteFileKind.other,
  };
}

/// A timestamp as the machine voice writes it: `2026-09-18 06:53`.
///
/// ISO-shaped and year-first, NOT localised. Two reasons, and the second is the
/// load-bearing one: this is data about a computer's filesystem, read beside
/// byte counts and permission strings; and the app already prints relative ages
/// on the board, where a relative age is the useful form. An absolute date's
/// job is to be unambiguous, which is exactly what a locale-dependent
/// `9/18/26` is not.
String formatFileTimestamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
