import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/nav_tree.dart';
import 'package:herdr_pocket/data/providers/themes.dart';
import 'package:herdr_pocket/data/remote_upload.dart';
import 'package:herdr_pocket/data/terminal/terminal_control.dart';
import 'package:herdr_pocket/data/terminal/terminal_selection.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/domain/agent/attachment.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:herdr_pocket/domain/terminal/pinch.dart';
import 'package:herdr_pocket/domain/terminal/swipe.dart';
import 'package:herdr_pocket/domain/workspace/jump_target.dart';
import 'package:herdr_pocket/domain/workspace/pane_actions.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';
import 'package:herdr_pocket/domain/workspace/workspace_tree.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/menu_popover.dart';
import 'package:herdr_pocket/ui/components/pane_actions_sheet.dart';
import 'package:herdr_pocket/ui/components/toast.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/components/ui_icon.dart';
import 'package:herdr_pocket/ui/design/glass.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/files/file_tree_page.dart';
import 'package:herdr_pocket/ui/pages/git/git_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/layout_page.dart';
import 'package:herdr_pocket/ui/pages/terminal/pane_switcher.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';
import 'package:image_picker/image_picker.dart';
import 'package:xterm/core.dart';

/// A live terminal on one agent's pane.
///
/// The framing is "a status board that contains a terminal": this is reached by
/// tapping an agent, it takes over that pane's input, and it closes back to the
/// board. It is a real character grid, not a chat transcript — the whole reason
/// the board exists is that a chat wrapper throws away everything you need to
/// read a TUI.
/// The font size the terminal is drawn at before the user scales it.
///
/// One of the two numbers that decide how much of a desktop the phone can show
/// at once (the other is the screen): at 12 points, a 411-point-wide phone fits
/// about 68 columns, which is a full-width TUI and a narrow editor.
const double kTerminalBaseFontSize = 12;

/// How far "return to live" asks the daemon to scroll down.
///
/// AS FAR AS THE PROTOCOL ALLOWS, and the ceiling is the protocol's, not a
/// judgement call: `terminal.scroll` takes a u16, and anything larger is
/// rejected outright — measured against a live daemon, `1 << 20` comes back as
/// "invalid value: integer `1048576`, expected u16" and the viewport does not
/// move at all. The far end clamps this to the bottom, which is what makes the
/// button self-correcting: our own count of how far back we are drifts the
/// moment output arrives while the reader is scrolled.
const int _jumpToBottomLines = 65535;

/// The zoom range, matching the stepper in Settings.
///
/// The SAME two numbers on purpose: a pinch and the settings row are two ways to
/// set one value, and a range that differed between them would make the stored
/// value unreachable from one of the two.
const double kTerminalMinZoom = 0.8;
const double kTerminalMaxZoom = 1.8;

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({required this.paneId, required this.title, super.key});

  final String paneId;
  final String title;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  /// Not `final`: switching panes REPLACES the model rather than resetting it.
  /// xterm's buffer has `clear()` but no `reset()`, and a half-cleared buffer
  /// that still holds the previous agent's scrollback is a worse outcome than
  /// one small allocation when the user asks for a different pane.
  Terminal _terminal = Terminal(maxLines: 4000);
  final _repaint = _Repaint();
  final _controller = TextEditingController();

  TerminalSession? _session;
  bool _attaching = false;

  /// Reads two-finger horizontal swipes. A `Listener` rather than a recogniser
  /// on purpose: it observes pointers without entering the gesture arena, so it
  /// cannot starve the scroll pan the way a scale recogniser would.
  final _twoFinger = TwoFingerSwipeTracker();

  /// Reads a two-finger pinch off the same pointers, for the same reason. See
  /// [PinchTracker]: the arithmetic is in the domain so it can be tested, and
  /// the gesture is observed rather than claimed so it cannot starve anything.
  final _pinch = PinchTracker();

  /// The live zoom while a pinch is in flight, or null when there is none.
  ///
  /// It is applied IMMEDIATELY — the grid is redrawn at the new size on every
  /// frame of the gesture — and written to the settings once, when the fingers
  /// lift. A setting that only changed at the end would make the pinch feel like
  /// a slider with no feedback.
  double? _pinchingScale;

  /// The zoom the current pinch started from.
  double _pinchBase = 1;
  Object? _error;
  String? _closeReason;
  bool _busy = true;

  int _cols = 80;

  /// Completes the first time a layout reports a real cell grid.
  ///
  /// `_cols`/`_rows` above are a guess, and the daemon renders — and for a
  /// control session resizes the user's own pane — at exactly what we ask for.
  /// Opening before the first frame has measured the widget therefore resizes
  /// someone's terminal twice: once to a guess, once to the truth, with their
  /// TUI redrawing itself at both. So the session waits for a measured size.
  final _sizeReady = Completer<void>();

  /// Which modifiers are armed on the key bar, and what that means for the next
  /// keystroke. Held on the PAGE rather than inside the bar so the soft
  /// keyboard can honour it too — see [KeyBarState.type].
  KeyBarState _keys = const KeyBarState();

  /// Lines back from the live bottom. 0 means "following".
  ///
  /// THE FAR END OWNS THIS NUMBER, and that is the whole reason this screen
  /// could not scroll for one revision. The daemon sends a RENDERED VIEWPORT,
  /// not a stream of lines: the local buffer holds exactly one screen (measured:
  /// 21 lines at 21 rows, however much the pane has printed), so an offset into
  /// it could only ever be zero. History lives on the machine, and looking at it
  /// is a request — `terminal.scroll` — not a scroll of what we already have.
  ///
  /// This field is therefore a MIRROR of the daemon's `offset_from_bottom`, kept
  /// for the "N lines back" bar and for knowing which way to ask next.
  int _scrollOffset = 0;

  /// True while the expanded key panel is open.
  ///
  /// On the page rather than inside the bar, because the panel is drawn OVER
  /// the terminal — the bar only owns the button that opens it, and a widget
  /// that held this flag would have to reach up to paint outside itself.
  bool _fanOpen = false;
  double _dragCarry = 0;
  double _lastCellHeight = 16;
  TerminalSelection? _selection;
  (int, int)? _selectionAnchor;
  double _lastCellWidth = 8;
  bool get _following => _scrollOffset == 0;
  int _rows = 24;
  String _previousInput = '';

  /// Which pane this screen is attached to. Starts as the one it was pushed
  /// with, and changes when the user picks another from the switcher.
  late String _paneId = widget.paneId;
  late String _title = widget.title;

  /// The hidden field that owns the soft keyboard.
  ///
  /// Held explicitly rather than left to `autofocus` alone, because "put the
  /// keyboard away" has to name the thing that is holding it. Unfocusing a
  /// scope instead looked right and did nothing: the field kept focus across a
  /// pushed route, and the keyboard stayed up over the Git page — a page with
  /// no field of its own and no use for a keyboard.
  final FocusNode _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    // Start the workspace tree loading, without subscribing to it.
    //
    // The tree is a READY dependency of this screen — the overflow sheet needs
    // the pane's directory, and the two-finger swipe needs to know which pane
    // is next — but reading it lazily at the moment of the gesture is too late:
    // the first read is three requests, and until they answer the gesture does
    // nothing at all. Opening it straight from the board is the main flow, and
    // the board never touches the tree, so this was the common case.
    //
    // `read(...future)` rather than `watch`: kick the read off, but do not
    // rebuild this page every time an agent prints.
    unawaited(_seedScrollFromTree());
    // Watch what the user types and translate it into terminal keystrokes.
    _controller.addListener(_onComposerChanged);
  }

  /// Learns whether the pane is ALREADY scrolled before this screen opened.
  ///
  /// Nothing that arrives over the terminal stream says so: a rendered frame of
  /// history is indistinguishable from a rendered frame of the present. The pane
  /// census is the only place the daemon reports `offset_from_bottom`, so the
  /// "N lines back" bar is seeded from it — otherwise a pane another client left
  /// scrolled would open showing history with no way back. (Found exactly that
  /// way: a reload reset the mirror to 0 while the daemon was still at 20.)
  ///
  /// A tree that cannot be read is NOT an error here — the bar simply starts
  /// hidden — so the failure is swallowed rather than left to bubble as an
  /// unhandled future. That distinction is not cosmetic: the original
  /// fire-and-forget read was fine because Riverpod itself listens to the
  /// future, but a `.then()` chain is a NEW future with no error handler, and
  /// every test whose scripted daemon lacks `workspace.list` failed on it.
  Future<void> _seedScrollFromTree() async {
    final WorkspaceTree tree;
    try {
      tree = await ref.read(navTreeProvider.future);
    } on Object {
      return;
    }
    if (!mounted) return;
    final offset = tree.paneById(_paneId)?.scrollOffsetFromBottom;
    if (offset == null || offset == 0 || _scrollOffset != 0) return;
    setState(() => _scrollOffset = offset);
  }

  @override
  void dispose() {
    // Nothing is waiting on a size once this screen is gone, but a completer
    // that never completes leaves `_open` suspended forever.
    if (!_sizeReady.isCompleted) _sizeReady.complete();
    _inputFocus.dispose();
    _resizeDebounce?.cancel();
    _repaint.dispose();
    _controller
      ..removeListener(_onComposerChanged)
      ..dispose();
    unawaited(_session?.close());
    super.dispose();
  }

  /// Detaches from the current pane and attaches to another.
  ///
  /// The ORDER matters: the old session is closed first. Opening a control
  /// session on the new pane while the old one is still open would leave two
  /// clients claiming input on the machine, and herdr is explicit that a second
  /// control client is refused — so racing the two would intermittently fail
  /// with a reason that has nothing to do with what the user did.
  Future<void> _switchTo(PaneInfo pane) async {
    if (pane.paneId == _paneId) return;
    // Firmer than a selection tick: this tears down a live stream and attaches
    // to a different agent's terminal, which is the most consequential thing a
    // tap does in this app.
    unawaited(HapticFeedback.mediumImpact());

    // Read the field into a local BEFORE clearing it. `await _session?.close()`
    // after nulling `_session` reads the field again, sees null, and closes
    // nothing — leaving the daemon holding a control session on the pane we are
    // walking away from, which is exactly what makes the next attach fail.
    final previous = _session;
    setState(() {
      _busy = true;
      _error = null;
      _closeReason = null;
      _session = null;
    });
    await previous?.close();

    if (!mounted) return;
    setState(() {
      _paneId = pane.paneId;
      _title = pane.displayName;
      _terminal = Terminal(maxLines: 4000);
      _scrollOffset = 0;
      _dragCarry = 0;
      _previousInput = '';
      _selection = null;
      _selectionAnchor = null;
    });
    await _open();
  }

  void _openLayout() {
    _push(LayoutPage(paneId: _paneId, title: _title));
  }

  /// Pushes a page over the terminal, taking the keyboard with it.
  ///
  /// WHY UNFOCUS FIRST. The terminal keeps a nearly invisible text field
  /// focused so the soft keyboard stays up and keystrokes keep flowing — that
  /// is the point of it. But the terminal stays in the tree when a page is
  /// pushed on top, so the field keeps focus and the keyboard stays on screen,
  /// covering the bottom half of a page that has no use for it. Leaving the
  /// terminal is the one moment where "the keyboard follows you" stops being
  /// right.
  void _push(Widget page) {
    _inputFocus.unfocus();
    Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => page),
    );
  }

  Future<void> _openSwitcher() async {
    final picked = await showPaneSwitcher(context, paneId: _paneId);
    if (picked == null || !mounted) return;
    await _switchTo(picked);
  }

  Future<void> _open() async {
    // See [_sizeReady]: the session must not be opened at a guessed grid.
    await _sizeReady.future;
    if (!mounted) return;

    final connection = await ref.read(connectionProvider.future);
    if (!mounted) return;
    if (connection is! Online) {
      setState(() {
        _error = 'not connected';
        _busy = false;
      });
      return;
    }

    final transport = connection.client.transport;
    // Dart cannot promote across two unrelated interfaces, so this is a cast
    // rather than a promotion — the `is` check above it is what makes it safe.
    if (transport is! RemoteStreamRunner) {
      setState(() {
        _error = 'this transport cannot open a terminal';
        _busy = false;
      });
      return;
    }
    final runner = transport as RemoteStreamRunner;

    try {
      final session = await TerminalControl.open(
        runner,
        paneId: _paneId,
        cols: _cols,
        rows: _rows,
      );
      if (!mounted) {
        await session.close();
        return;
      }
      session.frames.listen(
        (frame) {
          if (!mounted) return;
          // The daemon renders at the size we asked for, so the model must be
          // told the same size or the grid lands in the wrong columns.
          if (frame.width != _cols || frame.height != _rows) {
            _terminal.resize(frame.width, frame.height);
            _cols = frame.width;
            _rows = frame.height;
          }
          // No local "keep the reader still" arithmetic: while the viewport is
          // scrolled back, the frames arriving ARE the history the daemon is
          // rendering for us, and it holds that position itself.
          _terminal.write(frame.data);
          _repaint.fire();
        },
        // Both handlers are guarded on this session still being the current
        // one. Switching panes closes the old session on purpose, and its
        // teardown fires `onDone` — without the guard the brand-new terminal
        // would immediately be covered by a "disconnected" overlay for a
        // session the user deliberately left.
        onError: (Object e) {
          if (mounted && _session == session) setState(() => _error = e);
        },
        onDone: () {
          if (mounted && _session == session) {
            setState(() => _closeReason = session.closeReason);
          }
        },
      );
      setState(() {
        _session = session;
        _busy = false;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _busy = false;
        });
      }
    }
  }

  /// Turns text-field edits into terminal bytes.
  ///
  /// A text field is the only reliable way to raise the soft keyboard, but it
  /// thinks in strings while a terminal thinks in keystrokes. Diffing against
  /// the previous value recovers both: characters typed become input, and
  /// characters removed become DEL, which is what makes backspace work.
  void _onComposerChanged() {
    final session = _session;
    if (session == null) return;

    final current = _controller.text;
    final previous = _previousInput;
    _previousInput = current;

    if (current.length > previous.length) {
      _jumpToBottom();
      // Armed modifiers apply to the KEYBOARD too, not only to the dozen keys
      // on the bar. This is the half that matters most: `Ctrl` + typing `d` on
      // the phone's own keyboard is the only way to reach Ctrl+D, or Ctrl+R, or
      // any other control code that has no button.
      final outcome = _keys.type(current.substring(previous.length));
      if (_keys.armed.isNotEmpty) {
        // Typing consumes the armed modifiers, and the bar has to show it:
        // leaving `Ctrl` lit after it has already been spent would make the
        // next keystroke look like it should be controlled too.
        setState(() => _keys = KeyBarState(armed: outcome.armed));
      }
      session.sendText(outcome.bytes ?? '');
    } else if (current.length < previous.length) {
      final removed = previous.length - current.length;
      for (var i = 0; i < removed; i++) {
        session.sendBytes(const [0x7F]); // DEL — the terminal's backspace
      }
    }
    // Keep the field empty so it never accumulates a visible buffer.
    if (current.isNotEmpty) {
      _previousInput = '';
      _controller.clear();
    }
  }

  /// Moves to the tab [delta] places away, wrapping at the ends.
  ///
  /// The decision of WHERE lives in the domain ([siblingTab]) so it can be
  /// tested without a live session; this only carries it out.
  Future<void> _swipeTab(int delta) async {
    final tree = ref.read(navTreeProvider).value;
    if (tree == null) return;
    final next = siblingTab(tree, paneId: _paneId, delta: delta);
    if (next == null) return;
    await _switchTo(next.pane);
    // Named, because a silent tab change is indistinguishable from a glitch —
    // the screen looks the same and the content is simply different.
    if (mounted) showHerdrToast(context, next.tabLabel);
  }

  /// Moves to the pane [delta] places away within the same tab.
  Future<void> _swipePane(int delta) async {
    final tree = ref.read(navTreeProvider).value;
    if (tree == null) return;
    final next = siblingPane(tree, paneId: _paneId, delta: delta);
    if (next == null) return;
    await _switchTo(next.pane);
    if (mounted) showHerdrToast(context, next.paneLabel);
  }

  /// Puts a file on the machine and types its path into the agent.
  ///
  /// TYPED, NOT SENT. The path lands in the agent's composer so the user can add
  /// a sentence about it before pressing return — and because typing can never
  /// run anything on its own. The alternative (submitting the prompt for them)
  /// would send a bare file path as a whole message, which is rarely what
  /// anybody means.
  Future<void> _attach() async {
    final l10n = AppLocalizations.of(context);
    final uploader = ref.read(remoteUploaderProvider);
    if (uploader == null) {
      showHerdrToast(context, l10n.attachUnavailable, isError: true);
      return;
    }

    final source = await showCupertinoModalPopup<_AttachSource>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.attachTitle),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, _AttachSource.clipboard),
            child: actionSheetLabel(l10n.attachClipboard),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, _AttachSource.gallery),
            child: actionSheetLabel(l10n.attachGallery),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, _AttachSource.camera),
            child: actionSheetLabel(l10n.attachCamera),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: actionSheetLabel(l10n.actionCancel),
        ),
      ),
    );
    if (source == null || !mounted) return;

    setState(() => _attaching = true);
    try {
      final uploaded = switch (source) {
        _AttachSource.clipboard => await _uploadClipboard(uploader),
        _AttachSource.gallery ||
        _AttachSource.camera => await _uploadPhoto(uploader, source),
      };
      if (uploaded == null) return; // cancelled or nothing to send
      if (!mounted) return;

      final isZh = Localizations.localeOf(context).languageCode == 'zh';
      _jumpToBottom();
      _session?.sendText(
        attachmentPrompt(remotePath: uploaded.remotePath, isZh: isZh),
      );
      if (mounted) showHerdrToast(context, l10n.attachDone);
    } on UploadException catch (e) {
      if (!mounted) return;
      showHerdrToast(context, _uploadMessage(e, l10n), isError: true);
    } on Object catch (e) {
      if (!mounted) return;
      showHerdrToast(context, '${l10n.attachFailed}: $e', isError: true);
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  Future<UploadedAttachment?> _uploadClipboard(RemoteUploader uploader) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (mounted) {
        showHerdrToast(
          context,
          AppLocalizations.of(context).attachClipboardEmpty,
          isError: true,
        );
      }
      return null;
    }
    return await uploader.uploadText(text, originalName: 'clipboard.txt');
  }

  Future<UploadedAttachment?> _uploadPhoto(
    RemoteUploader uploader,
    _AttachSource source,
  ) async {
    final picked = await ImagePicker().pickImage(
      source: source == _AttachSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // Recompressed on the phone before it is ever pushed: a modern camera
      // JPEG is several megabytes, and the agent needs to SEE the screenshot,
      // not preserve its pixels.
      maxWidth: 2400,
      imageQuality: 88,
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    return await uploader.upload(
      bytes: bytes,
      kind: AttachmentKind.image,
      source: source == _AttachSource.camera
          ? AttachmentSource.camera
          : AttachmentSource.gallery,
      originalName: picked.name,
    );
  }

  String _uploadMessage(UploadException e, AppLocalizations l10n) =>
      switch (e.reason) {
        UploadFailure.refused =>
          e.detail == AttachmentRefusal.empty.name
              ? l10n.attachEmpty
              : l10n.attachTooLarge,
        UploadFailure.noHome => l10n.attachNoHome,
        UploadFailure.noDirectory => l10n.attachNoDirectory,
        UploadFailure.transfer => '${l10n.attachFailed}: ${e.detail ?? ''}',
      };

  /// Sends what a tap on the key bar produced.
  void _onKeyTap(SoftKey key) {
    // Actions are not keystrokes and never consume armed modifiers: arming Ctrl
    // and then reaching for Paste is not a request to send `\x1b^V`, it is two
    // unrelated intentions in a row.
    if (key.isAction) {
      if (key == SoftKey.copy) {
        unawaited(_copyFromBar());
      } else if (key == SoftKey.paste) {
        unawaited(_pasteFromBar());
      }
      return;
    }

    final outcome = _keys.tap(key);
    setState(() => _keys = KeyBarState(armed: outcome.armed));
    final bytes = outcome.bytes;
    if (bytes == null || bytes.isEmpty) return;
    _jumpToBottom();
    _session?.sendText(bytes);
  }

  /// The key bar's Copy: the selection if there is one, the screen if not.
  ///
  /// A Copy button that is dead until you have selected something is a button
  /// that looks broken on a phone, where selecting means a long-press and a
  /// drag. Falling back to the visible screen means the button always does the
  /// thing the user is most likely asking for.
  Future<void> _copyFromBar() async {
    final range = _selection;
    final text = (range != null && !range.isEmpty)
        ? selectionText(_terminal, range)
        : viewportText(
            _terminal,
            startLine: terminalViewport(
              totalLines: _terminal.buffer.lines.length,
              viewHeight: _rows,
              scrollOffset: _scrollOffset,
            ).start,
            rowCount: _rows,
          );
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _clearSelection();
  }

  Future<void> _pasteFromBar() async {
    final session = _session;
    if (session == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (!mounted) return;
    _jumpToBottom();
    session.sendText(
      pastePayload(text, bracketed: _terminal.bracketedPasteMode),
    );
  }

  /// Scrolls the viewport by a drag delta.
  void _onScrollDrag(DragUpdateDetails details) {
    // A pinch is in progress: those two fingers are resizing the terminal, and
    // the one that is still dragging must not also scroll it. The drag is not
    // cancelled (removing a callback mid-gesture does not release the arena), so
    // the guard lives here, where the decision is.
    if (_pinch.isPinching) return;

    final linesPerPixel = 1 / math.max(1, _lastCellHeight);
    _dragCarry += details.delta.dy * linesPerPixel;

    final whole = _dragCarry.truncate();
    if (whole == 0) return;
    _dragCarry -= whole;

    // CONTENT FOLLOWS THE FINGER: dragging DOWN pulls older lines into view,
    // dragging UP pushes back toward the live bottom. The first version had it
    // the other way round — a mouse-wheel convention (`up` shows history) on a
    // touch screen — and it reads as backwards the moment a thumb touches it:
    // on a phone, everything scrolls with the finger, and this must too.
    _scrollBy(whole);
  }

  /// Asks the daemon to move its viewport by [lines], positive meaning back.
  ///
  /// Every step is its own request, because there is no way to know what the far
  /// end has done until it re-renders — so the mirror is advanced by exactly
  /// what was asked for, and the frames that come back are what the user sees.
  void _scrollBy(int lines) {
    if (lines == 0) return;
    final next = math.max(0, _scrollOffset + lines);
    final step = next - _scrollOffset;
    if (step == 0) return;
    _session?.scroll(step);
    setState(() => _scrollOffset = next);
  }

  /// Begins a selection at the pressed cell.
  void _onSelectionStart(LongPressStartDetails details) {
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    setState(() {
      _selectionAnchor = cell;
      _selection = TerminalSelection.between(cell, cell);
    });
  }

  void _onSelectionMove(LongPressMoveUpdateDetails details) {
    final anchor = _selectionAnchor;
    if (anchor == null) return;
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    setState(() => _selection = TerminalSelection.between(anchor, cell));
  }

  void _onSelectionDrag(DragUpdateDetails details) {
    if (_pinch.isPinching) return;
    final anchor = _selectionAnchor;
    if (anchor == null) return;
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    setState(() => _selection = TerminalSelection.between(anchor, cell));
  }

  /// Maps a local position to a buffer cell.
  ///
  /// Goes through the viewport offset, so a selection made while scrolled back
  /// refers to the history the user is actually looking at rather than to
  /// whatever happens to be at that height on the live screen.
  (int, int)? _cellAt(Offset local) {
    if (_lastCellWidth <= 0 || _lastCellHeight <= 0) return null;

    final row = (local.dy / _lastCellHeight).floor();
    final column = (local.dx / _lastCellWidth).floor();
    if (row < 0 || column < 0) return null;

    final total = _terminal.buffer.lines.length;
    final window = terminalViewport(
      totalLines: total,
      viewHeight: _rows,
      scrollOffset: _scrollOffset,
    );
    final lineIndex = window.start + row;
    if (lineIndex < 0 || lineIndex >= total) return null;
    return (lineIndex, column);
  }

  void _clearSelection() => setState(() {
    _selection = null;
    _selectionAnchor = null;
  });

  Future<void> _copySelection() async {
    final range = _selection;
    if (range == null || range.isEmpty) return;
    final text = selectionText(_terminal, range);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _clearSelection();
  }

  void _jumpToBottom() {
    if (_following) return;
    // AS FAR AS YOU CAN, not "the number I think we are at". The far end clamps
    // a big request to the bottom (verified against a live daemon: 9999 lines
    // down lands on 0), which makes this self-correcting — the mirror below can
    // drift while output streams, because the daemon keeps a scrolled view
    // anchored by growing its own offset, and nothing in a rendered frame says
    // by how much.
    _session?.scroll(-_jumpToBottomLines);
    setState(() {
      _scrollOffset = 0;
      _dragCarry = 0;
    });
  }

  /// Reports a new viewport size to the daemon.
  ///
  /// Debounced, because a rotation or a keyboard animation fires many layout
  /// passes and every one of them would otherwise be a round trip that the
  /// daemon has to re-render for.
  Timer? _resizeDebounce;
  void _reportSize(int cols, int rows) {
    // The very first report is not a resize, it is the measurement the session
    // has been waiting on. There is no session yet, so there is nothing to
    // debounce or to tell.
    if (!_sizeReady.isCompleted) {
      _cols = cols;
      _rows = rows;
      _sizeReady.complete();
      return;
    }
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 180), () {
      _terminal.resize(cols, rows);
      _session?.resize(cols, rows);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    // The scheme's own colours, verbatim: a terminal scheme is what a terminal
    // is FOR. With no scheme selected this is the app's own tuning of the
    // xterm 16 against herdr's near-black ground.
    final palette = resolveTerminalColors(ref.watch(selectedThemeProvider));

    final glass = ref.watch(settingsProvider.select((s) => s.glassEnabled));
    final iconSet = ref.watch(settingsProvider.select((s) => s.iconSet));

    // Read HERE rather than inside `_buildSurface`: that one runs from a
    // `LayoutBuilder`, i.e. during layout, and a provider read outside the build
    // phase is not a dependency — it is a guess that happens to work until the
    // settings change.
    final storedZoom =
        ref.watch(settingsProvider.select((s) => s.terminalTextScale));
    final zoom = _pinchingScale ?? storedZoom;

    return CupertinoPageScaffold(
      backgroundColor: palette.background,
      navigationBar: HerdrTopBar(
        // The bar is transparent like every other one — what is behind it here
        // is the scaffold's own colour, i.e. the terminal ground, so the band
        // reads exactly as it did when the bar painted that colour itself.
        leading: HerdrBackButton(label: l10n.navBack),
        title: Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.foreground,
            fontSize: TextSize.strong,
          ),
        ),
        actions: [
          HerdrBarButton(
            label: l10n.terminalAttach,
            onPressed: _attaching ? null : () => unawaited(_attach()),
            child: _attaching
                ? CupertinoActivityIndicator(
                    radius: 8,
                    color: palette.cursor,
                  )
                : _toolbarGlyph(
                    iconSet: iconSet,
                    icon: UiIconName.attach,
                    fallback: CupertinoIcons.paperclip,
                    palette: palette,
                  ),
          ),
          HerdrBarButton(
            label: l10n.terminalPanes,
            onPressed: _openSwitcher,
            child: _toolbarGlyph(
              iconSet: iconSet,
              icon: UiIconName.panes,
              fallback: CupertinoIcons.rectangle_stack,
              palette: palette,
            ),
          ),
          // The way back out to the arrangement: a pane read full screen
          // loses all sense of what is beside it, and this is the one tap
          // that restores it.
          HerdrBarButton(
            label: l10n.terminalLayout,
            onPressed: _openLayout,
            child: _toolbarGlyph(
              iconSet: iconSet,
              icon: UiIconName.split,
              fallback: CupertinoIcons.rectangle_split_3x1,
              palette: palette,
            ),
          ),
          // Files and Git live here rather than as two more icons, and they
          // live HERE rather than only behind a long press on the workspaces
          // page. That long press is where they were, and it was invisible:
          // the feature existed, worked, and could not be found. A terminal
          // is where you are when you want to see what changed, and the pane
          // you are looking at already knows its own directory.
          //
          // A Builder so the button can hand its own context to the menu —
          // see [showHerdrMenu] for why a GlobalKey in a navbar is a trap.
          Builder(
            builder: (buttonContext) => HerdrBarButton(
              label: l10n.terminalMore,
              onPressed: () => _openMore(buttonContext),
              child: _toolbarGlyph(
                iconSet: iconSet,
                icon: UiIconName.more,
                fallback: CupertinoIcons.ellipsis_circle,
                palette: palette,
                size: 20,
              ),
            ),
          ),
          _StatusDot(
            busy: _busy,
            failed: _error != null,
            closed: _closeReason != null,
          ),
        ],
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                if (_selection != null && !_selection!.isEmpty)
                  _SelectionBar(
                    l10n: l10n,
                    palette: palette,
                    onCopy: () => unawaited(_copySelection()),
                    onCancel: _clearSelection,
                  )
                else if (!_following)
                  _ScrollBackBar(
                    offset: _scrollOffset,
                    palette: palette,
                    l10n: l10n,
                    onJump: _jumpToBottom,
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => _buildSurface(
                      context,
                      constraints,
                      palette,
                      colors,
                      l10n,
                      zoom,
                    ),
                  ),
                ),
                if (glass)
                  HerdrGlass(
                    colors: colors,
                    tintAlpha: 0.45,
                    borderRadius: BorderRadius.zero,
                    child: _keyBar(palette),
                  )
                else
                  _keyBar(palette),
                // The real input surface: invisible, nearly zero-height, and
                // the only thing that reliably raises the soft keyboard on both
                // platforms.
                //
                // THE RETURN KEY HAS TO BE WIRED UP EXPLICITLY. A single-line
                // text field with no `onSubmitted` does not insert a newline AND
                // does not submit anything — the IME's action key is simply a
                // no-op. That is exactly how it behaved: type a command, press
                // return, nothing happens, and it reads as "the app is
                // unfinished" rather than as a bug.
                SizedBox(
                  height: 1,
                  child: CupertinoTextField(
                    controller: _controller,
                    focusNode: _inputFocus,
                    autofocus: true,
                    showCursor: false,
                    decoration: null,
                    style: const TextStyle(
                      color: Color(0x00000000),
                      fontSize: 1,
                    ),
                    // Labels the IME key "send", rather than a return arrow that
                    // would suggest it inserts a line break.
                    textInputAction: TextInputAction.send,
                    // Reuses the key bar's own Enter, so an armed Ctrl applies
                    // to the keyboard's return exactly as it does to the bar's.
                    onSubmitted: (_) => _onKeyTap(SoftKey.enter),
                    // Keeps focus. The default for a non-newline action is to
                    // unfocus, which would drop the keyboard after every
                    // command.
                    onEditingComplete: () {},
                  ),
                ),
              ],
            ),
            // Everything the expanded key panel needs, drawn OVER the terminal
            // rather than under it. A panel that took layout space would resize
            // the grid — and the daemon renders at the size we report, so
            // opening a keyboard panel would resize the user's own pane twice
            // per tap. See [TerminalControl.open].
            // The dismiss surface covers the TERMINAL, not the bar. Leaving
            // the bar live is the point: the pinned buttons and the chips are
            // still the fastest way to send something, and a tap on one of them
            // should send it rather than be swallowed as "tap outside".
            if (_fanOpen)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: TerminalPageMetrics.keyBarHeight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeFan,
                ),
              ),
            if (_fanOpen)
              Positioned(
                right: Space.md,
                bottom: TerminalPageMetrics.keyBarHeight + Space.sm,
                child: _KeyFan(
                  // Named, so a test can aim at the panel rather than at "some
                  // widget somewhere that happens to say esc" — every key in it
                  // is also on the bar behind it.
                  key: keyFanKey,
                  keys: keyBarCatalogue,
                  state: _keys,
                  palette: palette,
                  colors: colors,
                  enabled: _session != null,
                  onTap: _tapKey,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _closeFan() => setState(() => _fanOpen = false);

  /// Sends a key, and tidies the expanded panel away if it is done its job.
  ///
  /// Used by the bar AND by the panel, so a key means the same thing whichever
  /// surface it was pressed on. The panel's own rule — modifiers stay, anything
  /// else closes — lives in the domain beside the bytes, because it is a
  /// property of the key rather than of the panel.
  void _tapKey(SoftKey key) {
    _onKeyTap(key);
    if (_fanOpen && !keyPanelStaysOpen(key)) _closeFan();
  }

  /// Raises the keyboard, or puts it away if it is already up.
  ///
  /// A TOGGLE, because a one-way button is a button that lies: once the input
  /// method is up, a control labelled "keyboard" that does nothing is worse
  /// than no control at all — the user presses it to make the keyboard go away
  /// and nothing happens.
  void _toggleKeyboard() {
    unawaited(HapticFeedback.selectionClick());
    if (_keyboardVisible) {
      _inputFocus.unfocus();
    } else {
      _raiseKeyboard();
    }
  }

  /// True when the input method is actually on screen.
  ///
  /// FROM THE INSETS, NOT FROM FOCUS, because they are different questions and
  /// the difference is the whole bug: dismissing the keyboard with the system's
  /// back gesture leaves the field FOCUSED with nothing on screen. A control
  /// that asked "do I have focus?" would therefore render itself as "hide the
  /// keyboard" over a screen with no keyboard on it, and pressing it would
  /// unfocus a field the user wanted to type into.
  bool get _keyboardVisible => MediaQuery.viewInsetsOf(context).bottom > 0;

  /// Makes the input method appear, whatever state the field is in.
  ///
  /// THE ALREADY-FOCUSED CASE IS THE ONE THAT MATTERS. A field that still holds
  /// focus does not raise the IME when focus is requested a second time — the
  /// platform considers the request satisfied and does nothing — so a keyboard
  /// button wired to `requestFocus()` alone works exactly once per screen and
  /// then reads as broken. Asking the text-input channel to show is the only
  /// thing that brings it back, and it is safe when it is already up.
  void _raiseKeyboard() {
    _inputFocus.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  /// A tap on the terminal itself.
  ///
  /// TWO THINGS, and they are the same thing on a phone: the grid is the input
  /// surface, so tapping it must raise the keyboard — which is what every
  /// terminal does and what this one did not do, leaving a tap that only
  /// scrolled and no way at all to type without a hardware keyboard. The
  /// jump-to-bottom stays because typing means you want the live screen.
  void _onSurfaceTap() {
    if (_selection != null) return;
    // The end of a two-finger gesture is not a tap. Without this the keyboard
    // comes up the moment a pinch or a pane switch finishes, because the last
    // finger to leave the glass leaves it without moving.
    if (_twoFinger.sawMultiplePointers || _pinch.isPinching) return;
    _jumpToBottom();
    _raiseKeyboard();
  }

  /// The key bar, wired to this page's modifier state and the user's layout.
  /// One toolbar glyph, in whichever set the user chose.
  ///
  /// The toolbar has no selection state, so the themed set is always drawn
  /// filled. Its ground is the terminal's own background rather than the app's
  /// card colour — the toolbar sits ON the terminal, and the terminal is a
  /// different kind of place.
  Widget _toolbarGlyph({
    required AppIconSet iconSet,
    required UiIconName icon,
    required IconData fallback,
    required TerminalColors palette,
    double size = 19,
  }) {
    if (iconSet == AppIconSet.system) {
      return Icon(fallback, color: palette.cursor, size: size);
    }
    return UiIcon(
      icon,
      size: size,
      variant: UiIconVariant.themed,
      color: palette.cursor,
      background: palette.background,
    );
  }

  /// The actions that belong to the pane rather than to the terminal's bytes.
  ///
  /// WHY A SHEET AND NOT THREE MORE ICONS. The bar already carries the three
  /// things you reach for while typing — attach, switch pane, show the split.
  /// These three are about the pane's DIRECTORY, which is a different question
  /// asked at a different moment. Four icons plus a status dot is where a
  /// phone navbar stops being readable at a glance.
  ///
  /// The rows are built from the pane the app already has, so a row that is
  /// shown always leads somewhere: no "Git changes" on a pane whose directory
  /// has not arrived yet, which would open a page that can only say it has
  /// nothing to read.
  Future<void> _openMore(BuildContext anchor) async {
    final l10n = AppLocalizations.of(context);
    // Measured before the first await: the button is a live widget now and a
    // Rect is a value, so nothing is read off a possibly-disposed element later.
    final anchorRect = menuAnchorRect(anchor);
    // Waits for a first read rather than refusing: a tap a second after the
    // terminal opened is a perfectly normal thing to do, and answering it with
    // "not yet" would be the app blaming the user for its own loading state.
    final tree = await ref.read(navTreeProvider.future);
    if (!mounted) return;
    final pane = tree.paneById(_paneId);
    if (pane == null) {
      // The tree is the only place the cwd and the focus flag come from, and
      // guessing at either would be worse than saying so. Reaching here means
      // the pane is genuinely gone — closed on the desktop since the tree was
      // read — rather than merely not loaded.
      showHerdrToast(context, l10n.morePaneUnknown, isError: true);
      return;
    }

    // A menu hanging off the button, not a sheet rising from the bottom edge:
    // the question is asked at the top of the screen and the answer belongs
    // beside it. See [showHerdrMenu] for why not `showMenu` either.
    final action = await showHerdrMenu<PaneAction>(
      context,
      anchorRect: anchorRect,
      themedIcons:
          ref.read(settingsProvider.select((s) => s.iconSet)) ==
          AppIconSet.themed,
      items: [
        for (final candidate in paneActionsFor(pane))
          HerdrMenuItem(
            value: candidate,
            label: labelForPaneAction(candidate, l10n),
            icon: paneActionGlyph(candidate).$1,
            cupertinoIcon: paneActionGlyph(candidate).$2,
          ),
      ],
    );

    if (!mounted || action == null) return;
    switch (action) {
      case PaneAction.browseFiles:
        _push(FileTreePage(path: pane.cwd!));
      case PaneAction.git:
        _push(GitPage(cwd: pane.cwd!));
      case PaneAction.focus:
        // Moving the desktop focus is reported either way: on failure the user
        // is left staring at their own screen wondering whether the tap
        // registered, and the pane may have closed in the meantime.
        try {
          await ref.read(navTreeProvider.notifier).focusPane(pane.paneId);
          if (mounted) {
            showHerdrToast(context, l10n.workspacesFocusDone);
          }
        } on Object {
          if (mounted) {
            showHerdrToast(context, l10n.workspacesFocusFailed, isError: true);
          }
        }
      // Never offered here: this page IS the pane opened, so a row that
      // reopened it would only close the screen offering it.
      case PaneAction.open:
        break;
    }
  }

  Widget _keyBar(TerminalColors palette) {
    return _KeyBar(
      keys: ref.watch(settingsProvider.select((s) => s.keyBarKeys)),
      state: _keys,
      enabled: _session != null,
      palette: palette,
      onTap: _tapKey,
      onKeyboard: _toggleKeyboard,
      // Read from the platform's own insets rather than from the focus node:
      // focus is not the same question. A hardware keyboard leaves the field
      // focused with nothing on screen, and the button has to describe what the
      // user can see.
      keyboardUp: _keyboardVisible,
      onExpand: () {
        unawaited(HapticFeedback.selectionClick());
        setState(() => _fanOpen = !_fanOpen);
      },
      expanded: _fanOpen,
    );
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
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        height: 1,
      ),
    );
    // A cell must be wide enough for the widest thing it can hold. The
    // ideographic space above gives the full-width advance; the Latin cell is
    // half of it by definition of a monospace CJK font.
    final cellWidth = metrics.width / 2;
    final cellHeight = metrics.height;

    final cols = (constraints.maxWidth / cellWidth).floor().clamp(20, 400);
    final rows = (constraints.maxHeight / cellHeight).floor().clamp(5, 400);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _reportSize(cols, rows),
    );

    if (_busy || _error != null || _closeReason != null) {
      return _Overlay(
        busy: _busy,
        error: _error,
        closeReason: _closeReason,
        palette: palette,
        l10n: l10n,
      );
    }

    _lastCellHeight = cellHeight;
    _lastCellWidth = cellWidth;

    return Stack(
      children: [
        RepaintBoundary(
      // Observes only. `deferToChild` keeps every gesture the surface already
      // handles working exactly as before.
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        child: GestureDetector(
          // Opaque so a drag anywhere on the grid scrolls rather than being
          // swallowed by whatever is behind it.
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: _selection != null
              ? _onSelectionDrag
              : _onScrollDrag,
          // A horizontal swipe moves between TABS, and only when nothing is
          // selected — with a selection up, a horizontal drag belongs to the
          // selection, exactly as the vertical one does.
          //
          // That guard is the whole design. The reference iOS client shipped this
          // gesture and then REMOVED it, because a drag meant to select text
          // paged to another agent instead; the fix is the condition, not the
          // removal.
          onHorizontalDragEnd: _selection != null
              ? null
              : (details) {
                  // A second finger was down at some point during this gesture,
                  // so this drag is the opening of a two-finger swipe and not a
                  // tab change. Both fingers land within milliseconds, but the
                  // FIRST can travel past the slop before the second arrives —
                  // timing cannot separate them, a pointer count can.
                  if (_twoFinger.sawMultiplePointers) return;
                  final velocity = details.primaryVelocity ?? 0;
                  // A swipe, not a wobble: a slow drag across the grid is
                  // somebody reading, and it should not navigate anywhere.
                  if (velocity.abs() < 240) return;
                  unawaited(_swipeTab(velocity < 0 ? 1 : -1));
                },
          onLongPressStart: _onSelectionStart,
          onLongPressMoveUpdate: _onSelectionMove,
          onLongPressEnd: (_) {},
          // Typing means you want the live screen: leaving the view parked in
          // history while keystrokes go to the shell is the most confusing thing
          // a terminal can do.
          onTap: _onSurfaceTap,
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
              // Zero, always: the frames the daemon sends while scrolled ARE
              // the history, so there is nothing left for the painter to
              // offset — `_scrollOffset` describes the far end's viewport, not
              // a window into our buffer.
              scrollOffset: 0,
              selection: _selection,
              repaint: _repaint,
            ),
          ),
        ),
      ),
        ),
        // The readout sits at the TOP of the grid, under the bar: while two
        // fingers are on the glass they cover the middle of the screen, and a
        // number they cannot see is not feedback.
        if (_pinchingScale != null)
          Positioned(
            top: Space.md,
            left: 0,
            right: 0,
            child: Center(
              child: _ZoomReadout(
                zoom: _pinchingScale!,
                cols: cols,
                rows: rows,
                palette: palette,
                l10n: l10n,
                glass: ref.watch(settingsProvider.select((s) => s.glassEnabled)),
              ),
            ),
          ),
      ],
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    final point = (x: event.position.dx, y: event.position.dy);
    _twoFinger.down(event.pointer, point);
    _pinch.down(event.pointer, point);
  }

  void _onPointerMove(PointerMoveEvent event) {
    final point = (x: event.position.dx, y: event.position.dy);
    _twoFinger.move(event.pointer, point);
    final direction = _twoFinger.takeDirection();
    if (direction != null) unawaited(_swipePane(direction));

    // The zoom, on the same pointers: no recogniser is involved, so the two
    // gestures cannot fight over the arena — the arming rule in [PinchTracker]
    // is what decides which one this is.
    final wasPinching = _pinch.isPinching;
    _pinch.move(event.pointer, point);
    if (!_pinch.isPinching) return;
    if (!wasPinching) {
      // Arming is the moment the size is fixed against: a pinch that is
      // measured from before its own threshold would jump on the first frame.
      _pinchBase = _pinchingScale ??
          ref.read(settingsProvider.select((s) => s.terminalTextScale));
    }
    final next = (_pinchBase * _pinch.scale)
        .clamp(kTerminalMinZoom, kTerminalMaxZoom);
    if (next == _pinchingScale) return;
    setState(() => _pinchingScale = next);
  }

  void _onPointerUp(PointerEvent event) {
    final wasPinching = _pinch.isPinching;
    _twoFinger.up(event.pointer);
    _pinch.up(event.pointer);
    if (!wasPinching || _pinch.isPinching) return;

    final zoom = _pinchingScale;
    if (zoom == null) return;
    // Committed whole, once, when the gesture ends. Writing to the settings on
    // every frame of the pinch would rebuild the whole app sixty times a second
    // and leave a trail of preference writes behind a gesture that is not over.
    unawaited(ref.read(settingsProvider.notifier).setTerminalTextScale(zoom));
    setState(() => _pinchingScale = null);
  }
}

/// What a pinch is doing, while it is doing it.
///
/// The number is the FONT size as a percentage of the base, because that is what
/// the user is changing; the grid underneath it is what it costs, and showing
/// both is what makes a resize honest — a terminal that reflows 68 columns down
/// to 40 is something the user should see before letting go.
class _ZoomReadout extends StatelessWidget {
  const _ZoomReadout({
    required this.zoom,
    required this.cols,
    required this.rows,
    required this.palette,
    required this.l10n,
    required this.glass,
  });

  final double zoom;
  final int cols;
  final int rows;
  final TerminalColors palette;
  final AppLocalizations l10n;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final percent = (zoom * 100).round();

    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.xs + 2,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.terminalZoomFont(percent),
            style: TextStyle(color: colors.text, fontSize: TextSize.strong),
          ),
          Text(
            '$cols \u00d7 $rows',
            style: TextStyle(
              color: colors.textDim,
              fontSize: TextSize.meta,
              fontFamily: HerdrFonts.mono,
            ),
          ),
        ],
      ),
    );

    return glass
        ? HerdrGlass(
            colors: colors,
            borderRadius: BorderRadius.circular(Radii.uniform),
            child: body,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              boxShadow: Elevation.card(colors),
            ),
            child: body,
          );
  }
}

/// Drives repaints after the terminal model changes.
///
/// xterm's `Terminal` is an `Observable`, not a Flutter `Listenable`, so it
/// cannot be handed to `CustomPainter.repaint` directly. Firing this alongside
/// each write is a one-line cost and keeps the model and the painter decoupled.
class _Repaint extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// Tells the reader they are not looking at the live screen, and offers one tap
/// back. Without this, a terminal that is silently parked in history looks
/// broken — keystrokes go somewhere the user cannot see.
class _ScrollBackBar extends StatelessWidget {
  const _ScrollBackBar({
    required this.offset,
    required this.palette,
    required this.l10n,
    required this.onJump,
  });

  final int offset;
  final TerminalColors palette;
  final AppLocalizations l10n;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onJump,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 28,
        color: palette.cursor.withValues(alpha: 0.18),
        alignment: Alignment.center,
        child: Text(
          l10n.terminalScrolledBack(offset),
          style: TextStyle(
            color: palette.foreground,
            fontSize: TextSize.meta,
            fontFamily: HerdrFonts.mono,
          ),
        ),
      ),
    );
  }
}

/// Copy or dismiss, while a selection is active.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.l10n,
    required this.palette,
    required this.onCopy,
    required this.onCancel,
  });

  final AppLocalizations l10n;
  final TerminalColors palette;
  final VoidCallback onCopy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: palette.cursor.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.terminalSelectionHint,
              style: TextStyle(
                color: palette.foreground,
                fontSize: TextSize.meta,
                fontFamily: HerdrFonts.mono,
              ),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            minimumSize: Size.zero,
            onPressed: onCancel,
            child: Text(
              l10n.actionCancel,
              style: TextStyle(
                color: palette.foreground,
                fontSize: TextSize.note,
              ),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            minimumSize: Size.zero,
            onPressed: onCopy,
            child: Text(
              l10n.copyAction,
              style: TextStyle(color: palette.cursor, fontSize: TextSize.note),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.busy,
    required this.failed,
    required this.closed,
  });

  final bool busy;
  final bool failed;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    // Read from the theme rather than spelled out in hex. The four values that
    // used to be here were the built-in palette's status colours, which under a
    // scheme are four different colours — and a single colour that means
    // "waiting" on one scheme and nothing at all on another is worse than no
    // colour.
    final colors = HerdrTheme.of(context);
    final color = failed
        ? colors.died
        : closed
        ? colors.waiting
        : busy
        ? colors.working
        : colors.done;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The keys a soft keyboard cannot produce.
///
/// Without these a phone terminal is unusable: there is no way to send Escape,
/// no way to interrupt, and no arrow keys — which is most of what you need to
/// drive a TUI or a REPL.
///
/// The bar is a VIEW of [KeyBarState] and nothing else. It does not know what a
/// key sends, it does not decide whether a modifier is still armed, and it has
/// no state of its own — all of that is in the domain, where it can be tested
/// without a widget, and where the soft keyboard can use the same rules.
class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.keys,
    required this.state,
    required this.onTap,
    required this.palette,
    required this.enabled,
    required this.onKeyboard,
    required this.keyboardUp,
    required this.onExpand,
    required this.expanded,
  });

  /// Which keys to offer, in order. Comes from Settings.
  final List<SoftKey> keys;
  final KeyBarState state;
  final ValueChanged<SoftKey> onTap;
  final TerminalColors palette;
  final bool enabled;

  /// Raises or puts away the input method.
  final VoidCallback onKeyboard;
  final bool keyboardUp;

  /// Opens the panel holding the rest of the catalogue.
  final VoidCallback onExpand;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    // TWO BUTTONS PINNED TO THE RIGHT, outside the scroller.
    //
    // The bar scrolls horizontally, and anything inside that scroller can be
    // scrolled off the end — which is precisely the wrong property for the two
    // controls that have to be reachable at all times: "give me a keyboard",
    // and "show me everything else". Pinned, they are the only two things on
    // this row whose position a user can learn.
    return Container(
      height: TerminalPageMetrics.keyBarHeight,
      color: palette.background,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
              itemCount: keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
              itemBuilder: (context, i) {
                final key = keys[i];
                return _KeyCap(
                  cap: key,
                  palette: palette,
                  armed: key.isModifier && state.isArmed(_modifierOf(key)),
                  enabled: enabled,
                  onTap: () => onTap(key),
                );
              },
            ),
          ),
          _BarButton(
            palette: palette,
            selected: keyboardUp,
            onTap: onKeyboard,
            semanticsLabel: keyboardUp
                ? AppLocalizations.of(context).terminalHideKeyboard
                : AppLocalizations.of(context).terminalShowKeyboard,
            icon: CupertinoIcons.keyboard,
          ),
          _BarButton(
            palette: palette,
            selected: expanded,
            onTap: onExpand,
            semanticsLabel: AppLocalizations.of(context).terminalAllKeys,
            icon: CupertinoIcons.square_grid_3x2,
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
    );
  }

  static TerminalModifier _modifierOf(SoftKey key) => switch (key) {
    SoftKey.ctrl => TerminalModifier.ctrl,
    SoftKey.alt => TerminalModifier.alt,
    SoftKey.shift => TerminalModifier.shift,
    _ => throw ArgumentError('$key is not a modifier'),
  };
}

/// One of the two pinned controls at the end of the bar.
///
/// An ICON, unlike every cap beside it, and the difference is meaningful rather
/// than cosmetic: a cap sends a byte to the machine, and these two do something
/// to this phone. Drawing them as words in the same chips as `esc` and `C-c`
/// would put "keyboard" in a list of things the terminal understands, which it
/// is not.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.palette,
    required this.selected,
    required this.onTap,
    required this.semanticsLabel,
    required this.icon,
  });

  final TerminalColors palette;
  final bool selected;
  final VoidCallback onTap;
  final String semanticsLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 40,
          height: TerminalPageMetrics.keyBarHeight,
          alignment: Alignment.center,
          child: Container(
            width: 30,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? palette.cursor.withValues(alpha: 0.22)
                  : colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              border: Border.all(
                color: selected ? palette.cursor : colors.hairline,
              ),
            ),
            child: Icon(
              icon,
              size: 16,
              color: selected ? palette.cursor : colors.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Identifies the expanded key panel.
///
/// A public key rather than a private type because the panel's whole point is
/// that it duplicates the bar: without a handle on it, any test of "tap Ctrl in
/// the panel" is a test of "tap one of the two widgets that say Ctrl".
const Key keyFanKey = ValueKey('terminal-key-fan');

/// The measurements the bar and the panel above it share.
///
/// Two widgets, one number: the panel floats exactly [keyBarHeight] above the
/// bottom of the stack, and if the bar's height lived in two places the panel
/// would slowly drift onto it.
abstract final class TerminalPageMetrics {
  static const double keyBarHeight = 46;
}

/// Every key in the catalogue, in a panel that arcs out of the toolbar.
///
/// WHY THIS EXISTS. The bar is a horizontal scroller and the catalogue is
/// twenty-four keys long, so most of it is off-screen — reachable, but only by
/// a scroll gesture nobody performs while an agent is waiting. The alternative
/// — a bar wide enough for everything — would be a wall of chips across the
/// bottom third of the terminal.
///
/// THE EXPANSION IS AN ARC, TWICE OVER, and that is the whole visual idea:
/// the panel is revealed by a circle growing out of the corner it is anchored
/// to, and each cap travels to its place along a bowed path rather than
/// straight to it. Caps land in a stagger so the panel assembles instead of
/// appearing — which is what makes the relationship between the button and the
/// panel legible in the 200 milliseconds before the user starts reading it.
class _KeyFan extends StatefulWidget {
  const _KeyFan({
    required this.keys,
    required this.state,
    required this.palette,
    required this.colors,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final List<SoftKey> keys;
  final KeyBarState state;
  final TerminalColors palette;
  final HerdrColors colors;
  final bool enabled;
  final ValueChanged<SoftKey> onTap;

  @override
  State<_KeyFan> createState() => _KeyFanState();
}

class _KeyFanState extends State<_KeyFan> with SingleTickerProviderStateMixin {
  /// Long enough to be seen, short enough that it is never in the way.
  ///
  /// A panel that takes half a second to assemble is a panel the user waits
  /// for; this one is finished before the eye has finished moving to it, and it
  /// still reads as motion rather than as a jump cut.
  static const Duration _duration = Duration(milliseconds: 210);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colours = widget.colors;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        return ClipPath(
          clipper: _ArcRevealClipper(_controller.value),
          child: Opacity(opacity: t.clamp(0, 1), child: child),
        );
      },
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.all(Space.sm),
        decoration: BoxDecoration(
          color: colours.surface,
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(color: colours.hairline),
          boxShadow: Elevation.card(colours),
        ),
        child: Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (var i = 0; i < widget.keys.length; i++)
              _FanKey(
                progress: _controller,
                index: i,
                // The arc: half a second of stagger across the whole panel, so
                // the caps leave the corner in order.
                delay: i * 0.012,
                child: _KeyCap(
                  cap: widget.keys[i],
                  palette: widget.palette,
                  armed: widget.keys[i].isModifier &&
                      widget.state.isArmed(_modifierFor(widget.keys[i])),
                  enabled: widget.enabled,
                  onTap: () => widget.onTap(widget.keys[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static TerminalModifier _modifierFor(SoftKey key) => switch (key) {
    SoftKey.ctrl => TerminalModifier.ctrl,
    SoftKey.alt => TerminalModifier.alt,
    SoftKey.shift => TerminalModifier.shift,
    _ => throw ArgumentError('$key is not a modifier'),
  };
}

/// One cap's journey out of the button's corner.
///
/// The path is a QUADRATIC BOW rather than a straight line: the cap leaves the
/// anchor heading sideways and arrives heading up, which is the difference
/// between a panel that fans open and a grid that fades in. The bow is a
/// fraction of the distance travelled, so a cap near the anchor moves almost
/// straight and the far corner swings the most — the same way a fan does.
class _FanKey extends StatelessWidget {
  const _FanKey({
    required this.progress,
    required this.index,
    required this.delay,
    required this.child,
  });

  final Animation<double> progress;
  final int index;
  final double delay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, inner) {
        // Each cap has its own slice of the timeline, and its own curve: the
        // overshoot on the scale is what makes the last few caps feel like they
        // snapped into place rather than slid.
        final t = ((progress.value - delay) / (1 - delay)).clamp(0.0, 1.0);
        final eased = Curves.easeOutBack.transform(t);
        final travel = Curves.easeOutCubic.transform(t);

        // 0 = still at the button; 1 = in its cell.
        return Transform.translate(
          offset: Offset(
            // Rightwards and downwards from the button: the panel is anchored
            // at the bottom-right, so everything in it comes from there.
            (1 - travel) * (28 + index % 4 * 6),
            (1 - travel) * (14 + index ~/ 4 * 10),
          ),
          child: Transform.scale(
            scale: 0.4 + 0.6 * eased,
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}

/// Grows a circle out of the panel's bottom-right corner.
///
/// `progress` runs 0→1 and the radius is measured to the far corner, so at 1
/// the circle contains the panel by construction rather than by a constant
/// somebody tuned on one phone.
class _ArcRevealClipper extends CustomClipper<Path> {
  _ArcRevealClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    final centre = Offset(size.width, size.height);
    final reach = (size.width + size.height) * Curves.easeOutCubic.transform(
      progress.clamp(0.0, 1.0),
    );
    return Path()
      ..addOval(Rect.fromCircle(center: centre, radius: reach))
      ..close();
  }

  @override
  bool shouldReclip(_ArcRevealClipper old) => old.progress != progress;
}

/// One button on the bar.
///
/// Copy and Paste are drawn as ICONS while every other key is a word, and that
/// is deliberate rather than decorative: `Ctrl+C` in a terminal is SIGINT, not
/// copy. A bar that rendered a button reading "Copy" in the same style as a
/// button reading "C-c" would be inviting the one mistake that costs you a
/// running agent.
class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.cap,
    required this.armed,
    required this.enabled,
    required this.onTap,
    required this.palette,
  });

  final SoftKey cap;
  final bool armed;
  final bool enabled;
  final VoidCallback onTap;
  final TerminalColors palette;

  @override
  Widget build(BuildContext context) {
    // The chips are APP chrome that happens to float over the terminal, so
    // they take the app's chip colours — the same fill and edge as every other
    // control in the app. They used to be spelled out in hex, which was the
    // built-in palette written down a second time: a scheme changed the
    // terminal underneath while the bar stayed the old navy.
    final colors = HerdrTheme.of(context);
    final foreground = armed
        ? palette.cursor
        : cap.isAction
        // The one interactive tint. Not a status colour: Copy and Paste are
        // controls, and borrowing "working" to mean "button" is how a colour
        // stops meaning anything.
        ? colors.accent
        : colors.textDim;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      // `Align` WITH A WIDTH FACTOR, not `Center`. A bare `Center` expands to
      // fill whatever it is given, which is invisible in the bar (a horizontal
      // list gives it unbounded width, so it shrink-wraps anyway) and wrong the
      // moment the same cap is placed in the expanded panel: a `Wrap` hands its
      // children the FULL width as a loose constraint, so every cap became a
      // full-width pill and the panel turned into one key per row. `widthFactor`
      // asks for the child's own width; the bar's tight height still wins.
      child: Align(
        widthFactor: 1,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            height: 28,
            // NO `alignment`, and it is the whole reason the expanded panel
            // works: a `Container.alignment` wraps the child in an `Align` with
            // NO width factor, which fills whatever width it is offered. In the
            // bar that is invisible (the list offers unbounded width), and in
            // the panel it made every cap a full-width pill — one key per row,
            // a 856-point-tall wall of chips. The chip must be the size of its
            // own label.
            decoration: BoxDecoration(
              color: armed
                  ? palette.cursor.withValues(alpha: 0.22)
                  : colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              border: Border.all(
                color: armed ? palette.cursor : colors.hairline,
              ),
            ),
            // `Align` WITH A WIDTH FACTOR, for the vertical half of the job the
            // fixed `height` above hands over. A tight height makes the child
            // exactly 28 tall, and a `Text` given a tight height LAYS ITSELF
            // OUT AT THE TOP of it — the labels sat visibly high in their
            // pills, `esc` and `Ctrl` alike.
            //
            // Same rule as the outer `Align`, same reason: no `widthFactor`
            // means the box fills whatever width it is offered. In the bar
            // (unbounded) that is invisible; in the expanded panel (`Wrap`,
            // loose full-width constraints) it is a key per row.
            child: Align(
              widthFactor: 1,
              child: _label(foreground),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(Color foreground) => switch (cap) {
    SoftKey.copy => Icon(
      CupertinoIcons.doc_on_doc,
      size: 15,
      color: foreground,
    ),
    SoftKey.paste => Icon(
      CupertinoIcons.doc_on_clipboard,
      size: 15,
      color: foreground,
    ),
    _ => Text(
      cap.label,
      style: TextStyle(
        color: foreground,
        fontSize: TextSize.meta,
        fontFamily: HerdrFonts.mono,
      ),
    ),
  };
}

/// What the terminal shows when it is not showing a terminal.
class _Overlay extends StatelessWidget {
  const _Overlay({
    required this.busy,
    required this.error,
    required this.closeReason,
    required this.palette,
    required this.l10n,
  });

  final bool busy;
  final Object? error;
  final String? closeReason;

  /// The terminal's colours, not the app's: this text sits ON the terminal's
  /// own ground, so the scheme's foreground/background PAIR is the only thing
  /// guaranteed to be legible here. The built-in scheme's ink is the same
  /// `#EEF0F7` that used to be hard-coded here.
  final TerminalColors palette;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final (String title, String detail) = switch ((busy, error, closeReason)) {
      (true, _, _) => (l10n.terminalConnecting, ''),
      (_, final Object e, _) => (_explain(e, l10n), '$e'),
      (_, _, final String r) => (l10n.terminalExited, r),
      _ => ('', ''),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.foreground,
                fontSize: TextSize.strong,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.foreground.withValues(alpha: 0.68),
                  fontSize: TextSize.note,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _explain(Object e, AppLocalizations l10n) {
    if (e is HerdrTransportException) {
      if (e.message.contains(herdrNotInstalledSentinel)) {
        return l10n.errorHerdrNotFound;
      }
      return l10n.errorGeneric;
    }
    return l10n.errorGeneric;
  }
}

/// Which door the attachment came in through.
enum _AttachSource { clipboard, gallery, camera }
