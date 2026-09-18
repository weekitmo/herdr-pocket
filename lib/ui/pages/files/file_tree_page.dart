import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/domain/files/file_kind.dart';
import 'package:herdr_pocket/domain/files/file_transfer.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/download_sheet.dart';
import 'package:herdr_pocket/ui/components/file_actions_sheet.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/files/file_preview_page.dart';

/// A directory browser: one level per screen.
///
/// One level per screen rather than a tree, and that is the phone-specific
/// decision rather than a limitation: a folded tree on a 360 px-wide screen
/// spends most of its width on indentation and its rows on disclosure triangles,
/// and the whole point of this screen is the NAMES. Pushing a level costs one
/// tap and gives every entry the full width, plus the platform's own back
/// gesture — which is the navigation model the user already has.
class FileTreePage extends ConsumerStatefulWidget {
  /// Browses [path], which must be an absolute directory.
  const FileTreePage({required this.path, super.key});

  /// Absolute directory path on the far end.
  final String path;

  @override
  ConsumerState<FileTreePage> createState() => _FileTreePageState();
}

class _FileTreePageState extends ConsumerState<FileTreePage> {
  List<RemoteDirEntry>? _entries;

  /// The failure to report, held as a FLAG rather than as a localised sentence.
  ///
  /// `_load` runs from `initState`, where there is no inherited widget to look
  /// localisations up from — and there is no way to read them without one, which
  /// is why the message is composed in `build` instead of being captured here.
  /// A `String?` field holding a half-built sentence would also freeze the
  /// language at load time rather than at paint time.
  bool _failed = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });

    final runner = ref.read(remoteRunnerProvider);
    if (runner == null) {
      if (mounted) {
        setState(() {
          _entries = const [];
          _failed = true;
          _loading = false;
        });
      }
      return;
    }

    try {
      final entries = await RemoteFs(runner).list(widget.path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        // A failed listing must not render as "this folder is empty" — those
        // are different statements and only one of them is true.
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _open(RemoteDirEntry entry) async {
    final path = _join(widget.path, entry.name);
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => entry.isDirectory
            ? FileTreePage(path: path)
            : FilePreviewPage(path: path),
      ),
    );
  }

  Future<void> _download(RemoteDirEntry entry) async {
    await showDownloadSheet(
      context,
      remotePath: _join(widget.path, entry.name),
      fileName: entry.name,
    );
  }

  /// Everything else a file can do, behind a long press.
  ///
  /// THE LONG PRESS USED TO BE A SECOND COPY OF THE DOWNLOAD BUTTON, and it was
  /// a poor copy: the same action, at a different size, on a gesture the user
  /// had no way to discover. It is now a DOOR — the place the actions that are
  /// not worth a permanent control live — which is what the pane rows and the
  /// machine rows already do (AGENTS.md, Phase 11). The trailing button keeps
  /// download one tap away, so the sheet's download row is for reachability
  /// rather than for meaning, exactly as it was before.
  Future<void> _more(RemoteDirEntry entry, {required bool canDownload}) async {
    final path = _join(widget.path, entry.name);
    final action = await showFileMoreActions(
      context,
      name: entry.name,
      path: path,
      markdownPreview: isMarkdownName(entry.name),
      download: canDownload,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case FileMoreAction.previewMarkdown:
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => FilePreviewPage(
              path: path,
              mode: FilePreviewMode.markdown,
            ),
          ),
        );
      case FileMoreAction.info:
        await showFileInfo(context, name: entry.name, path: path);
      case FileMoreAction.download:
        await _download(entry);
      case FileMoreAction.viewText:
        // Never offered here: tapping the row already opens the text.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        // The bar never paints anything, so the list keeps the full height and
        // makes room for it with its own top padding — content scrolling under
        // the circles is the whole effect.
        obstructs: false,
        leading: HerdrBackButton(label: l10n.navBack),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _basename(widget.path),
              style: TextStyle(color: colors.text, fontSize: TextSize.strong),
            ),
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
        actions: [
          HerdrBarButton(
            label: l10n.actionRefresh,
            onPressed: () => unawaited(_load()),
            child: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ),
      child: Builder(
        builder: (context) => _body(context, colors, l10n),
      ),
    );
  }

  Widget _body(BuildContext context, HerdrColors colors, AppLocalizations l10n) {
    if (_loading) {
      return Center(
        child: CupertinoActivityIndicator(color: colors.textDim),
      );
    }

    if (_failed) {
      return _Message(
        colors: colors,
        text: '${l10n.errorGeneric}\n${l10n.actionRetry}',
        isFailure: true,
      );
    }

    final entries = _entries ?? const <RemoteDirEntry>[];
    if (entries.isEmpty) {
      return _Message(colors: colors, text: l10n.filePreviewEmpty);
    }

    // The top inset is the floating bar's own height, which the scaffold
    // published as `MediaQuery.padding.top`; the bottom is the system's, so the
    // last row still clears the gesture area. Both are READ, never written out
    // here: a hard-coded 44 would be wrong on a phone with a notch.
    final insets = MediaQuery.paddingOf(context);

    // Whether the rows offer a download at all. Read from the setting rather
    // than from "is the connection ready", because the setting is the thing the
    // user controls: a button that appears and then explains that a switch is
    // off is a worse first encounter than no button and one switch to find.
    final canDownload = ref.watch(
      settingsProvider.select((s) => s.fileTransferEnabled),
    );

    return ListView.separated(
      padding: EdgeInsets.only(
        top: insets.top + Space.sm,
        bottom: insets.bottom + Space.sm,
      ),
      itemCount: entries.length,
      // A plain rule, not Material's `Divider`. The rule stops short of the
      // left edge so the icon column reads as a column.
      separatorBuilder: (_, _) => Container(
        height: 1,
        margin: const EdgeInsets.only(left: Space.xxl),
        color: colors.hairlineQuiet,
      ),
      itemBuilder: (context, i) {
        final entry = entries[i];
        // Directories offer no download: `fileActionsFor` is the single place
        // that decides, so the row cannot disagree with the sheet it opens.
        final canDownloadEntry =
            canDownload &&
            fileActionsFor(isDirectory: entry.isDirectory).isNotEmpty;
        return _EntryRow(
          entry: entry,
          colors: colors,
          onTap: () => unawaited(_open(entry)),
          onDownload: canDownloadEntry
              ? () => unawaited(_download(entry))
              : null,
          // A directory gets no sheet yet: every row it would hold is either
          // about a file's bytes (size, preview, download) or about a listing
          // this page already shows. `null` is the honest answer — a long press
          // that opens an empty sheet teaches the user not to long press.
          onMore: entry.isDirectory
              ? null
              : () => unawaited(_more(entry, canDownload: canDownloadEntry)),
        );
      },
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.colors,
    required this.onTap,
    this.onDownload,
    this.onMore,
  });

  final RemoteDirEntry entry;
  final HerdrColors colors;
  final VoidCallback onTap;

  /// Null when this row offers no download — a directory, or file transfer is
  /// switched off.
  final VoidCallback? onDownload;

  /// Null for a directory, which has no sheet to open. See [_more].
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // The row is already a full-width target, and this one opens a panel
      // rather than performing anything — the same gesture the workspace tree
      // and the machines list use for their actions.
      onLongPress: onMore,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            Icon(
              entry.isDirectory ? CupertinoIcons.folder : CupertinoIcons.doc_text,
              size: 18,
              color: entry.isDirectory ? colors.accent : colors.textFaint,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: TextSize.strong,
                  // Names are machine data: they are compared against terminal
                  // output and `git status`, so they get the machine voice.
                  fontFamily: HerdrFonts.mono,
                  fontFamilyFallback: HerdrFonts.monoFallback,
                ),
              ),
            ),
            if (entry.isLink)
              Padding(
                padding: const EdgeInsets.only(left: Space.sm),
                child: Icon(
                  CupertinoIcons.link,
                  size: 14,
                  color: colors.textFaint,
                ),
              ),
            // THE ONE PLACE THIS APP PUTS A BUTTON INSIDE A LIST ROW, and the
            // reasoning is worth writing down because the rule it bends is a
            // real one (AGENTS.md, Phase 11: no floating icon buttons in rows).
            //
            // That rule exists because the Machines page had "edit" and "delete"
            // side by side INSIDE the row's tap target, so the finger reaching
            // for "connect" was one thumb-width from destroying a machine. This
            // is neither destructive nor adjacent to anything destructive: it
            // is the primary action of the screen, it sits where a directory
            // row's chevron sits (so the column already reads as "trailing
            // affordance"), and hiding the feature's only entry point behind a
            // long press would make it undiscoverable. The long press is
            // offered as well, for reachability rather than for meaning.
            if (onDownload != null)
              _RowAction(
                colors: colors,
                semanticLabel: AppLocalizations.of(context).fileActionDownload,
                onPressed: onDownload!,
              )
            else if (entry.isDirectory)
              Icon(
                CupertinoIcons.chevron_forward,
                size: 14,
                color: colors.textFaint,
              ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.colors,
    required this.text,
    this.isFailure = false,
  });

  final HerdrColors colors;
  final String text;
  final bool isFailure;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isFailure ? colors.statusTextDied : colors.textDim,
            fontSize: TextSize.strong,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

/// Joins [name] onto [directory] without doubling a slash.
String _join(String directory, String name) =>
    directory.endsWith('/') ? '$directory$name' : '$directory/$name';

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

/// The trailing download affordance on a file row.
///
/// A [GestureDetector] around the glyph rather than a bare [CupertinoButton],
/// because the button's own minimum hit target would grow the row it sits in —
/// and a 44 pt control inside a 40 pt row is how a list starts looking uneven.
/// The tap target is widened by the padding instead, which costs the row
/// nothing.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.colors,
    required this.semanticLabel,
    required this.onPressed,
  });

  final HerdrColors colors;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.only(left: Space.md),
          child: Icon(
            CupertinoIcons.arrow_down_circle,
            size: 20,
            // The accent, not a status colour: this is an action, and every
            // status colour in the app already means something else.
            color: colors.accent,
          ),
        ),
      ),
    );
  }
}
