import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/remote_bytes.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/domain/files/file_kind.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';
import 'package:herdr_pocket/domain/files/preview_kind.dart';
import 'package:herdr_pocket/domain/files/source_language.dart';
import 'package:herdr_pocket/domain/highlight/syntax.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/download_sheet.dart';
import 'package:herdr_pocket/ui/components/file_actions_sheet.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/markdown/markdown_view.dart';
import 'package:herdr_pocket/ui/pages/files/code_highlight_runner.dart';
import 'package:herdr_pocket/ui/pages/files/code_view.dart';
import 'package:herdr_pocket/ui/pages/files/image_view.dart';

/// How one file is being shown.
///
/// Three modes rather than three pages, because everything except the body is
/// the same: the same read, the same truncation notice, the same title and path,
/// the same failure sentences. A second page would gradually grow its own copy
/// of all of it, and the first symptom would be a `.md` file that reports a read
/// failure differently depending on which view was open.
enum FilePreviewMode {
  /// The file's text, with a line-number gutter, syntax colours and a
  /// selection.
  text,

  /// A Markdown document, rendered.
  markdown,

  /// A picture: bytes decoded by the engine, or an SVG drawn from its text.
  image,
}

/// One file, read from the machine the daemon runs on.
///
/// herdr has no filesystem API, so the bytes come from the connection that is
/// already open — text over a shell command ([RemoteFs]), pictures over SFTP
/// ([RemoteBytes]). Nothing here knows that, which is the point: this page takes
/// a path and shows what came back.
///
/// Nothing here imports Material either: the code view's selection is built from
/// `widgets`-layer primitives by hand, which is the same call the host-key sheet
/// makes for the same reason.
class FilePreviewPage extends ConsumerStatefulWidget {
  /// Shows the file at [path], which must be absolute.
  const FilePreviewPage({required this.path, this.mode, super.key});

  /// Absolute path on the far end.
  final String path;

  /// How to render it, or null for "whatever the file's NAME says".
  ///
  /// Null is the tree's case: a `.png` opens as a picture and a `.py` opens as
  /// text without either caller having to know the rule. A non-null value is the
  /// page's own case — the reader picked "View source" in the sheet — and it
  /// outranks the name, because a person who asked for the source of an SVG
  /// wants the XML, not the picture.
  final FilePreviewMode? mode;

  @override
  ConsumerState<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends ConsumerState<FilePreviewPage> {
  /// The text read, for the modes that read text.
  RemoteReadResult? _text;

  /// The byte read, for the picture that is not text.
  RemoteBytesResult? _bytes;

  /// The tokenised text, or null while it is being computed (and forever, for a
  /// file with no grammar). The code view renders plain until it arrives.
  List<CodeLine>? _lines;

  bool _loading = true;

  /// Which read is the current one.
  ///
  /// Every await below can finish after the page has been rebuilt, replaced by
  /// the other view, or left. Applying a stale answer is the bug the connection
  /// code already carries a generation counter for (`findings.md` §50), and it
  /// looks exactly like a file that shows the wrong colours: a tokeniser for the
  /// previous file landing on this one.
  int _generation = 0;

  String get _name => _basename(widget.path);

  /// Whether the file's bytes are a picture the engine can decode.
  bool get _isRaster => isRasterImageName(_name);

  /// True when the picture's bytes ARE the picture, so they come over SFTP.
  ///
  /// Both halves matter: a `.png` is read as bytes, and a `.png` opened in the
  /// TEXT view is not — a caller that asks for the source of any file gets the
  /// text read, which then reports honestly that the file is not text.
  bool get _readsBytes => _isRaster && _mode == FilePreviewMode.image;

  FilePreviewMode get _mode =>
      widget.mode ??
      (previewKindFor(_name) == FilePreviewKind.image
          ? FilePreviewMode.image
          : FilePreviewMode.text);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _lines = null;
      _text = null;
      _bytes = null;
    });

    // A PDF is decided before any read happens: the bytes are a document this
    // app has no renderer for, and pulling megabytes down onto a phone to show
    // a sentence would be a slow way to say the same thing. The sheet still
    // offers the download, which on both platforms hands the file to something
    // that CAN render it.
    if (isPdfName(_name)) {
      setState(() => _loading = false);
      return;
    }

    if (_readsBytes) {
      await _loadBytes(generation);
    } else {
      await _loadText(generation);
    }
  }

  /// Reads the file as text, then tokenises it in the background.
  Future<void> _loadText(int generation) async {
    final runner = ref.read(remoteRunnerProvider);

    RemoteReadResult result;
    if (runner == null) {
      // The far end cannot run commands at all. That is not a read failure with
      // a cause worth guessing at, so it is reported as one generic failure
      // rather than dressed up as "file not found".
      result = const RemoteReadFailed(
        RemoteReadFailure.notFound,
        'this connection cannot run commands',
      );
    } else {
      try {
        result = await RemoteFs(runner).read(widget.path);
      } on Object catch (e) {
        // The transport threw: the channel died, or the 15 s command deadline
        // expired. Distinct from a read that reported a reason, but the page has
        // nothing different to offer the reader, so it lands on the same notice.
        result = RemoteReadFailed(RemoteReadFailure.unknown, '$e');
      }
    }

    if (!mounted || generation != _generation) return;
    setState(() {
      _text = result;
      _loading = false;
    });

    if (result is RemoteFileContent) {
      unawaited(_highlight(result.content, generation));
    }
  }

  /// Reads the file as bytes, over the channel that moves bytes.
  Future<void> _loadBytes(int generation) async {
    final fetcher = ref.read(remoteFetcherProvider);

    RemoteBytesResult result;
    if (fetcher == null) {
      result = const RemoteBytesFailed(
        RemoteBytesFailure.noChannel,
        'this connection cannot move bytes',
      );
    } else {
      try {
        result = await RemoteBytes(fetcher).read(widget.path);
      } on Object catch (e) {
        result = RemoteBytesFailed(RemoteBytesFailure.unknown, '$e');
      }
    }

    if (!mounted || generation != _generation) return;
    setState(() {
      _bytes = result;
      _loading = false;
    });
  }

  /// Colours the text that is already on screen.
  ///
  /// Deliberately NOT awaited by [_loadText]: the file appears immediately in
  /// one ink and gains its colours a moment later. Holding a 256 KB file back
  /// for the length of its tokenisation would make every open slower to show the
  /// same characters, and a failure here is not worth a sentence — the text is
  /// all there, and colour is decoration.
  Future<void> _highlight(String content, int generation) async {
    final language = sourceLanguageFor(_name);
    if (language == null) return;

    final runner = ref.read(codeHighlightRunnerProvider);
    try {
      final lines = await runner(content, language);
      if (!mounted || generation != _generation) return;
      setState(() => _lines = lines);
    } on Object {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        // Full height for the code, room made by the list's own padding: the
        // bar is transparent and the file scrolls under it.
        obstructs: false,
        leading: HerdrBackButton(label: l10n.navBack),
        actions: [
          HerdrBarButton(
            label: l10n.fileMoreActions,
            onPressed: () => unawaited(_more(context)),
            child: const Icon(CupertinoIcons.ellipsis),
          ),
        ],
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _name,
              style: TextStyle(color: colors.text, fontSize: TextSize.strong),
            ),
            // The basename alone is ambiguous the moment two files share a
            // name, and on a phone there is no address bar to check. The full
            // path is the machine voice, so it is monospace.
            Text(
              widget.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
              ),
            ),
          ],
        ),
      ),
      child: _body(l10n),
    );
  }

  Widget _body(AppLocalizations l10n) {
    final colors = HerdrTheme.of(context);

    if (_loading) {
      return _Notice(
        colors: colors,
        message: l10n.filePreviewLoading,
        isBusy: true,
      );
    }

    // A PDF is answered before any read happens, because there is no read that
    // would help: the bytes are a document this app has no renderer for, and
    // pulling megabytes down onto a phone to show a sentence would be a slow way
    // to say the same thing. The sheet still offers the download, which on both
    // platforms hands the file to something that CAN render it.
    if (isPdfName(_name)) {
      return _Notice(colors: colors, message: l10n.filePdfNoPreview);
    }

    if (_readsBytes) return _imageBody(l10n, colors);

    return switch (_text) {
      // A truncated read is shown. It is the same text the file starts with,
      // and hiding it would make a large log unopenable; the notice says
      // exactly how much was read, which is what keeps it honest. It is the
      // list's FIRST ROW rather than a band above it: a band would pin the
      // notice to the screen and cut the code off below the bar.
      RemoteFileContent(:final content, :final truncated) => _textBody(
          content: content,
          header: truncated ? _QuietNotice(_truncatedLabel(l10n, content)) : null,
          l10n: l10n,
        ),
      RemoteFileEmpty() => _Notice(
          colors: colors,
          message: l10n.filePreviewEmpty,
        ),
      RemoteFileBinary() => _Notice(
          colors: colors,
          message: l10n.filePreviewBinary,
        ),
      RemoteReadFailed() => _Notice(
          colors: colors,
          message: '${l10n.filePreviewFailed}\n${l10n.errorGeneric}',
          isFailure: true,
        ),
      null => _Notice(colors: colors, message: l10n.filePreviewLoading),
    };
  }

  /// The body for a file whose bytes are text.
  Widget _textBody({
    required String content,
    required Widget? header,
    required AppLocalizations l10n,
  }) {
    switch (_mode) {
      case FilePreviewMode.text:
        return CodeView(source: content, lines: _lines, header: header);
      case FilePreviewMode.markdown:
        return MarkdownView(
          source: content,
          // The same notice, in the same place, for the same reason — a
          // rendered document that silently stops halfway is worse than a
          // text file that does, because the omission is invisible.
          header: header,
          onLinkTap: (url) => _copyLink(url, l10n),
        );
      case FilePreviewMode.image:
        // Only an SVG can be here: a raster image never reaches the text read.
        // Malformed XML is a real possibility — half-written files exist — and
        // `errorBuilder` is what keeps that from being a red screen.
        return ImagePreview(
          child: SvgPicture.string(
            content,
            errorBuilder: (context, error, stack) => Center(
              child: Text(
                l10n.fileImageUnreadable,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: HerdrTheme.of(context).statusTextDied,
                  fontSize: TextSize.strong,
                  height: 1.4,
                ),
              ),
            ),
          ),
        );
    }
  }

  /// The body for a file whose bytes are a picture.
  Widget _imageBody(AppLocalizations l10n, HerdrColors colors) {
    return switch (_bytes) {
      RemoteBytesData(:final bytes) => ImagePreview(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            // The DECODE cap, not the transfer cap: see [ImagePreview]. The
            // engine does not upscale, so a small image is untouched.
            cacheWidth: ImagePreview.maxDecodeWidth,
            errorBuilder: (context, error, stack) => Center(
              child: Text(
                l10n.fileImageUnreadable,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.statusTextDied,
                  fontSize: TextSize.strong,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      RemoteBytesTooLarge(:final sizeBytes) => _Notice(
          colors: colors,
          message: sizeBytes == null
              ? l10n.fileImageTooLargeUnknown
              : l10n.fileImageTooLarge(formatByteCount(sizeBytes)),
        ),
      RemoteBytesFailed(:final reason) => _Notice(
          colors: colors,
          message: _bytesFailedLabel(reason, l10n),
          isFailure: true,
        ),
      null => _Notice(
          colors: colors,
          message: l10n.filePreviewLoading,
          isBusy: true,
        ),
    };
  }

  /// The sentence for a failed byte read.
  ///
  /// Each reason gets its own, for the reason the enum exists: "this host has no
  /// SFTP subsystem" is one line in `sshd_config`, and a user told only "could
  /// not read" retries forever.
  String _bytesFailedLabel(RemoteBytesFailure reason, AppLocalizations l10n) =>
      switch (reason) {
        RemoteBytesFailure.noChannel => l10n.fileImageLoadFailed,
        RemoteBytesFailure.sftpUnavailable => l10n.downloadFailedSftp,
        RemoteBytesFailure.isDirectory => l10n.filePreviewFailed,
        RemoteBytesFailure.notFound => l10n.fileImageLoadFailed,
        RemoteBytesFailure.connectionLost => l10n.errorGeneric,
        RemoteBytesFailure.unknown => l10n.fileImageLoadFailed,
      };

  /// Opens the same sheet the file tree opens, with the rows this page can
  /// actually offer.
  ///
  /// Switching between the views REPLACES the page rather than pushing on top
  /// of it. All the views are the same file seen two ways, and a back button
  /// that undoes a view switch would make "go back" mean "I was in the wrong
  /// view" — the back button is how you leave the file.
  Future<void> _more(BuildContext context) async {
    final name = _name;
    final mode = _mode;
    final content = switch (_text) {
      RemoteFileContent(:final content) => content,
      _ => null,
    };
    final canDownload = ref.read(
      settingsProvider.select((s) => s.fileTransferEnabled),
    );
    final isSvg = isSvgName(name);

    final action = await showFileMoreActions(
      context,
      name: name,
      path: widget.path,
      markdownPreview: mode == FilePreviewMode.text && isMarkdownName(name),
      imagePreview: mode == FilePreviewMode.text && isSvg,
      viewText: mode == FilePreviewMode.markdown ||
          (mode == FilePreviewMode.image && isSvg),
      copyText: mode == FilePreviewMode.text && content != null,
      download: canDownload && fileActionsFor(isDirectory: false).isNotEmpty,
    );
    if (!context.mounted || action == null) return;

    switch (action) {
      case FileMoreAction.previewMarkdown:
        _replaceMode(context, FilePreviewMode.markdown);
      case FileMoreAction.previewImage:
        _replaceMode(context, FilePreviewMode.image);
      case FileMoreAction.viewText:
        _replaceMode(context, FilePreviewMode.text);
      case FileMoreAction.copyText:
        if (content != null) _copyAll(content);
      case FileMoreAction.info:
        await showFileInfo(context, name: name, path: widget.path);
      case FileMoreAction.download:
        await showDownloadSheet(
          context,
          remotePath: widget.path,
          fileName: name,
        );
    }
  }

  void _replaceMode(BuildContext context, FilePreviewMode mode) {
    if (mode == _mode) return;
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute<void>(
        builder: (_) => FilePreviewPage(path: widget.path, mode: mode),
      ),
    );
  }

  /// Copies the WHOLE file, which is a different promise from the selection.
  ///
  /// The code view's own selection is a `SelectableRegion` over a lazily built
  /// list: only the rows that have been built are selectable, so "select all"
  /// covers what is on screen plus what was scrolled past — not necessarily the
  /// file. This row is the one that copies the file, and it is here rather than
  /// left implicit because the difference is invisible until someone pastes
  /// half a file into a chat.
  void _copyAll(String content) {
    unawaited(Clipboard.setData(ClipboardData(text: content)));
    unawaited(HapticFeedback.selectionClick());
    showHerdrToast(context, AppLocalizations.of(context).fileTextCopied);
  }

  /// A link from a rendered document.
  ///
  /// COPIED, not opened. There is no browser in this app and no URL-launching
  /// plugin, and the links in a README are usually one of two things: a project
  /// URL the reader wants somewhere else, or a relative path that means nothing
  /// outside the repository. Both are served by the system clipboard, which is
  /// also the only one of the two that works with no network at all.
  void _copyLink(String url, AppLocalizations l10n) {
    unawaited(Clipboard.setData(ClipboardData(text: url)));
    showHerdrToast(context, l10n.markdownLinkCopied);
  }
}

/// "Showing the first N KB" — N is what was read, rounded up.
///
/// Derived from the text that actually arrived rather than from the configured
/// limit, so the number cannot drift away from the truth if the limit changes.
String _truncatedLabel(AppLocalizations l10n, String content) {
  final kb = (content.length + 1023) ~/ 1024;
  return l10n.filePreviewTruncated(kb);
}

/// A one-line note above the content. Quiet by design: it is a statement about
/// how much was read, not a problem.
class _QuietNotice extends StatelessWidget {
  const _QuietNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.sm,
      ),
      color: colors.surfaceRaised,
      child: Text(
        message,
        style: TextStyle(color: colors.textDim, fontSize: TextSize.meta),
      ),
    );
  }
}

/// A centred message: empty, binary, loading, or failed.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.colors,
    required this.message,
    this.isBusy = false,
    this.isFailure = false,
  });

  final HerdrColors colors;
  final String message;
  final bool isBusy;
  final bool isFailure;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isBusy) ...[
              CupertinoActivityIndicator(color: colors.textDim),
              const SizedBox(height: Space.lg),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isFailure ? colors.statusTextDied : colors.textDim,
                fontSize: TextSize.strong,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last component of a path, for the title.
///
/// Handles a trailing slash and the root, so the title is never empty.
String _basename(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  final name = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  return name.isEmpty ? trimmed : name;
}
