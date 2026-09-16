import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// One file, read from the machine the daemon runs on.
///
/// herdr has no filesystem API, so the bytes come from a shell command over the
/// SSH connection that is already open — see [RemoteFs]. Nothing here knows
/// that, which is the point: this page takes a path and shows what came back.
///
/// Plain [Text], never `SelectableText`. The latter lives in
/// `package:flutter/material.dart`, and importing it would make the project's
/// no-Material rule a matter of trust rather than of fact — the same call the
/// host-key sheet makes, for the same reason.
class FilePreviewPage extends ConsumerStatefulWidget {
  /// Shows the file at [path], which must be absolute.
  const FilePreviewPage({required this.path, super.key});

  /// Absolute path on the far end.
  final String path;

  @override
  ConsumerState<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends ConsumerState<FilePreviewPage> {
  RemoteReadResult? _result;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final runner = ref.read(remoteRunnerProvider);
    if (runner == null) {
      // The far end cannot run commands at all. That is not a read failure with
      // a cause worth guessing at, so it is reported as one generic failure
      // rather than dressed up as "file not found".
      if (mounted) {
        setState(() {
          _result = const RemoteReadFailed(
            RemoteReadFailure.notFound,
            'this connection cannot run commands',
          );
          _loading = false;
        });
      }
      return;
    }

    RemoteReadResult result;
    try {
      result = await RemoteFs(runner).read(widget.path);
    } on Object catch (e) {
      // The transport threw: the channel died, or the 15 s command deadline
      // expired. Distinct from a read that reported a reason, but the page has
      // nothing different to offer the reader, so it lands on the same notice.
      result = RemoteReadFailed(RemoteReadFailure.unknown, '$e');
    }

    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
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
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _basename(widget.path),
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

    final result = _result;
    return switch (result) {
      // A truncated read is shown. It is the same text the file starts with,
      // and hiding it would make a large log unopenable; the notice says
      // exactly how much was read, which is what keeps it honest. It is the
      // list's FIRST ROW rather than a band above it: a band would pin the
      // notice to the screen and cut the code off below the bar.
      RemoteFileContent(:final content, :final truncated) => _Code(
          content: content,
          colors: colors,
          header: truncated ? _QuietNotice(_truncatedLabel(l10n, content)) : null,
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
}

/// "Showing the first N KB" — N is what was read, rounded up.
///
/// Derived from the text that actually arrived rather than from the configured
/// limit, so the number cannot drift away from the truth if the limit changes.
String _truncatedLabel(AppLocalizations l10n, String content) {
  final kb = (content.length + 1023) ~/ 1024;
  return l10n.filePreviewTruncated(kb);
}

/// The scrolling text, with a line-number gutter.
///
/// Built as a list rather than one big [Text] so a 3000-line file does not lay
/// out every line to show the first twenty. The gutter is a sibling of the line
/// rather than a column of its own, because a separate column cannot stay
/// aligned once a line wraps — and a gutter that drifts out of step with the
/// text is worse than no gutter at all.
class _Code extends StatelessWidget {
  const _Code({required this.content, required this.colors, this.header});

  final String content;
  final HerdrColors colors;

  /// Drawn as the list's first row when there is something to say about the
  /// text below it (a truncated read, chiefly).
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    // A trailing empty line is what a file ending in a newline produces; it is
    // a line that does not exist, so it is dropped rather than numbered.
    final lines = content.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

    // Room for the floating bar, read from the scaffold rather than written
    // out: the top value here IS the bar's height, which is what lets the code
    // disappear underneath it as the page scrolls.
    final insets = MediaQuery.paddingOf(context);
    final offset = header == null ? 0 : 1;

    return ListView.builder(
      padding: EdgeInsets.only(
        top: insets.top + Space.md,
        bottom: insets.bottom + Space.md,
      ),
      itemCount: lines.length + offset,
      itemBuilder: (context, i) {
        if (header != null && i == 0) return header!;
        return _CodeLine(
          number: i + 1 - offset,
          text: lines[i - offset],
          colors: colors,
        );
      },
    );
  }
}

class _CodeLine extends StatelessWidget {
  const _CodeLine({
    required this.number,
    required this.text,
    required this.colors,
  });

  final int number;
  final String text;
  final HerdrColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '$number',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.meta,
                height: 1.5,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              text.isEmpty ? ' ' : text,
              style: TextStyle(
                color: colors.text,
                fontSize: TextSize.note,
                height: 1.5,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
