/// The terminal key bar's rules, as data.
///
/// PURE DART ON PURPOSE. What a key sends is not a drawing decision — it is the
/// difference between interrupting an agent and copying its output, and it is
/// arithmetic nobody can eyeball. Keeping it here means it is testable without a
/// widget, and it is the same rules for the on-screen bar and for whatever the
/// soft keyboard types.
library;

/// A modifier that arms and then applies to the NEXT thing typed.
///
/// WHY THESE ARE STICKY AND NOT HELD. A terminal carries BYTES, not key events:
/// there is no "shift" byte and no "control" byte on the wire. A modifier only
/// exists as a combination — `Ctrl+C` is `\x03`, `Shift+Tab` is `ESC [ Z`,
/// `Alt+f` is `ESC f`. So a modifier button cannot send anything when it is
/// pressed; it has to wait for a key to combine with. That is a sticky key, and
/// it is the only design that matches what the protocol can express.
enum TerminalModifier {
  ctrl('Ctrl'),
  alt('Alt'),
  shift('Shift');

  TerminalModifier(this.label);

  final String label;
}

/// A key the bar can offer.
///
/// The catalogue is deliberately wider than the default bar: the bar is a
/// horizontal scroller on a phone and every key added to it costs every user,
/// so the default is the set you reach for under pressure and the rest is one
/// trip to Settings away.
enum SoftKey {
  // --- Modifiers: arm, then combine with the next key. ---
  ctrl('ctrl', 'Ctrl', KeyKind.modifier),
  alt('alt', 'Alt', KeyKind.modifier),
  shift('shift', 'Shift', KeyKind.modifier),

  // --- Literal keys. ---
  esc('esc', 'esc', KeyKind.literal),
  tab('tab', 'tab', KeyKind.literal),
  enter('enter', 'enter', KeyKind.literal),
  space('space', 'space', KeyKind.literal),
  backspace('bs', '\u232b', KeyKind.literal),

  up('up', '\u2191', KeyKind.literal),
  down('down', '\u2193', KeyKind.literal),
  left('left', '\u2190', KeyKind.literal),
  right('right', '\u2192', KeyKind.literal),

  home('home', 'home', KeyKind.literal),
  end('end', 'end', KeyKind.literal),
  pageUp('pgup', 'pgup', KeyKind.literal),
  pageDown('pgdn', 'pgdn', KeyKind.literal),
  delete('del', 'del', KeyKind.literal),

  // --- Ready-made control codes. ---
  //
  // Redundant with `Ctrl` plus a letter, and kept anyway: `C-c` is the single
  // most-pressed key in this app after the arrows, and making it two taps to
  // interrupt an agent would be a worse product for a tidier key list.
  interrupt('c-c', 'C-c', KeyKind.literal),
  eof('c-d', 'C-d', KeyKind.literal),
  suspend('c-z', 'C-z', KeyKind.literal),
  clear('c-l', 'C-l', KeyKind.literal),
  reverseSearch('c-r', 'C-r', KeyKind.literal),

  // --- Actions. Not keystrokes at all; see [SoftKey.isAction]. ---
  //
  // THIS IS WHERE CMD/WIN ENDS UP, and that is not a shortcut. macOS Terminal
  // intercepts Cmd+C and Cmd+V at the APPLICATION level — the shell never sees
  // them, and no terminal protocol carries a "command" byte. So "Command+C" is
  // not a keystroke this app can send; it is exactly this button. Offering a
  // `Cmd` key would be offering something that cannot do anything.
  copy('copy', 'Copy', KeyKind.action),
  paste('paste', 'Paste', KeyKind.action);

  SoftKey(this.id, this.label, this.kind);

  /// Stable identifier, used for persistence. Never derived from the label: a
  /// label is allowed to change, a stored preference is not.
  final String id;

  final String label;
  final KeyKind kind;

  bool get isModifier => kind == KeyKind.modifier;

  /// True for keys that do not produce terminal bytes at all.
  ///
  /// Copy is the important one: `Ctrl+C` in a terminal is **SIGINT**, not copy,
  /// and a bar that offered only `C-c` next to a button labelled "copy" would be
  /// inviting exactly that mistake. The two do different things and are drawn
  /// differently because of it.
  bool get isAction => kind == KeyKind.action;

  /// The key's full name, for the screen where the user picks which ones to
  /// show.
  ///
  /// NOT TRANSLATED, deliberately. These are the proper names of physical keys
  /// — the same words printed on the keyboard the user is typing on — and
  /// "Page down" translated into three characters would be a worse label for a
  /// key than the one already on the key.
  String get description => switch (this) {
        SoftKey.ctrl => 'Control',
        SoftKey.alt => 'Alt',
        SoftKey.shift => 'Shift',
        SoftKey.esc => 'Escape',
        SoftKey.tab => 'Tab',
        SoftKey.enter => 'Enter',
        SoftKey.space => 'Space',
        SoftKey.backspace => 'Backspace',
        SoftKey.up => 'Up',
        SoftKey.down => 'Down',
        SoftKey.left => 'Left',
        SoftKey.right => 'Right',
        SoftKey.home => 'Home',
        SoftKey.end => 'End',
        SoftKey.pageUp => 'Page up',
        SoftKey.pageDown => 'Page down',
        SoftKey.delete => 'Delete',
        SoftKey.interrupt => 'Interrupt (SIGINT)',
        SoftKey.eof => 'End of input (EOF)',
        SoftKey.suspend => 'Suspend (SIGTSTP)',
        SoftKey.clear => 'Clear screen',
        SoftKey.reverseSearch => 'Reverse search',
        SoftKey.copy => 'Copy',
        SoftKey.paste => 'Paste',
      };

  /// The bytes this key sends with no modifier armed, or null for modifiers and
  /// actions, which produce bytes only in combination or not at all.
  String? get plain => switch (this) {
        SoftKey.esc => '\x1b',
        SoftKey.tab => '\t',
        // CR, not LF. A terminal's Enter sends carriage return; a bare line feed
        // is a different key that most shells will not treat as "run this".
        SoftKey.enter => '\r',
        SoftKey.space => ' ',
        SoftKey.backspace => '\x7f',
        SoftKey.up => '\x1b[A',
        SoftKey.down => '\x1b[B',
        SoftKey.right => '\x1b[C',
        SoftKey.left => '\x1b[D',
        SoftKey.home => '\x1b[H',
        SoftKey.end => '\x1b[F',
        SoftKey.pageUp => '\x1b[5~',
        SoftKey.pageDown => '\x1b[6~',
        SoftKey.delete => '\x1b[3~',
        SoftKey.interrupt => '\x03',
        SoftKey.eof => '\x04',
        SoftKey.suspend => '\x1a',
        SoftKey.clear => '\x0c',
        SoftKey.reverseSearch => '\x12',
        _ => null,
      };
}

enum KeyKind { modifier, literal, action }

/// The keys the bar shows unless the user changes it.
///
/// Order is deliberate and is the same argument the previous bar made: the keys
/// reached for under pressure first, the ones learned by feel last.
const List<SoftKey> defaultKeyBar = [
  SoftKey.esc,
  SoftKey.tab,
  SoftKey.enter,
  SoftKey.interrupt,
  SoftKey.ctrl,
  SoftKey.alt,
  SoftKey.shift,
  SoftKey.copy,
  SoftKey.paste,
  SoftKey.left,
  SoftKey.up,
  SoftKey.down,
  SoftKey.right,
];

/// Every key, in the order Settings lists them.
const List<SoftKey> keyBarCatalogue = SoftKey.values;

/// Whether the expanded key panel stays open after [key] was pressed.
///
/// A RULE, NOT A LAYOUT DECISION, which is why it lives here rather than in the
/// panel. Arming Ctrl and having the panel vanish would make `Ctrl+D` — the one
/// combination this whole design exists for — impossible to perform from the
/// panel, because the second key would have to be found on the soft keyboard
/// instead. Everything else HAS done something by being pressed, and a panel
/// that stays up after sending a key is a panel you have to dismiss twice.
bool keyPanelStaysOpen(SoftKey key) => key.isModifier;

/// What a tap produced.
typedef KeyOutcome = ({Set<TerminalModifier> armed, String? bytes});

/// The armed-modifier state machine.
///
/// Immutable so the page can hold one and rebuild from it, and so the behaviour
/// is asserted in tests rather than implied by a `bool` field somewhere in a
/// widget.
class KeyBarState {
  const KeyBarState({this.armed = const {}});

  final Set<TerminalModifier> armed;

  bool get isEmpty => armed.isEmpty;

  bool isArmed(TerminalModifier m) => armed.contains(m);

  /// Arms a modifier, or disarms it if it was already armed.
  ///
  /// Toggling rather than latching: a modifier you cannot turn off is how you
  /// send C-c three times and kill three things.
  KeyBarState toggle(TerminalModifier m) => KeyBarState(
        armed: armed.contains(m)
            ? (armed.toSet()..remove(m))
            : (armed.toSet()..add(m)),
      );

  /// Prepares a tap on [key].
  ///
  /// Returns the next state and the bytes to send. A modifier tap produces no
  /// bytes and leaves the set changed; anything else CONSUMES the armed
  /// modifiers, whether or not it could use them — an armed Ctrl that silently
  /// survived a keypress would fire on the key after that, which is worse than
  /// having to press it again.
  KeyOutcome tap(SoftKey key) {
    if (key.isModifier) {
      return (armed: toggle(_modifierFor(key)).armed, bytes: null);
    }
    if (key.isAction) return (armed: armed, bytes: null);
    return (armed: const {}, bytes: applyModifiers(key.plain ?? '', armed));
  }

  static TerminalModifier _modifierFor(SoftKey key) => switch (key) {
        SoftKey.ctrl => TerminalModifier.ctrl,
        SoftKey.alt => TerminalModifier.alt,
        SoftKey.shift => TerminalModifier.shift,
        _ => throw ArgumentError('$key is not a modifier'),
      };

  /// Applies armed modifiers to something typed rather than tapped.
  ///
  /// Used for the soft keyboard, and it is the reason [TerminalModifier] lives
  /// on the page rather than inside the bar: with `Ctrl` armed, typing `d` on
  /// the phone's own keyboard has to send `\x04`. Without this the sticky key
  /// would only combine with the dozen keys on the bar, and `Ctrl+D` — the one
  /// everybody actually wants — would be unreachable.
  KeyOutcome type(String text) {
    // A newline from the phone's own keyboard IS the Enter key.
    //
    // Not a detail: the LF byte works for a shell in canonical mode (ICRNL
    // turns it into a line) but not for a TUI in raw mode, where Enter is CR.
    // The difference is invisible until an agent's menu ignores your return key
    // — so the composer normalises instead of forwarding whatever the IME
    // happened to insert.
    final normalised = text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');

    if (armed.isEmpty || normalised.isEmpty) {
      return (armed: const {}, bytes: normalised);
    }

    // CHARACTER BY CHARACTER, and that is not a detail. A fast typist produces
    // two characters between two frames of the text field, and Ctrl applies to
    // each of them. Handing the whole string to [applyModifiers] would send it
    // to the navigation-key table instead — which matches nothing, so an armed
    // Ctrl would silently do nothing at all, on the one keystroke somebody
    // armed it for.
    final bytes = StringBuffer();
    for (final rune in normalised.runes) {
      bytes.write(applyModifiers(String.fromCharCode(rune), armed));
    }
    return (armed: const {}, bytes: bytes.toString());
  }
}

/// Turns a base sequence into the bytes a modified keypress produces.
///
/// Public and pure so the arithmetic is testable on its own; the table is the
/// whole point of this file.
String applyModifiers(String base, Set<TerminalModifier> armed) {
  if (armed.isEmpty || base.isEmpty) return base;
  var out = base;
  // Shift first, then Ctrl, then Alt: each step takes the previous one's output,
  // so `Ctrl+Shift+Tab` becomes the control form of the shifted Tab rather than
  // a shifted control form that no terminal has a sequence for.
  if (armed.contains(TerminalModifier.shift)) out = _shifted(out);
  if (armed.contains(TerminalModifier.ctrl)) out = _controlled(out);
  if (armed.contains(TerminalModifier.alt)) out = '\x1b$out';
  return out;
}

/// `Shift` on a key that has a defined shifted form.
///
/// Only two families do: Tab (`ESC [ Z`, the only way a terminal can say
/// "backwards") and the arrows and navigation keys, which swap their final byte
/// for a parameter. Everything else — every ordinary character — is left alone,
/// because Shift on a letter is not a terminal's business: the soft keyboard
/// already sent the shifted character.
String _shifted(String base) => switch (base) {
      '\t' => '\x1b[Z',
      // The `ESC [ 1 ; 2 x` form is what xterm-256color terminals send.
      '\x1b[A' => '\x1b[1;2A',
      '\x1b[B' => '\x1b[1;2B',
      '\x1b[C' => '\x1b[1;2C',
      '\x1b[D' => '\x1b[1;2D',
      '\x1b[H' => '\x1b[1;2H',
      '\x1b[F' => '\x1b[1;2F',
      '\x1b[5~' => '\x1b[5;2~',
      '\x1b[6~' => '\x1b[6;2~',
      '\x1b[3~' => '\x1b[3;2~',
      _ => base,
    };

/// `Ctrl` on a key that has a defined control code.
///
/// The rule for letters is `code & 0x1f`, which is where C0 control codes come
/// from in the first place. The punctuation entries are the exceptions that rule
/// does not cover, and each of them is a key somebody uses every day.
String _controlled(String base) {
  if (base.length == 1) {
    final code = base.codeUnitAt(0);
    // A-Z and a-z.
    if (code >= 0x41 && code <= 0x5a) return String.fromCharCode(code - 0x40);
    if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code - 0x60);
    return switch (base) {
      ' ' || '@' => '\x00',
      '[' => '\x1b',
      // Not a raw string: a raw string may not END with a backslash, and this
      // one is nothing but a backslash.
      // ignore: use_raw_strings
      '\\' => '\x1c',
      ']' => '\x1d',
      '^' => '\x1e',
      '_' => '\x1f',
      // Anything else has no control form; send it unchanged rather than
      // swallowing the keypress.
      _ => base,
    };
  }

  // `Ctrl` with a navigation key is a modifier PARAMETER, not a control code.
  return switch (base) {
    '\x1b[A' => '\x1b[1;5A',
    '\x1b[B' => '\x1b[1;5B',
    '\x1b[C' => '\x1b[1;5C',
    '\x1b[D' => '\x1b[1;5D',
    '\x1b[H' => '\x1b[1;5H',
    '\x1b[F' => '\x1b[1;5F',
    '\x1b[5~' => '\x1b[5;5~',
    '\x1b[6~' => '\x1b[6;5~',
    '\x1b[3~' => '\x1b[3;5~',
    '\x1b[Z' => '\x1b[1;5Z',
    _ => base,
  };
}

/// Turns clipboard text into what the pane should receive.
///
/// BRACKETED PASTE IS NOT A NICETY. A terminal that pastes a multi-line block
/// raw feeds it to the shell line by line, and every line runs the moment it
/// arrives — a paste of five commands is five commands executed, with no chance
/// to look at them. A program signals that it understands bracketed paste by
/// sending `ESC [ ? 2004 h`, and then a paste is wrapped in `ESC [ 200 ~` …
/// `ESC [ 201 ~` so it arrives as one insertion instead.
///
/// [bracketed] comes from the terminal model, which is the only thing that has
/// seen that mode-setting sequence.
///
/// Line endings become CR either way, because that is what a terminal's Enter
/// sends. Without the normalisation a pasted command runs under the shell and
/// then — for anything reading raw input, an editor or a REPL — leaves a stray
/// LF that looks like an extra keypress.
String pastePayload(String text, {required bool bracketed}) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (bracketed) return '\x1b[200~$lines\x1b[201~';
  return lines.replaceAll('\n', '\r');
}
