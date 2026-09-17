import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';

/// The marker that separates a command's stdout from its exit code.
///
/// The command passes the nine characters `\n§EXIT§` to `printf`, which turns
/// the `\n` into a REAL newline — so this constant contains one. That is the
/// point, not an accident: the marker can therefore never begin at offset zero
/// of the output, so the search for it starts at index 1, and a file whose first
/// bytes happen to spell the marker cannot be mistaken for the sentinel.
///
/// The exit code is carried IN the output rather than taken from the channel for
/// two reasons: [RemoteCommandRunner.runCommand] returns stdout and nothing
/// else, so there is no exit status to read, and a pipeline's exit status is its
/// last command's. `printf` rather than `echo`, which is not required to
/// interpret `\n` and on several shells' builtins does not.
const remoteExitMarker = '\n\u00a7EXIT\u00a7';

/// The marker as it appears INSIDE a command string.
///
/// Public so the git client can build the same sentinel rather than keeping a
/// second copy: the two commands' output is split by ONE parser
/// ([splitTrailingSentinel]), so they must agree byte for byte about what the
/// sentinel is.
///
/// `remoteExitMarker` holds a real newline, which is the right shape for OUTPUT —
/// it is what `printf` produces. Putting a real newline into the COMMAND would
/// split it into two shell commands, and the sentinel would never be printed at
/// all. So the command carries the two characters `\` `n`, which `printf`
/// interprets; the shell sees one line and the output still begins with a
/// newline.
///
/// The section signs are LITERAL here, and that is not cosmetic. `printf` is an
/// external binary on macOS and has no `\u` escape — measured on this machine,
/// `printf '\u00a7'` prints the seven characters `\u00a7`, so a `\u`-escaped
/// marker would never be found in the output and EVERY read would report "no
/// exit code". Bash's builtin `printf` does support `\u`, which is exactly what
/// makes this the kind of bug that passes a manual test on one shell and fails
/// on another.
const remoteExitMarkerEscape = r'\n§EXIT§';

/// Printed by the listing command when `ls` itself fails.
///
/// A plain string rather than [remoteExitMarker]: this command has no pipeline
/// to protect an exit status, and `printf`'s own status would be 0 either way,
/// so a marker is all that is needed — and a marker with no leading newline is
/// one that survives being written to a pipe.
const remoteListFailureMarker = '__HERDR_FS_LIST_FAILED__';

/// How many digits an exit code may have. Anything longer following the marker
/// is file content that happened to contain it, not a status code.
const _maxExitCodeDigits = 3;

/// Matches the sentinel and the exit code, ANCHORED TO THE END of the output.
///
/// A regex rather than `indexOf`, for one reason that matters and one that is
/// merely pleasant.
///
/// The one that matters is the `$` anchor. A file whose CONTENT happens to
/// spell the marker must not be mistaken for the sentinel, and only an
/// end-anchored match can promise that: the greedy `[\s\S]*` walks to the LAST
/// candidate and the anchor then rejects it unless it sits at the very end,
/// which is where `printf` writes it and nowhere a file's bytes can be.
///
/// The pleasant one is that the position arithmetic is a match LENGTH rather
/// than an offset hunt. Taking the length of the code group means the leading
/// `[\s\S]*` never has to be reasoned about.
///
/// CORRECTION, 2026-09-11: an earlier version of this comment claimed this Dart
/// VM's `indexOf`/`lastIndexOf` were broken, citing `'\n§EXIT§0'.lastIndexOf('\n§EXIT§') == 0`
/// and `indexOf(…, 1) == -1` as evidence. Both results are CORRECT and
/// documented: the needle genuinely starts at index 0, and a start index means
/// the match may not BEGIN before it — so `indexOf(needle, 1)` returning -1 is
/// the specified answer. Re-measured independently; there is no VM bug. The
/// regex stays because of the anchor, not because of this.
final _sentinelPattern = RegExp(
  '[\\s\\S]*$remoteExitMarker(\\d{1,$_maxExitCodeDigits})\$',
);

/// Splits a command's stdout from the exit code it ends with.
///
/// Returns the body and the code, or `(stdout, null)` when the output does not
/// end in a sentinel AT ALL — which is a real answer, not a parse failure: it
/// means the reply was truncated, or the command never reached its `printf`.
///
/// A sentinel that IS present but is not the last thing in the output is treated
/// as FILE CONTENT rather than as a code. That is the fail-closed direction: a
/// file whose last line happens to spell `§EXIT§7` must not have its exit status
/// invented from that line, and a truncated reply must not be read as a
/// successful short read.
(String, int?) splitTrailingSentinel(String stdout) {
  final match = _sentinelPattern.firstMatch(stdout);
  if (match == null) return (stdout, null);
  // Length from the CODE group, not from the whole match. The greedy prefix is
  // there to find the last candidate, and its length is a property of the
  // input rather than of anything worth reasoning about.
  final digits = match.group(1)!;
  return (
    stdout.substring(0, stdout.length - digits.length - remoteExitMarker.length),
    int.parse(digits),
  );
}

/// Runs the `head` command and splits its output from its exit code.
///
/// Extracted so the byte-limit fallback below can reuse it without duplicating
/// the parsing — the sentinel logic is the part that must exist in exactly one
/// place.
Future<(String, int?)> _readOnce(
  RemoteCommandRunner runner,
  String path,
  int byteCount,
) async {
  // `--` so a path beginning with a dash is a path and not an option.
  // `2>/dev/null` because stderr is discarded by the runner anyway; making it
  // explicit keeps the exit code the only channel interpreted, which is the one
  // thing a shell gets right.
  final out = await runner.runCommand(
    'head -c $byteCount -- ${quoteRemotePath(path)} 2>/dev/null; '
    "printf '$remoteExitMarkerEscape%s' \"\$?\"",
  );
  return splitTrailingSentinel(out);
}

/// How many bytes one read request asks for, over and above the limit.
///
/// ONE. The single extra byte is what makes "there was more" observable: a file
/// of exactly `limit` bytes answers with exactly `limit`, and a larger one
/// answers with `limit + 1`. More than one would be worse, not safer — a file
/// between `limit` and `limit + slack` would then show more than the cap while
/// being labelled truncated, and the label would be the only honest part of it.
const _readSlack = 1;

/// Reads and lists files on the machine the daemon runs on.
///
/// herdr's NDJSON API has no filesystem surface at all — verified against a live
/// 0.9.0, whose method list contains nothing of the kind. So the only honest way
/// to show a file is to ask the SHELL on the far end, over the SSH connection
/// that is already open. [RemoteCommandRunner] is that seam and already exists
/// for connection setup, so this needs no bridge binary and no second port.
class RemoteFs {
  /// Wraps one command runner.
  const RemoteFs(this._runner, {this.maxBytes = defaultMaxBytes});

  /// How much of a file to read by default.
  ///
  /// 256 KB is roughly three thousand lines — more than anyone reads on a
  /// phone, and small enough that the decode is not what the user waits for.
  static const defaultMaxBytes = 262144;

  /// Bytes examined when deciding whether a file is text.
  static const binarySampleBytes = 8192;

  /// Fraction of the sample that may be non-text before a file is called binary.
  static const binaryRatioThreshold = 0.3;

  final RemoteCommandRunner _runner;
  final int maxBytes;

  /// Reads [absolutePath], at most [maxBytes] bytes of it.
  ///
  /// Never throws for a remote failure: a missing file, a directory and a
  /// permission problem are outcomes, not exceptions, and the UI has to say
  /// which one it was. A transport-level failure (the channel died, or the
  /// runner's own 15 s command deadline expired) still throws
  /// [HerdrTransportException] — a different question with a different answer.
  Future<RemoteReadResult> read(String absolutePath, {int? maxBytes}) async {
    final limit = maxBytes ?? this.maxBytes;
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'maxBytes', 'must be positive');
    }

    // Ask for one byte over the cap: that byte is the evidence that the file
    // continues past it.
    //
    // There is deliberately NO retry for a far end that ignores the byte count.
    // With a one-byte margin the two cases are arithmetically disjoint — a
    // complete reply is at most `cap`, an oversized one is exactly `cap + 1` —
    // so a reply is always classified, never guessed at. A larger margin would
    // create the ambiguity it was meant to fix, by making a file between `cap`
    // and `cap + margin` look like a refusal.
    final requestBytes = limit + _readSlack;
    final (content, exitCode) = await _readOnce(
      _runner,
      absolutePath,
      requestBytes,
    );

    if (exitCode == null) {
      return const RemoteReadFailed(
        RemoteReadFailure.unknown,
        'the remote shell did not report an exit code',
      );
    }
    if (exitCode != 0) {
      return RemoteReadFailed(
        classifyRemoteFailure(exitCode),
        'the remote shell exited $exitCode',
      );
    }

    final raw = utf8.encode(content);

    // A file that was empty prints nothing, so `content` is `''`.
    if (raw.isEmpty) return const RemoteFileEmpty();

    // One byte past the cap is the evidence that the file continues; `head`
    // already stopped there, so that byte is dropped rather than shown. Slicing
    // the BYTES rather than the decoded String keeps the text, the byte count
    // and the truncation flag describing the same slice — and it can split a
    // multi-byte character, which is why the decode below is lenient.
    final truncated = raw.length > limit;
    final kept = truncated ? Uint8List.sublistView(raw, 0, limit) : raw;
    // `printf` appends one newline before the marker, so the last byte of a
    // COMPLETE reply is that separator rather than content — unless the read was
    // CUT, in which case the separator is not in the reply at all and dropping a
    // byte would delete a byte of the file.
    final dropNewline = !truncated && kept.last == 0x0A;
    final fileBytes = dropNewline ? Uint8List.sublistView(kept, 0, kept.length - 1) : kept;

    if (looksBinary(fileBytes)) {
      return RemoteFileBinary(
        truncated: truncated,
        byteCount: fileBytes.length,
      );
    }

    // allowMalformed, not strict: a cut at the cap can land inside a UTF-8
    // sequence, and a preview with one replacement character at the end is
    // worth far more than an error page.
    final text = utf8.decode(fileBytes, allowMalformed: true);
    if (text.isEmpty) return const RemoteFileEmpty();

    return RemoteFileContent(
      content: text,
      truncated: truncated,
      byteCount: fileBytes.length,
      fileEndsWithNewline: dropNewline,
    );
  }

  /// Lists one directory level.
  ///
  /// Throws [RemoteFsException] when the directory cannot be read, because a
  /// listing has no useful partial state: an empty list would be shown as "this
  /// folder is empty", which is a different and wrong statement.
  Future<List<RemoteDirEntry>> list(String absolutePath) async {
    // `LC_ALL=C` is not cosmetic: the date columns are PARSED, and a locale
    // that prints `9月 11` puts three tokens where an English month puts two.
    // Pinning it makes the field count a property of the command rather than of
    // whatever the user's shell happens to be set to.
    //
    // The failure marker is a plain string rather than the exit sentinel. `||`
    // only runs it when `ls` failed, and unlike the sentinel it needs no leading
    // newline — measured on this machine, `printf`'s output arrives with the
    // newline already stripped, so a marker that depends on one is a marker that
    // silently disappears.
    final out = await _runner.runCommand(
      'LC_ALL=C ls -lA -- ${quoteRemotePath(absolutePath)} 2>/dev/null '
      "|| printf '$remoteListFailureMarker'",
    );

    // The listing command prints ONLY the sentinel when `ls` fails, so its
    // presence anywhere in the output is the failure signal. Same regex
    // reasoning as [splitTrailingSentinel]: the index APIs cannot be trusted
    // here.
    if (out.contains(remoteListFailureMarker)) {
      throw RemoteFsException(
        RemoteReadFailure.notFound,
        'could not list $absolutePath',
      );
    }

    final entries = <RemoteDirEntry>[];
    for (final line in out.split('\n')) {
      final entry = RemoteDirEntry.parse(line);
      // `-A` already omits these, but a listing that showed the directory
      // inside itself would be a visible bug and the filter is a comparison.
      if (entry == null || entry.name == '.' || entry.name == '..') continue;
      entries.add(entry);
    }

    // Directories first, then names, case-insensitively. The case folding is
    // not cosmetic: a listing that put `README.md` before `Cli` would look
    // broken, and a case-insensitive filesystem on the far end orders
    // differently from this comparison unless both fold.
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }
}

/// Why a remote read failed, in terms the UI can act on.
///
/// Deliberately not a message: classifying by matching on error text is how
/// guidance erodes, and `head` says different things in different locales.
enum RemoteReadFailure {
  /// No such file, or the far end could not be reached at all.
  notFound,

  /// The path is a directory, or otherwise not a regular file.
  isDirectory,

  /// The far end refused.
  permissionDenied,

  /// Anything the exit code does not explain.
  unknown,
}

/// The outcome of [RemoteFs.read].
sealed class RemoteReadResult {
  const RemoteReadResult();
}

/// A file with text in it.
class RemoteFileContent extends RemoteReadResult {
  /// Holds one successfully read text file.
  const RemoteFileContent({
    required this.content,
    required this.byteCount,
    this.truncated = false,
    this.fileEndsWithNewline = true,
  });

  /// The text, with the separator newline that the command added removed.
  final String content;

  /// The FILE's size in bytes, as far as it was read.
  ///
  /// Not the length of the reply: a file that ends with a newline would appear
  /// one byte short if the separator were counted as content.
  final int byteCount;

  final bool truncated;

  /// False when the file's last line has no terminator.
  ///
  /// Carried because the read had to remove one newline to tell the difference
  /// between the file's own and the one the command printed, and the caller
  /// should not have to guess which it was.
  final bool fileEndsWithNewline;
}

/// A real file with nothing in it.
class RemoteFileEmpty extends RemoteReadResult {
  /// The one shape an empty file has.
  const RemoteFileEmpty();
}

/// A file that is not text.
///
/// Its CONTENT is deliberately not carried. Decoding a binary blob and showing
/// the mojibake is worse than showing nothing: it invites the reader to believe
/// it, and it puts control characters into the text layer.
class RemoteFileBinary extends RemoteReadResult {
  /// Holds one binary file's size.
  const RemoteFileBinary({required this.byteCount, this.truncated = false});

  final int byteCount;
  final bool truncated;
}

/// A read that did not produce a file.
class RemoteReadFailed extends RemoteReadResult {
  /// Holds one failure and why.
  const RemoteReadFailed(this.reason, this.detail);

  final RemoteReadFailure reason;

  /// What the shell did, for diagnostics. Not shown to the user: the UI
  /// localises from [reason].
  final String detail;
}

/// A directory listing could not be produced.
class RemoteFsException implements Exception {
  /// Holds one listing failure.
  const RemoteFsException(this.reason, this.message);

  final RemoteReadFailure reason;
  final String message;

  @override
  String toString() => 'RemoteFsException(${reason.name}): $message';
}

/// One entry in a directory listing.
class RemoteDirEntry {
  /// Holds one entry.
  const RemoteDirEntry({
    required this.name,
    required this.isDirectory,
    this.isLink = false,
    this.sizeBytes,
  });

  final String name;

  final bool isDirectory;

  /// A symlink, reported as its own kind.
  ///
  /// It cannot be called a directory from this listing without following it,
  /// and following it would change what a tap does. The far end resolves the
  /// path anyway, so saying "link" and letting activation decide is the honest
  /// option.
  final bool isLink;

  /// Size in bytes for a regular file. Null for a directory, whose `ls -l` size
  /// is a filesystem detail rather than a fact about the contents.
  final int? sizeBytes;

  /// Parses one line of `ls -lA --`, or null when the line carries no entry.
  ///
  /// Anchored on the CLOCK TIME, which is the one column whose shape a filename
  /// almost never has. Everything after it is the name, so a name containing a
  /// run of spaces survives; the size is a fixed number of fields before it.
  ///
  /// The alternative — counting tokens from the end — was tried and is wrong on
  /// this machine's own defaults: a locale that prints the month as `9月` makes
  /// `9月 11 23:28` three tokens where `Sep 11 23:28` is three too, but the
  /// ordering is different, and the size lands on the month. Anchoring removes
  /// the month from the arithmetic rather than trying to predict it.
  ///
  /// Two shapes are refused rather than guessed at, both of which would
  /// otherwise produce a path that does not exist: a name containing a space in
  /// a line with no clock time (an `ls -l` over six months old prints a year
  /// there), and a name containing a newline, which `ls` prints as `?` in the
  /// first place. Neither is a defect in this parser; both are what `-l` output
  /// cannot express.
  static RemoteDirEntry? parse(String line) {
    if (line.length < 12) return null;

    final first = line[0];
    if (!_typeCharacters.contains(first)) return null;

    // ONE split, on runs of whitespace, so padding cannot create empty fields.
    // The columns are then, from the end: name, clock time, day, month, size —
    // and the CLOCK TIME is what the name is anchored on, because it is the one
    // field with a shape a filename almost never has.
    //
    // The real defect this is written against was measured on this machine: a
    // filename whose clock time is `23:28` and whose day column is `9月 11`
    // (three tokens, because that is what a locale with a month suffix prints)
    // must NOT shift the size onto the month. Anchoring on the clock time is
    // what removes the month's token count from the arithmetic entirely.
    final fields = line.split(RegExp(r'\s+')).where((f) => f.isNotEmpty).toList();
    if (fields.length < 8) return null;

    var clock = -1;
    for (var i = fields.length - 2; i >= 3; i--) {
      if (_clockTime.hasMatch(fields[i])) {
        clock = i;
        break;
      }
    }

    final int size;
    var name = fields.last;
    if (clock >= 0) {
      // size, month, day, time — so the size is four fields before the time.
      // size, month, day, time — THREE fields between the size and the clock
      // time, so the size is three before it. The month being one token or two
      // (`Jan` vs `9月`) shifts the month's own index, never this one.
      size = int.tryParse(fields[clock - 3]) ?? 0;
      // Everything after the time is the name. A run of spaces inside a name is
      // therefore preserved, which is the only way `my notes.txt` can come back
      // intact; a name with no space in it is one field either way.
      final from = line.indexOf(fields[clock]) + fields[clock].length;
      name = line.substring(from).trim();
    } else {
      // No clock time at all: a POSIX `ls -l > 6 months old`, which prints the
      // YEAR in that column instead. `size` is then four from the end and the
      // name is the last field, which is right for a name without a space.
      size = int.tryParse(fields[fields.length - 5]) ?? 0;
    }

    final isLink = first == 'l';
    if (isLink) {
      // `-l` appends ` -> target` to a symlink. The name is the entry's identity
      // and the target is not part of it, so the suffix is cut — but only for a
      // link, because `a -> b` is a legal name for a regular file.
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) name = name.substring(0, arrow);
    }

    if (name.isEmpty || name == '.' || name == '..') return null;

    final isDirectory = first == 'd';
    return RemoteDirEntry(
      name: name,
      isDirectory: isDirectory,
      isLink: isLink,
      sizeBytes: isDirectory ? null : size,
    );
  }

  /// `ls -l`'s file-type characters. Anything else means this line is not a
  /// listing entry — a warning from the far end, or a stray line from a shell
  /// startup file.
  static const _typeCharacters = 'd-bcpls';

  /// `HH:MM`, with optional seconds. Deliberately strict: this is the anchor
  /// the name and the size are found from, so matching something else would move
  /// both to the middle of the line.
  static final _clockTime = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$');

  @override
  String toString() => isDirectory ? '$name/' : name;
}

/// Single-quotes [path] so the remote shell hands it back byte-for-byte.
///
/// THE SECURITY-CRITICAL FUNCTION IN THIS FILE. The path comes from a remote
/// listing, so it is attacker-influenceable in principle: a file named
/// `'; rm -rf ~; echo '` has to be a file, not a command.
///
/// Single quotes are the right tool — inside them a POSIX shell expands
/// NOTHING, so `$(…)`, backticks and `$VAR` are all inert — provided the path
/// contains no single quote of its own. Escaping one out of a single-quoted
/// string requires closing the quote, emitting an escaped quote, and reopening
/// (`'` `\'` `'`), which is the standard shape and the only one that is
/// provably correct.
///
/// [requireSafePaneId] in `terminal_control.dart` does the opposite — an
/// allow-list — because pane ids are a closed format and a value failing it is
/// not a pane id at all. A path has no such format: `my notes.txt`, `a"b` and a
/// leading `-` are all legal filenames. So the discipline is the same (never
/// interpolate unverified input) and the technique has to differ.
///
/// NUL, newline and CR are REJECTED rather than escaped. NUL cannot appear in a
/// path at all (POSIX forbids it), and a carriage return or newline is legal in
/// a filename but not representable in the record framing these commands are
/// read through — a command containing one can be read as two commands by
/// anything that re-parses it. Failing loudly beats emitting a shell word we
/// cannot reason about.
String quoteRemotePath(String path) {
  if (path.isEmpty) {
    throw ArgumentError.value(path, 'path', 'must not be empty');
  }
  if (path.contains('\u0000')) {
    throw ArgumentError.value(path, 'path', 'must not contain a NUL byte');
  }
  if (path.contains('\n') || path.contains('\r')) {
    throw ArgumentError.value(path, 'path', 'must not contain a newline');
  }
  return "'${path.replaceAll("'", r"'\''")}'";
}

/// Single-quotes a whole SCRIPT for the shell sshd hands it to.
///
/// WHY THIS IS NOT [quoteRemotePath]. That one refuses newlines, because the
/// commands it quotes are read back out of a framed record and a newline can be
/// mistaken for the end of one. A multi-line script is not read that way — it is
/// WRITTEN in newlines — and single-quoting is exact for every byte a script can
/// contain, so the only thing refused here is the one byte a shell cannot carry
/// at all.
String quoteRemoteScript(String script) {
  if (script.isEmpty) {
    throw ArgumentError.value(script, 'must not be empty');
  }
  if (script.contains('\u0000')) {
    throw ArgumentError.value(script, 'must not contain a NUL byte');
  }
  return "'${script.replaceAll("'", r"'\''")}'";
}

/// Wraps [script] so it runs under a POSIX shell, whatever the login shell is.
///
/// ## The bug this exists for (found on a real phone, 2026-09-17)
///
/// An SSH `exec` request is not run by `sh` — it is run by the user's LOGIN
/// SHELL. On this project's own machine that is **zsh**, and zsh's default
/// `nomatch` option turns an unmatched glob into a fatal error that **aborts
/// the rest of the command**:
///
/// ```text
/// % zsh -c 'echo start; for f in /nope/*/SKILL.md; do :; done; echo end'
/// start
/// zsh:1: no matches found: /nope/*/SKILL.md        ← `end` never runs
/// ```
///
/// Every command in this app until now was glob-free, so nothing noticed. The
/// skills probe is not: it globs two dozen directories that mostly do not
/// exist, and under zsh it died on the first one — taking the trailing sentinel
/// with it, so the app could only report "the remote shell did not finish".
///
/// Handing the script to `/bin/sh` explicitly removes the question. `/bin/sh`
/// is the one path POSIX requires, so it does not depend on the login shell's
/// PATH either.
String posixShellCommand(String script) =>
    '/bin/sh -c ${quoteRemoteScript(script)}';

/// Whether a byte sample is not text.
///
/// Two signals, either sufficient.
///
/// A NUL byte is the strong one — it is what `file(1)` uses and it is very
/// nearly never present in a text file. The second is a proportion of BYTES
/// THAT DO NOT DECODE AS UTF-8, which is what catches formats with no NUL near
/// the head. A PNG is the worked example: its first eight bytes are a lone
/// `0x89` followed by six C0 control bytes, all of which are valid UTF-8
/// *sequences* while being nothing any text file contains. Decoding alone would
/// pass it, so the check is per-sequence: control scalars, unassigned scalars,
/// unpaired surrogates and truncated sequences all count as not-text, and the
/// ratio is over the sample actually available — a forty-byte file that is half
/// control bytes is binary, so dividing by a nominal 8 KB would let short binary
/// stubs through.
///
/// Bytes above 0x7F are NOT counted merely for being high: they are UTF-8 lead
/// and continuation bytes, and a CJK document is the case this app exists to get
/// right. A Chinese README misreported as binary would be a much worse bug than
/// an exotic container file rendered as mojibake.
bool looksBinary(List<int> bytes, {int sampleBytes = RemoteFs.binarySampleBytes}) {
  if (bytes.isEmpty) return false;

  final sample = bytes.length > sampleBytes
      ? bytes.sublist(0, sampleBytes)
      : bytes;

  var nonText = 0;
  var i = 0;
  while (i < sample.length) {
    final b = sample[i];
    if (b == 0) return true;

    if (b < 0x80) {
      if (!_isAsciiText(b)) nonText++;
      i++;
      continue;
    }

    final length = _utf8SequenceLength(b);
    // A truncated sequence at the very end of the sample is not evidence of
    // anything: the cut is ours, not the file's.
    if (length == 0 || i + length > sample.length) {
      nonText++;
      i++;
      continue;
    }
    if (!_isValidUtf8Sequence(sample, i, length)) {
      nonText++;
      i++;
      continue;
    }

    // `C2 80` (U+0080) and `EF BF BE` (U+FFFE) are well-formed and still are not
    // text; a real text file has neither.
    final scalar = _decodeScalar(sample, i, length);
    if (scalar < 0x20 && scalar != 0x09 && scalar != 0x0A && scalar != 0x0D) {
      nonText += length;
    } else if (scalar == 0xFFFE || scalar == 0xFFFF) {
      nonText += length;
    }
    i += length;
  }

  return nonText / sample.length > RemoteFs.binaryRatioThreshold;
}

/// ASCII tab, newline, CR and the printable range. Everything else is "not
/// text" for the purposes of [looksBinary].
bool _isAsciiText(int b) =>
    b == 0x09 ||
    b == 0x0A ||
    b == 0x0D ||
    (b >= 0x20 && b <= 0x7E);

/// 0 when [b] is not a UTF-8 lead byte, otherwise the sequence's total length.
int _utf8SequenceLength(int b) {
  if (b >= 0xC2 && b <= 0xDF) return 2;
  if (b >= 0xE0 && b <= 0xEF) return 3;
  if (b >= 0xF0 && b <= 0xF4) return 4;
  // 0x80–0xBF is a continuation byte with nothing leading it, and 0xC0/0xC1
  // would only ever encode an overlong form.
  return 0;
}

bool _isValidUtf8Sequence(List<int> bytes, int start, int length) {
  for (var k = 1; k < length; k++) {
    final b = bytes[start + k];
    if (b < 0x80 || b > 0xBF) return false;
  }
  return true;
}

int _decodeScalar(List<int> bytes, int start, int length) {
  final first = bytes[start];
  if (length == 2) return ((first & 0x1F) << 6) | (bytes[start + 1] & 0x3F);
  if (length == 3) {
    return ((first & 0x0F) << 12) |
        ((bytes[start + 1] & 0x3F) << 6) |
        (bytes[start + 2] & 0x3F);
  }
  return ((first & 0x07) << 18) |
      ((bytes[start + 1] & 0x3F) << 12) |
      ((bytes[start + 2] & 0x3F) << 6) |
      (bytes[start + 3] & 0x3F);
}

/// Maps the exit code of the read command to a reason.
///
/// `head` exits 1 for "no such file" and for "is a directory" alike — one status
/// for both, because that is what the shared error path gives — so the exit code
/// alone cannot separate them. Rather than pretend otherwise, both land on
/// [RemoteReadFailure.notFound]: telling a user their file is a directory when
/// it is missing would be a confident wrong answer, and the filesystem API
/// cannot actually say which it was either.
RemoteReadFailure classifyRemoteFailure(int exitCode) => switch (exitCode) {
      126 => RemoteReadFailure.permissionDenied,
      127 => RemoteReadFailure.notFound,
      1 => RemoteReadFailure.notFound,
      _ => RemoteReadFailure.unknown,
    };

/// Picks the command runner out of a live connection.
///
/// Null is a real answer, not a loading state: a transport that cannot run
/// commands will never be able to, and the UI needs to say so rather than spin.
/// The local-socket transport is exactly that case.
final remoteRunnerProvider = Provider<RemoteCommandRunner?>(
  (ref) => _runnerOf(ref.watch(connectionProvider).value),
);

RemoteCommandRunner? _runnerOf(ConnectionStatus? status) {
  if (status is! Online) return null;
  // Two steps on purpose. Dart does not promote through a getter, so the test
  // has to happen on a local, and the declared type is what makes the answer
  // "a runner or nothing" rather than "a transport of some kind".
  final Object transport = status.client.transport;
  return transport is RemoteCommandRunner ? transport : null;
}
