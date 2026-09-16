import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/git_client.dart';
import 'package:herdr_pocket/data/remote_fs.dart';
import 'package:herdr_pocket/domain/git/git_diff.dart';
import 'package:herdr_pocket/domain/git/git_status.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/diff_view.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// What has changed in a repository, and what exactly changed.
///
/// herdr's API says nothing about git — `worktree.list` carries a branch name
/// and topology and no changed files — so this reads it by running `git` over
/// the SSH connection that is already open. That is the same data source
/// `herdr-sidebar` uses, not a workaround invented here.
///
/// Tapping a file opens a diff page rather than expanding a row. A unified diff
/// is arbitrarily tall, and an expanding row inside a scrolling list makes both
/// the list and the diff harder to read: the reader loses their place in the
/// file list every time they close one. A pushed page gets the platform's back
/// gesture, which is what makes it feel free.
class GitPage extends ConsumerStatefulWidget {
  /// Shows the repository containing [cwd].
  const GitPage({required this.cwd, super.key});

  /// Any directory on the far end. It does not have to be the repository root —
  /// git is asked for the root, because every path it prints afterwards is
  /// relative to that and not to this.
  final String cwd;

  @override
  ConsumerState<GitPage> createState() => _GitPageState();
}

class _GitPageState extends ConsumerState<GitPage> {
  GitStatusResult? _result;
  String? _root;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final client = ref.read(gitClientProvider);
    if (client == null) {
      if (mounted) {
        setState(() {
          _result = const GitStatusFailure(GitFailure.unknown);
          _loading = false;
        });
      }
      return;
    }

    GitStatusResult result;
    String? root;
    try {
      // The root is resolved first and separately, because a status read from a
      // subdirectory reports paths relative to the ROOT. Joining those onto
      // `widget.cwd` would produce paths that do not exist — the single easiest
      // way to make this screen silently useless.
      root = await client.repoRoot(widget.cwd);
      if (root == null) {
        // `rev-parse` fails the same way whether git is absent or the directory
        // is not a repository, and the two need different sentences: one is
        // "install git", the other is "cd somewhere else". Asking which is one
        // extra round trip ON THE FAILURE PATH ONLY, which is cheap next to
        // telling someone to move to a repository when they have no git.
        result = await client.isAvailable()
            ? const GitStatusFailure(GitFailure.notARepository)
            : const GitStatusFailure(GitFailure.notInstalled);
      } else {
        result = await client.status(root);
      }
    } on Object catch (e) {
      result = GitStatusFailure(GitFailure.unknown, detail: '$e');
    }

    if (!mounted) return;
    setState(() {
      _result = result;
      _root = root;
      _loading = false;
    });
  }

  Future<void> _openDiff(GitEntry entry, {required bool staged}) async {
    final root = _root;
    if (root == null) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => GitDiffPage(
          cwd: root,
          entry: entry,
          staged: staged,
          title: widget.cwd,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      navigationBar: HerdrTopBar(
        // The list keeps the full height and makes room for the bar with its
        // own top padding, so a scrolled file list slides under the circles.
        obstructs: false,
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          l10n.gitTitle,
          style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        ),
        actions: [
          // Refresh used to be the word "Refresh" in the bar. It is an icon in
          // a circle now, like every other chrome button: a word has no shape
          // to put a surface behind, and a bare word over scrolling content is
          // the one thing the circles exist to avoid.
          HerdrBarButton(
            label: l10n.actionRefresh,
            onPressed: _loading ? null : () => unawaited(_load()),
            child: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ),
      child: _body(colors, l10n),
    );
  }

  Widget _body(HerdrColors colors, AppLocalizations l10n) {
    if (_loading) {
      return _Busy(colors: colors, message: l10n.gitLoading);
    }

    return switch (_result) {
      GitStatusFailure(:final reason) => _Message(
          colors: colors,
          text: switch (reason) {
            GitFailure.notInstalled => l10n.gitUnavailable,
            GitFailure.notARepository => l10n.gitNotARepo,
            GitFailure.unknown => '${l10n.errorGeneric}\n${l10n.actionRetry}',
          },
        ),
      GitStatusBody(:final status) when status.isClean => _Message(
          colors: colors,
          text: l10n.gitClean,
        ),
      GitStatusBody(:final status) => _Status(
          status: status,
          root: _root ?? widget.cwd,
          colors: colors,
          l10n: l10n,
          onOpen: _openDiff,
        ),
      null => _Busy(colors: colors, message: l10n.gitLoading),
    };
  }
}

/// The status, grouped the way a reader thinks about it.
class _Status extends StatelessWidget {
  const _Status({
    required this.status,
    required this.root,
    required this.colors,
    required this.l10n,
    required this.onOpen,
  });

  final GitStatus status;
  final String root;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final void Function(GitEntry entry, {required bool staged}) onOpen;

  @override
  Widget build(BuildContext context) {
    // Room for the floating bar at the top and the gesture area at the bottom;
    // both are read, so neither can drift from the phone they are drawn on.
    final insets = MediaQuery.paddingOf(context);

    return ListView(
      padding: EdgeInsets.only(
        top: insets.top,
        bottom: insets.bottom + Space.xxl,
      ),
      children: [
        _Header(status: status, root: root, colors: colors, l10n: l10n),
        // A file can appear in two sections at once — staged AND further
        // modified — and that is not a duplicate: those are two different
        // diffs, and merging them into one row would hide one of them.
        ..._section(
          title: l10n.gitConflicted,
          entries: status.conflicted,
          staged: false,
          isConflict: true,
        ),
        ..._section(
          title: l10n.gitStaged,
          entries: status.staged,
          staged: true,
        ),
        ..._section(
          title: l10n.gitUnstaged,
          entries: status.unstaged,
          staged: false,
        ),
        ..._section(
          title: l10n.gitUntracked,
          entries: status.untracked,
          staged: false,
        ),
        if (status.hasUnrecognisedStatus)
          Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Text(
              // Fail-closed, said out loud. The status letters are an open set,
              // and a row this build cannot read is shown with its raw letter
              // rather than quietly filed as "modified".
              l10n.errorGeneric,
              style: TextStyle(color: colors.statusTextWaiting, fontSize: TextSize.meta),
            ),
          ),
      ],
    );
  }

  List<Widget> _section({
    required String title,
    required List<GitEntry> entries,
    required bool staged,
    bool isConflict = false,
  }) {
    if (entries.isEmpty) return const [];

    Color tint() => isConflict
        ? colors.statusTextDied
        : staged
            ? colors.statusTextDone
            : colors.textFaint;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.lg,
          Space.lg,
          Space.lg,
          Space.xs,
        ),
        child: Row(
          children: [
            // The status word is the only colour here, which is the design
            // system's rule: colour is meaning, not decoration.
            Text(
              title,
              style: TextStyle(
                color: tint(),
                fontSize: TextSize.micro,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              l10n.gitChangesCount(entries.length),
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
              ),
            ),
          ],
        ),
      ),
      for (final entry in entries)
        _EntryRow(
          // A path is not unique across sections, so the section is part of the
          // key — otherwise Flutter reuses one row's state for another's.
          key: ValueKey('$title/${entry.path}'),
          entry: entry,
          colors: colors,
          staged: staged,
          onTap: () => onOpen(entry, staged: staged),
        ),
    ];
  }
}

/// Branch, upstream and how far it has drifted.
class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.root,
    required this.colors,
    required this.l10n,
  });

  final GitStatus status;
  final String root;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final branch = status.branch;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.hairlineQuiet)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.arrow_branch,
                size: 15,
                color: branch == null ? colors.textFaint : colors.accent,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  branch ?? root,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: TextSize.strong,
                    fontFamily: HerdrFonts.mono,
                    fontFamilyFallback: HerdrFonts.monoFallback,
                  ),
                ),
              ),
            ],
          ),
          // Only shown when there is something to say. A detached HEAD and an
          // unborn branch both have no name, and printing "(detached)" as if it
          // were a branch would be the parser's guess leaking into the UI.
          if (branch == null) ...[
            const SizedBox(height: Space.xs),
            Text(
              root,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
          ],
          if (status.hasUpstream && (status.ahead != 0 || status.behind != 0)) ...[
            const SizedBox(height: Space.sm),
            Text(
              l10n.gitAheadBehind(status.ahead, status.behind),
              style: TextStyle(
                color: colors.textDim,
                fontSize: TextSize.meta,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One changed path.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.colors,
    required this.staged,
    required this.onTap,
    super.key,
  });

  final GitEntry entry;
  final HerdrColors colors;
  final bool staged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The letters are git's own, and an unrecognised one is shown AS ITSELF
    // rather than mapped onto a word this build made up.
    final letters = '${entry.index.letter}${entry.worktree.letter}';
    final unrecognised = entry.hasUnrecognisedStatus;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                letters,
                style: TextStyle(
                  color: unrecognised
                      ? colors.statusTextWaiting
                      : staged
                          ? colors.statusTextDone
                          : colors.textFaint,
                  fontSize: TextSize.micro,
                  fontFamily: HerdrFonts.mono,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: TextSize.body,
                      fontFamily: HerdrFonts.mono,
                      fontFamilyFallback: HerdrFonts.monoFallback,
                    ),
                  ),
                  if (entry.originalPath != null)
                    Text(
                      '← ${entry.originalPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textFaint,
                        fontSize: TextSize.micro,
                        fontFamily: HerdrFonts.mono,
                        fontFamilyFallback: HerdrFonts.monoFallback,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              CupertinoIcons.chevron_forward,
              size: 13,
              color: colors.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// One file's diff.
///
/// Pushed rather than expanded, and the title is deliberately the generic "Git
/// changes" with the path beneath it: no localisation key exists for a
/// diff-specific title, and inventing one would mean editing the .arb files,
/// which this change is not allowed to do. The path is the machine voice and
/// the more useful of the two labels anyway.
class GitDiffPage extends ConsumerStatefulWidget {
  /// Shows the diff for one entry.
  const GitDiffPage({
    required this.cwd,
    required this.entry,
    required this.staged,
    required this.title,
    super.key,
  });

  /// Absolute repository root on the far end.
  final String cwd;

  final GitEntry entry;

  /// True to diff the index against HEAD (`--cached`).
  final bool staged;

  /// The path shown under the title, in the machine voice.
  final String title;

  @override
  ConsumerState<GitDiffPage> createState() => _GitDiffPageState();
}

class _GitDiffPageState extends ConsumerState<GitDiffPage> {
  GitDiffResult? _result;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final client = ref.read(gitClientProvider);
    if (client == null) {
      setState(() {
        _result = const GitDiffFailure(GitFailure.unknown);
        _loading = false;
      });
      return;
    }

    GitDiffResult result;
    try {
      result = await client.diff(
        widget.cwd,
        path: widget.entry.path,
        staged: widget.staged,
      );
    } on Object catch (e) {
      result = GitDiffFailure(GitFailure.unknown, detail: '$e');
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
        // A diff page is a Column — a notice, then a scroll view — so the bar
        // obstructs: the body is pushed below it rather than sliding under,
        // because half of that body is not scrollable and would end up behind
        // the circles.
        leading: HerdrBackButton(label: l10n.navBack),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.gitTitle,
              style: TextStyle(color: colors.text, fontSize: TextSize.strong),
            ),
            Text(
              widget.entry.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textFaint,
                fontSize: TextSize.micro,
                fontFamily: HerdrFonts.mono,
                fontFamilyFallback: HerdrFonts.monoFallback,
              ),
            ),
          ],
        ),
      ),
      child: SafeArea(child: _body(colors, l10n)),
    );
  }

  Widget _body(HerdrColors colors, AppLocalizations l10n) {
    if (_loading) {
      return _Busy(colors: colors, message: l10n.gitLoading);
    }

    final result = _result;
    return switch (result) {
      GitDiffFailure(:final reason) => _Message(
          colors: colors,
          text: switch (reason) {
            GitFailure.notInstalled => l10n.gitUnavailable,
            GitFailure.notARepository => l10n.gitNotARepo,
            GitFailure.unknown => '${l10n.errorGeneric}\n${l10n.actionRetry}',
          },
        ),
      GitDiffBody(:final diff, :final truncated) when !diff.isEmpty => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (truncated)
              _TruncationNotice(
                // Reported from the client's own cap rather than a number
                // written out here, so the notice cannot disagree with where
                // the text actually stops.
                text: l10n.filePreviewTruncated(
                  GitClient.defaultMaxDiffBytes ~/ 1024,
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: GitDiffView(diff: diff, colors: colors),
              ),
            ),
          ],
        ),
      // An untracked file has no diff at all — `git diff` cannot see a path it
      // does not track, so this is expected rather than a failure. Its whole
      // content is what changed, so that is what is shown, if it can be read.
      GitDiffBody() when widget.entry.isUntracked =>
        _UntrackedContent(entry: widget.entry, colors: colors, l10n: l10n),
      GitDiffBody() => _Message(colors: colors, text: l10n.gitDiffEmpty),
      null => _Busy(colors: colors, message: l10n.gitLoading),
    };
  }
}

/// The whole of an untracked file, rendered as an addition.
///
/// It costs one file read that the diff path already knows how to do, and it
/// answers the question the reader actually has. No localisation key exists for
/// "this file is new, here it is", and "No diff to show" would be true but
/// useless.
class _UntrackedContent extends ConsumerStatefulWidget {
  const _UntrackedContent({
    required this.entry,
    required this.colors,
    required this.l10n,
  });

  final GitEntry entry;
  final HerdrColors colors;
  final AppLocalizations l10n;

  @override
  ConsumerState<_UntrackedContent> createState() => _UntrackedContentState();
}

class _UntrackedContentState extends ConsumerState<_UntrackedContent> {
  GitDiff? _diff;
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

    GitDiff? diff;
    try {
      final result = await RemoteFs(runner).read(widget.entry.path);
      if (result is RemoteFileContent) {
        // Built as a unified diff rather than as its own view: the renderer is
        // the same one a tracked file uses, so an added line looks the same
        // wherever it came from. The synthetic header is marked as such so
        // nobody later mistakes it for git's output.
        diff = GitDiff.parse(
          'diff --git a/${widget.entry.path} b/${widget.entry.path}\n'
          'new file\n'
          '@@ -0,0 +1,${_lineCount(result.content)} @@\n'
          '${result.content.split('\n').map((l) => '+$l').join('\n')}',
        );
      }
    } on Object {
      diff = null;
    }

    if (!mounted) return;
    setState(() {
      _diff = diff;
      _loading = false;
    });
  }

  static int _lineCount(String content) {
    final lines = const LineSplitter().convert(content);
    return lines.isEmpty ? 1 : lines.length;
  }

  @override
  Widget build(BuildContext context) {
    final diff = _diff;
    if (_loading) {
      return _Busy(colors: widget.colors, message: widget.l10n.gitLoading);
    }
    if (diff == null || diff.isEmpty) {
      return _Message(colors: widget.colors, text: widget.l10n.gitDiffEmpty);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: GitDiffView(diff: diff, colors: widget.colors),
    );
  }
}

/// A quiet line above content that was cut short.
class _TruncationNotice extends StatelessWidget {
  const _TruncationNotice({required this.text});

  final String text;

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
        text,
        style: TextStyle(color: colors.textDim, fontSize: TextSize.meta),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.colors, required this.message});

  final HerdrColors colors;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CupertinoActivityIndicator(color: colors.textDim),
          const SizedBox(height: Space.lg),
          Text(
            message,
            style: TextStyle(color: colors.textDim, fontSize: TextSize.body),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.colors, required this.text});

  final HerdrColors colors;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.textDim,
            fontSize: TextSize.strong,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
