import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/domain/terminal/composer.dart';

/// What the input connection is put back to after every edit.
///
/// The caret sits after the sentinel, which is where the next typed character
/// lands, and the two spaces are the sentinel itself. See
/// `domain/terminal/composer.dart` for why there are two.
const TextEditingValue kComposerResting = TextEditingValue(
  text: kComposerSentinel,
  selection: TextSelection.collapsed(offset: 2),
);

/// The terminal's keyboard surface: an invisible field that turns a phone's
/// keyboard into terminal keystrokes.
///
/// The field is left holding [kComposerResting] between keystrokes — two spaces
/// the user never sees — so that a backspace always has something to delete. The
/// rules that turn a report into keystrokes live in
/// `domain/terminal/composer.dart`.
///
/// WHY NOT A `CupertinoTextField` AND AN `onChanged` DIFF, which is what this
/// replaced. A text field only reports a CHANGE, so a backspace on an empty
/// field reports nothing at all — and because the old widget cleared itself
/// after every keystroke, its field was always empty, so the delete key was
/// dead for the entire session. The user could type into a TUI's input box and
/// then not take a character back out of it. The sentinel in
/// `domain/terminal/composer.dart` is the fix; this widget is the half that
/// owns the input connection.
///
/// AND A HARDWARE KEYBOARD IS A SECOND DOOR. A physical keyboard — a Bluetooth
/// one on the desk, or anything driving the phone through `adb shell input` —
/// does not go through the IME at all: it arrives as key events on the focus
/// node. A real text field gets that half for free; a hand-written client has
/// to ask for it, and the terminal would simply type nothing from a real
/// keyboard without [_onKeyEvent].
///
/// WHY A HAND-WRITTEN `TextInputClient` RATHER THAN A FIELD. Owning the
/// connection is also what makes `setEditingState` possible on our own terms:
/// the field is put back to the sentinel after every report, so nothing
/// accumulates, and the IME is configured once with the features that would
/// otherwise rewrite what the user typed. That configuration matters more here
/// than anywhere else in the app — the characters go to a shell, where a
/// "helpful" autocorrect is not a typo, it is a command.
class TerminalComposer extends StatefulWidget {
  const TerminalComposer({
    required this.focusNode,
    required this.onInsert,
    required this.onDelete,
    required this.onEnter,
    this.autofocus = true,
    super.key,
  });

  /// The node the page raises the keyboard with.
  ///
  /// Owned by the caller: the terminal page unfocuses it when it pushes a page
  /// (the keyboard would otherwise sit over a screen that has no use for it)
  /// and focuses it again on the way back.
  final FocusNode focusNode;

  /// Text the user typed, to be sent as-is.
  final void Function(String text) onInsert;

  /// The backspace key, [count] times.
  final void Function(int count) onDelete;

  /// The keyboard's own action key ("send"), which in a terminal is Enter.
  final VoidCallback onEnter;

  final bool autofocus;

  @override
  State<TerminalComposer> createState() => _TerminalComposerState();
}

class _TerminalComposerState extends State<TerminalComposer>
    with TextInputClient {
  TextInputConnection? _connection;

  /// What the input connection last told the keyboard.
  ///
  /// Kept because the connection can be re-shown without being re-attached —
  /// the system's back gesture dismisses the keyboard and leaves the field
  /// focused — and a re-shown connection that has forgotten its text is a
  /// keyboard with an empty field over a terminal that is not empty.
  TextEditingValue _state = kComposerResting;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    if (widget.focusNode.hasFocus) {
      // Already focused: this can happen when the page is rebuilt under a
      // route that was popped. The listener would never fire, and the terminal
      // would be the one screen in the app that silently has no keyboard.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusChange());
    }
  }

  @override
  void didUpdateWidget(TerminalComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
      _onFocusChange();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    // Closed rather than left to the framework: a connection that outlives its
    // client is a keyboard typing into a disposed state object.
    _connection?.close();
    _connection = null;
    super.dispose();
  }

  void _onFocusChange() {
    if (widget.focusNode.hasFocus) {
      _openOrShow();
    } else {
      _close();
    }
  }

  void _openOrShow() {
    final open = _connection;
    if (open != null && open.attached) {
      // `show` rather than a fresh attach: the connection is still ours, and
      // re-attaching would throw away the editing state the IME is holding.
      open.show();
      return;
    }

    _state = kComposerResting;
    final connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        // Enter has no other meaning in a terminal, and the label says so.
        inputAction: TextInputAction.send,
        // THE FOUR THAT KEEP THE USER'S COMMAND INTACT. Autocorrect, predictive
        // suggestions and personalised learning all rewrite words in place, and
        // the rewrite arrives here as an edit that is neither typing nor a
        // backspace — which the sentinel reader discards. That is a silent loss
        // of a keystroke, so the features are turned off at the source instead.
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );
    _connection = connection;
    connection.show();
    connection.setEditingState(_state);
  }

  /// Hardware keys, which never reach the input connection.
  ///
  /// Only the three that have an unambiguous terminal meaning are handled here:
  /// the delete key, Enter, and printable characters. Arrows, Escape and Tab
  /// are deliberately left alone — the key bar sends those with the escape
  /// sequences they need, and a phone keyboard sends none of them anyway.
  ///
  /// With Ctrl or Alt held the platform reports no character, so nothing is
  /// typed and nothing is wrongly typed either: the sticky modifiers on the key
  /// bar remain the app's way to reach a control code.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      widget.onDelete(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      widget.onEnter();
      return KeyEventResult.handled;
    }

    final character = event.character;
    if (character != null && character.isNotEmpty) {
      widget.onInsert(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _close() {
    final open = _connection;
    _connection = null;
    if (open != null && open.attached) open.close();
  }

  // ------------------------------------------------------------- the client ---

  @override
  TextEditingValue? get currentTextEditingValue => _state;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _state = value;

    switch (ComposerBuffer.read(
      text: value.text,
      composing: !value.composing.isCollapsed,
    )) {
      case ComposerTyped(:final text):
        widget.onInsert(text);
      case ComposerDeleted(:final count):
        widget.onDelete(count);
      case ComposerComposing():
      case ComposerNothing():
        break;
    }

    // Back to the sentinel, BEFORE the next keystroke. Leaving what was typed
    // in the field would make the next backspace delete the one before it
    // twice over — the terminal already has those characters, and the field is
    // only a keyboard, not an echo of the pane.
    if (ComposerBuffer.needsReset(
      text: value.text,
      composing: !value.composing.isCollapsed,
    )) {
      _state = kComposerResting;
      final open = _connection;
      if (open != null && open.attached) open.setEditingState(_state);
    }
  }

  @override
  void performAction(TextInputAction action) {
    // Whatever the action key is labelled, in a terminal it means Enter. The
    // configuration above asks for `send`; keyboard apps are free to answer
    // with `done` or `go` on their own terms, and refusing those would leave
    // the most important key in the app dead on some phone somewhere.
    widget.onEnter();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
  }

  @override
  Widget build(BuildContext context) {
    // One point tall and transparent: the field is a keyboard handle, not a
    // place. It is laid out at the bottom of the page so the IME's own
    // "keep the caret visible" arithmetic agrees with where the terminal's
    // input line is.
    return SizedBox(
      height: 1,
      width: double.infinity,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onKeyEvent: _onKeyEvent,
        // The terminal's gestures are the pointer's, not the focus system's.
        canRequestFocus: true,
        child: const SizedBox.expand(),
      ),
    );
  }
}
