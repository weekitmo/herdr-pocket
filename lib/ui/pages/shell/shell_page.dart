import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/data/transport/shell_transport.dart';
import 'package:herdr_pocket/data/transport/ssh_dial.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/key_strip.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_composer.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:xterm/core.dart';

/// A real terminal on a machine, with no herdr in the path.
///
/// WHY THIS EXISTS AT ALL. Everything else in this app is a view of the herdr
/// daemon: the board reads its agents, the tree reads its workspaces, and even
/// the pane mirror is the daemon rendering a pane for us. That makes the whole
/// app useless on a machine that has SSH and no herdr — which is most machines,
/// most of the time.
///
/// So this page is the one surface that only needs SSH. It opens a PTY, runs
/// what the user configured (a login shell by default, `tmux` if they set it),
/// and draws it with the same painter, the same key strip and the same type
/// metrics as the pane mirror. Which is the point: it is not a second terminal
/// implementation, it is the same terminal attached to a different source.
///
/// ## What is genuinely different from the pane mirror
///
/// Three things, and each one is a rule rather than a detail:
///
///  1. **WE own the size.** The pane mirror asks the daemon for the pane's own
///     geometry and treats the phone's box as a window onto it. Here there is no
///     daemon: the PTY is sized to the box, and the box changing is a
///     `window-change` we have to send ourselves.
///  2. **The history is OURS.** A mirrored pane's scrollback lives on the far
///     side, so that page always paints at `scrollOffset: 0` and lets the daemon
///     do the scrolling. Here xterm's own buffer is the history, so scrolling
///     back is a local offset — and it works while the link is down.
///  3. **The session can END.** A pane outlives every viewer; a PTY does not.
///     When it finishes, the exit status is the only thing that says whether it
///     worked, so it is shown rather than swallowed.
class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({required this.profile, super.key});

  /// The machine to open the PTY on. Taken from the caller rather than read
  /// from "the current host", because a terminal is something you open on the
  /// machine you need — which is very often not the one the board is pointed at
  /// (the machine you are fixing, for instance).
  final HostProfile profile;

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends ConsumerState<ShellPage> {
  /// The character grid. Owned here, not by the painter, and never replaced
  /// except on reopen: the scrollback is the user's, and dropping it to redraw
  /// would be dropping what they were reading.
  Terminal _terminal = Terminal(maxLines: 4000);

  /// The one notifier the painter listens to. See [_Repaint].
  final _repaint = _Repaint();

  RemoteShellSession? _session;
  final _inputFocus = FocusNode();

  KeyBarState _keys = const KeyBarState();

  /// The grid we have told the far side we are, in cells.
  int _cols = 0;
  int _rows = 0;

  /// Cell size, measured during layout. Kept so a drag can be converted from
  /// pixels into lines without re-measuring on every pointer move.
  double _cellHeight = 0;

  /// How far back from the live screen we are painting, in lines. Zero is
  /// "following the output", which is where a terminal should be almost always.
  int _scrollOffset = 0;
  double _dragCarry = 0;

  bool _opening = false;
  Object? _error;

  /// Set when the remote process is gone. Distinct from [_error]: this is a
  /// session that ran and finished, not one that failed to start.
  bool _ended = false;
  int? _exitCode;

  bool _fanOpen = false;

  /// Debounces `window-change` while the keyboard animates open or closed.
  Timer? _resizeTimer;

  @override
  void dispose() {
    _resizeTimer?.cancel();
    FocusScope.of(context);
    _inputFocus.dispose();
    unawaited(_session?.close());
    _repaint.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- session

  Future<void> _open() async {
    final profile = widget.profile;
    try {
      final secrets =
          await ref.read(hostSecretsStoreProvider).read(profile.id);
      if (!mounted) return;
      if (secrets == null) {
        setState(() {
          _opening = false;
          _error = HerdrTransportException(
            TransportFailure.authenticationFailed,
            'no stored credential for ${profile.label}',
          );
        });
        return;
      }

      final runner = SshShellTransport(
        credentials: SshCredentials(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: secrets.privateKeyPem,
          privateKeyPassphrase: secrets.privateKeyPassphrase,
          password: secrets.password,
        ),
        // The same verifier the board dials through, so a machine approved once
        // is never asked about again — and a machine whose key CHANGED raises
        // the same alarm here as there.
        verifyHostKey: ref.read(hostKeyVerifierProvider),
        command: ref.read(settingsProvider).sessionCommand,
      );

      final session = await runner.open(cols: _cols, rows: _rows);
      if (!mounted) {
        await session.close();
        return;
      }

      session.output.listen(
        (chunk) {
          if (!mounted || _session != session) return;
          _terminal.write(chunk);
          _repaint.fire();
        },
        onError: (Object e) {
          if (mounted && _session == session) setState(() => _error = e);
        },
        onDone: () => unawaited(_finish(session)),
      );

      setState(() {
        _session = session;
        _opening = false;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _opening = false;
        });
      }
    }
  }

  /// The remote process is gone: record how it went.
  ///
  /// The exit status is read AFTER the output stream ends rather than from the
  /// channel's closure, because the two are not the same moment — data can still
  /// be queued when the channel closes, and a status read too early comes back
  /// null for a process that exited cleanly.
  Future<void> _finish(RemoteShellSession session) async {
    final code = await session.exitStatus;
    if (!mounted || _session != session) return;
    setState(() {
      _ended = true;
      _exitCode = code;
    });
  }

  Future<void> _reopen() async {
    final old = _session;
    setState(() {
      _session = null;
      _ended = false;
      _exitCode = null;
      _error = null;
      _opening = true;
      _scrollOffset = 0;
      _dragCarry = 0;
    });
    // A fresh grid: the old one holds a dead session's output, and scrolling
    // back into it would be scrolling into a terminal that no longer exists.
    _terminal = Terminal(maxLines: 4000);
    _terminal.resize(_cols, _rows);
    await old?.close();
    if (mounted) await _open();
  }

  // ------------------------------------------------------------------ size

  /// Applies a newly measured grid, opening or resizing the session to match.
  ///
  /// Called from layout, so it must not call `setState` synchronously — the
  /// opening is deferred to a callback exactly like the size report on the pane
  /// mirror.
  void _applySize(int cols, int rows) {
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    // Tell the MODEL first: the painter draws `rows` lines from the end of the
    // buffer, and a grid that disagrees with the PTY puts every wrap in the
    // wrong place.
    _terminal.resize(cols, rows);
    if (_ended) return;

    final session = _session;
    if (session == null) {
      if (_opening || _error != null) return;
      _opening = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_open());
      });
      return;
    }

    // NOT IMMEDIATELY, and this is not politeness. The soft keyboard animates,
    // which produces a size on every frame; each one becomes a `window-change`
    // and a SIGWINCH, and a full-screen program redraws for every one of them.
    // The user sees their terminal flicker while the keyboard slides.
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) _session?.resize(_cols, _rows);
    });
  }

  // ----------------------------------------------------------------- input

  /// Sends [text] as bytes, with whatever modifiers are armed applied to it.
  void _send(String text) {
    final session = _session;
    if (session == null || text.isEmpty) return;
    // Typing means you want the live screen. Leaving the view parked in history
    // while keystrokes go to the far end is the most confusing thing a terminal
    // can do.
    if (_scrollOffset != 0) setState(() => _scrollOffset = 0);
    session.sendBytes(utf8.encode(text));
  }

  void _onTyped(String text) {
    final outcome = _keys.type(text);
    setState(() => _keys = KeyBarState(armed: outcome.armed));
    if (outcome.bytes != null) _send(outcome.bytes!);
  }

  void _onBackspace(int count) {
    // The phone's backspace produces no keyup and, with the field kept empty,
    // sometimes no event at all — which is why [TerminalComposer] owns the input
    // connection and reports deletions explicitly. DEL, not BS: that is what a
    // terminal's backspace key sends.
    _send('\x7f' * count);
  }

  void _onKeyTap(SoftKey key) {
    if (key == SoftKey.copy) {
      unawaited(_copySelection());
      return;
    }
    if (key == SoftKey.paste) {
      unawaited(_paste());
      return;
    }
    final outcome = _keys.tap(key);
    setState(() => _keys = KeyBarState(armed: outcome.armed));
    if (outcome.bytes != null) _send(outcome.bytes!);
  }

  Future<void> _copySelection() async {
    // Nothing to select from yet: the shell page has no selection gesture in
    // this version, so copy takes the live screen's text. Honest and useful —
    // and the alternative (a copy button that does nothing) is worse.
    final buffer = _terminal.buffer;
    final lines = <String>[];
    final from = math.max(0, buffer.lines.length - _rows);
    for (var i = from; i < buffer.lines.length; i++) {
      lines.add(buffer.lines[i].toString());
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n').trimRight()));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    _send(pastePayload(text, bracketed: _terminal.bracketedPasteMode));
  }

  // --------------------------------------------------------------- gestures

  void _onScrollDrag(DragUpdateDetails details) {
    if (_cellHeight <= 0) return;
    _dragCarry += details.delta.dy / _cellHeight;
    final whole = _dragCarry.truncate();
    if (whole == 0) return;
    _dragCarry -= whole;
    // Dragging DOWN (positive dy) walks forward in time, i.e. toward the live
    // screen — so the offset moves the other way.
    final maxOffset =
        math.max(0, _terminal.buffer.lines.length - _rows);
    setState(() {
      _scrollOffset = (_scrollOffset - whole).clamp(0, maxOffset);
    });
    _repaint.fire();
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final palette = resolveTerminalColors(ref.watch(selectedThemeProvider));
    final zoom = ref.watch(settingsProvider.select((s) => s.terminalTextScale));

    return CupertinoPageScaffold(
      backgroundColor: palette.background,
      navigationBar: HerdrTopBar(
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          widget.profile.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.foreground, fontSize: TextSize.strong),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _buildSurface(context, constraints, palette, colors, l10n, zoom),
            ),
          ),
          // The hidden field that owns the soft keyboard. One point tall, and
          // present only while the session is alive: a keyboard that types into
          // a finished session is worse than no keyboard.
          if (!_ended && _error == null)
            TerminalComposer(
              focusNode: _inputFocus,
              onInsert: _onTyped,
              onDelete: _onBackspace,
              // The key strip's own Enter, so an armed Ctrl applies to the
              // keyboard's return exactly as it does to the bar's.
              onEnter: () => _onKeyTap(SoftKey.enter),
            ),
          if (!_ended) _keyBar(palette),
        ],
      ),
    );
  }

  Widget _keyBar(TerminalColors palette) {
    return KeyStrip(
      keys: ref.watch(settingsProvider.select((s) => s.keyBarKeys)),
      state: _keys,
      enabled: _session != null,
      palette: palette,
      onTap: _onKeyTap,
      onKeyboard: _toggleKeyboard,
      keyboardUp: MediaQuery.viewInsetsOf(context).bottom > 0,
      onExpand: () {
        unawaited(HapticFeedback.selectionClick());
        setState(() => _fanOpen = !_fanOpen);
      },
      expanded: _fanOpen,
      // The chat window is not offered here yet: its `/` and `@` menus are
      // built from a remote filesystem probe that this page does not open, and
      // a composer without them would be a downgrade from the key strip.
      // See plannings/ssh-terminal/task_plan.md, Phase B.
      composerEnabled: false,
      onComposer: () {},
      composerOpen: false,
    );
  }

  void _toggleKeyboard() {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _inputFocus.unfocus();
    } else {
      _inputFocus.requestFocus();
    }
  }

  Widget _buildSurface(
    BuildContext context,
    BoxConstraints constraints,
    TerminalColors palette,
    HerdrColors colors,
    AppLocalizations l10n,
    double zoom,
  ) {
    final fontSize = kTerminalBaseFontSize * zoom;
    const fontFamily = HerdrFonts.mono;

    final metrics = CellMetrics.measure(
      text: '\u3000',
      style: TextStyle(fontFamily: fontFamily, fontSize: fontSize, height: 1),
    );
    // A cell must be wide enough for the widest thing it can hold: the
    // ideographic space gives the full-width advance, and the Latin cell is half
    // of it by the definition of a monospace CJK pairing.
    final cellWidth = metrics.width / 2;
    final cellHeight = metrics.height;

    final cols = (constraints.maxWidth / cellWidth).floor().clamp(20, 400);
    final rows = (constraints.maxHeight / cellHeight).floor().clamp(5, 400);

    _cellHeight = cellHeight;
    // Both ends from the box, unlike the pane mirror: the PTY is ours to size,
    // and a terminal that asked for somebody else's geometry would be a terminal
    // that wraps in the wrong place.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applySize(cols, rows);
    });

    if (_opening || _error != null || _ended) {
      return _ShellOverlay(
        palette: palette,
        l10n: l10n,
        opening: _opening,
        error: _error,
        ended: _ended,
        exitCode: _exitCode,
        onReopen: () => unawaited(_reopen()),
      );
    }

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: _onScrollDrag,
          child: CustomPaint(
            size: Size.infinite,
            painter: TerminalPainter(
              terminal: _terminal,
              palette: palette,
              cellWidth: cellWidth,
              cellHeight: cellHeight,
              fontFamily: fontFamily,
              fontFamilyFallback: HerdrFonts.monoFallback,
              fontSize: fontSize,
              cursorVisible: true,
              // The offset is ours, because the history is ours — see the class
              // doc. The pane mirror passes zero here and lets the daemon hold
              // the position.
              scrollOffset: _scrollOffset,
              selection: null,
              // `topRow` is left at its default of zero, and that is the
              // point: the PTY is the height of the box, so there is no taller
              // frame to take a window of — `firstVisibleRow` would return zero
              // here for the same reason.
              repaint: _repaint,
            ),
          ),
        ),
        if (_scrollOffset > 0)
          Positioned(
            right: Space.md,
            bottom: Space.md,
            child: _BackToLive(
              palette: palette,
              onTap: () => setState(() => _scrollOffset = 0),
              label: l10n.shellBackToLive,
            ),
          ),
        if (_fanOpen)
          Positioned.fill(
            child: KeyFan(
              keys: ref.watch(settingsProvider.select((s) => s.keyBarKeys)),
              state: _keys,
              palette: palette,
              colors: colors,
              enabled: _session != null,
              onTap: _onKeyTap,
            ),
          ),
      ],
    );
  }
}

/// "Jump back to the live screen", shown only while scrolled back.
///
/// A local scrollback needs an exit that is not "drag the exact number of lines
/// back down": output arriving while you read pushes the live screen further
/// away, so the gesture that got you here cannot reliably get you out.
class _BackToLive extends StatelessWidget {
  const _BackToLive({
    required this.palette,
    required this.onTap,
    required this.label,
  });

  final TerminalColors palette;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.background.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(color: palette.foreground.withValues(alpha: 0.25)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          child: Text(
            label,
            style: TextStyle(color: palette.foreground, fontSize: TextSize.meta),
          ),
        ),
      ),
    );
  }
}

/// What the page shows while there is no terminal on it.
class _ShellOverlay extends StatelessWidget {
  const _ShellOverlay({
    required this.palette,
    required this.l10n,
    required this.opening,
    required this.error,
    required this.ended,
    required this.exitCode,
    required this.onReopen,
  });

  final TerminalColors palette;
  final AppLocalizations l10n;
  final bool opening;
  final Object? error;
  final bool ended;
  final int? exitCode;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final (title, body) = _describe();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (opening)
              CupertinoActivityIndicator(color: palette.cursor)
            else
              Icon(
                CupertinoIcons.exclamationmark_triangle,
                color: palette.foreground.withValues(alpha: 0.7),
                size: 28,
              ),
            const SizedBox(height: Space.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.foreground, fontSize: TextSize.strong),
            ),
            const SizedBox(height: Space.sm),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.foreground.withValues(alpha: 0.7),
                fontSize: TextSize.note,
                height: 1.4,
              ),
            ),
            if (!opening) ...[
              const SizedBox(height: Space.lg),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.lg,
                  vertical: Space.sm,
                ),
                color: palette.foreground.withValues(alpha: 0.12),
                onPressed: onReopen,
                child: Text(
                  l10n.shellReopen,
                  style: TextStyle(
                    color: palette.foreground,
                    fontSize: TextSize.strong,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (String, String) _describe() {
    if (opening) return (l10n.shellConnecting, l10n.shellConnectingBody);
    if (ended) {
      final code = exitCode;
      return (
        l10n.shellEnded,
        code == null ? l10n.shellExitUnknown : l10n.shellExitCode(code),
      );
    }
    // The message, not the exception's toString: a remote "command not found"
    // is the single most likely failure here (a configured `tmux` on a machine
    // without it), and the sentence the user needs is the one the far side
    // wrote.
    final e = error;
    final detail = e is HerdrTransportException ? e.message : '$e';
    return (l10n.shellFailed, detail);
  }
}

/// Repaints the grid without rebuilding the page.
///
/// `Terminal` is not a [Listenable], and every chunk of output would otherwise
/// need a `setState` — which rebuilds the key strip, the overlay and the layout
/// for a change that only the painter cares about.
class _Repaint extends ChangeNotifier {
  void fire() => notifyListeners();
}
