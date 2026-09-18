import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/domain/files/file_meta.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/herdr_sheet.dart';
import 'package:herdr_pocket/ui/components/menu_popover.dart' show actionSheetLabel;
import 'package:herdr_pocket/ui/design/tokens.dart';

/// What a long press on a file can lead to.
enum FileMoreAction {
  /// Open the document view of a Markdown file.
  previewMarkdown,

  /// Open the plain-text view — from the document view, "show me the source".
  viewText,

  /// Size, times, permissions, ownership.
  info,

  /// Push the file to the phone.
  download,
}

/// The sheet of things you can do with a file.
///
/// ONE SHEET, TWO DOORS, and the rows are filtered by the door: the file tree
/// offers the Markdown preview of a `.md` file, the preview page offers the
/// SOURCE of the document it is showing, and neither offers the view it is
/// already on. Building two sheets is how the two copies start to differ — one
/// gains an action, the other keeps yesterday's wording.
///
/// [markdownPreview], [viewText] and [download] are the caller's answers, not
/// this function's: only the tree knows whether file transfer is switched on,
/// and only the page knows which view it is. There is deliberately no guard for
/// "nothing to offer": the info row is unconditional, so an empty sheet is
/// impossible — and a guard was written once anyway, silently swallowing the
/// only action a plain `.txt` file had.
Future<FileMoreAction?> showFileMoreActions(
  BuildContext context, {
  required String name,
  required String path,
  bool markdownPreview = false,
  bool viewText = false,
  bool download = false,
}) {
  final l10n = AppLocalizations.of(context);

  return showCupertinoModalPopup<FileMoreAction>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      title: Text(name, style: const TextStyle(fontSize: TextSize.strong)),
      // The path, in the machine voice. The name alone cannot tell two files
      // apart across a project; the path is what the user would use to find it
      // in a terminal.
      message: Text(
        path,
        style: const TextStyle(
          fontFamily: HerdrFonts.mono,
          fontSize: TextSize.meta,
        ),
      ),
      actions: [
        if (markdownPreview)
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.of(sheetContext).pop(FileMoreAction.previewMarkdown),
            child: actionSheetLabel(l10n.fileActionPreviewMarkdown),
          ),
        if (viewText)
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.of(sheetContext).pop(FileMoreAction.viewText),
            child: actionSheetLabel(l10n.fileActionViewText),
          ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(FileMoreAction.info),
          child: actionSheetLabel(l10n.fileActionInfo),
        ),
        if (download)
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.of(sheetContext).pop(FileMoreAction.download),
            child: actionSheetLabel(l10n.fileActionDownload),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: actionSheetLabel(l10n.actionCancel),
      ),
    ),
  );
}

/// Shows one file's metadata, read over the connection that is already open.
///
/// A SHEET RATHER THAN A PAGE, because this is a fact about the file the user
/// is standing next to, not a place to go: it arrives while they wait, and it
/// leaves with the same gesture as every other sheet in the app.
Future<void> showFileInfo(
  BuildContext context, {
  required String name,
  required String path,
}) {
  return showHerdrSheet<void>(
    context: context,
    title: name,
    builder: (_, _) => FileInfoPanel(path: path),
  );
}

/// The rows of the file-info sheet.
///
/// Loads its own metadata, because the sheet is opened while the user is
/// looking at the file and the fetch outlives neither: a failed `stat` is shown
/// as a sentence in the sheet, never as an empty one — "this file has no size"
/// and "the machine did not answer" are different statements.
class FileInfoPanel extends ConsumerStatefulWidget {
  /// Reads the metadata of [path], which must be absolute.
  const FileInfoPanel({required this.path, super.key});

  /// Absolute path on the far end.
  final String path;

  @override
  ConsumerState<FileInfoPanel> createState() => _FileInfoPanelState();
}

class _FileInfoPanelState extends ConsumerState<FileInfoPanel> {
  RemoteFileMeta? _meta;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final runner = ref.read(remoteRunnerProvider);
    if (runner == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final meta = await RemoteFs(runner).stat(widget.path);
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xxl),
        child: Center(child: CupertinoActivityIndicator(color: colors.textDim)),
      );
    }

    final meta = _meta;
    if (meta == null) {
      return Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Text(
          l10n.fileInfoFailed,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.statusTextDied,
            fontSize: TextSize.strong,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(l10n.fileInfoKind, _kindLabel(meta.kind, l10n)),
          // NO size for a directory. `stat` reports the directory RECORD's own
          // size there — 4096 on one filesystem, 96 on another — which is a
          // fact about the filesystem rather than about anything inside it, and
          // a row that looks like a file size but is not one is worse than a
          // missing row.
          if (!meta.isDirectory)
            _row(
              l10n.fileInfoSize,
              formatByteCount(meta.sizeBytes),
              machine: true,
            ),
          _row(
            l10n.fileInfoModified,
            formatFileTimestamp(meta.modified),
            machine: true,
          ),
          _row(
            l10n.fileInfoCreated,
            meta.created == null
                ? l10n.fileInfoCreatedUnknown
                : formatFileTimestamp(meta.created!),
            machine: meta.created != null,
            isFaint: meta.created == null,
          ),
          if (meta.permissions != null)
            _row(l10n.fileInfoPermissions, meta.permissions!, machine: true),
          if (meta.owner != null)
            _row(l10n.fileInfoOwner, meta.owner!, machine: true),
          if (meta.group != null)
            _row(l10n.fileInfoGroup, meta.group!, machine: true),
          _row(l10n.fileInfoPath, widget.path, machine: true),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    String value, {
    bool machine = false,
    bool isFaint = false,
  }) {
    final colors = HerdrTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.sm,
        Space.lg,
        Space.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(
              label,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.note,
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isFaint ? colors.textFaint : colors.text,
                fontSize: TextSize.note,
                fontFamily: machine ? HerdrFonts.mono : null,
                fontFamilyFallback: machine ? HerdrFonts.monoFallback : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _kindLabel(RemoteFileKind kind, AppLocalizations l10n) =>
      switch (kind) {
        RemoteFileKind.file => l10n.fileInfoKindFile,
        RemoteFileKind.directory => l10n.fileInfoKindDirectory,
        RemoteFileKind.link => l10n.fileInfoKindLink,
        RemoteFileKind.other => l10n.fileInfoKindOther,
      };
}

/// Wide enough for the longest label in either language ("Permissions"), and
/// fixed so the values line up as a column rather than each row finding its own
/// starting point.
const double _labelWidth = 96;
