/// What one report from the phone's keyboard means for the terminal.
///
/// ## Why a sentinel, and not the text the user typed
///
/// A terminal wants KEYSTROKES. A phone keyboard produces EDITS TO A STRING,
/// and the obvious bridge — keep what was typed and diff it — has a hole that
/// is invisible until somebody tries to use it: once the field is empty, the
/// backspace key produces no edit at all, so there is nothing to send and the
/// terminal's own input line cannot be deleted. That is not a hypothetical: the
/// field was cleared after every keystroke, so backspace was dead for the whole
/// session, which is exactly the bug this file was written for.
///
/// The fix is to leave a character in the field that the user never sees and
/// never means: [kComposerSentinel]. Every report is then measured against it —
/// anything longer is typing, anything shorter is a backspace — and the field
/// is put back to the sentinel after each one, so the buffer never grows, never
/// accumulates autocorrect state, and never depends on what the terminal has
/// already echoed back. A backspace with nothing typed still has something to
/// delete, which is the whole point.
///
/// Two spaces rather than one, so that "one character was deleted" and "the
/// field was wiped" are different reports. A keyboard's own clear button is a
/// real thing; a backspace is the common case, and it must never be mistaken
/// for it.
///
/// PURE DART, and the reader takes strings rather than a `TextEditingValue` for
/// that reason: this is the layer everything else is checked against, and it
/// has to be exercisable without a widget tree. The widget that feeds it lives
/// in `lib/ui/pages/terminal/terminal_composer.dart`.
library;

/// What the field is left holding between keystrokes.
///
/// The caret sits after it, which is where the next typed character lands.
const String kComposerSentinel = '  ';

/// What one report from the IME means for the pane.
sealed class ComposerEdit {
  const ComposerEdit();
}

/// The user typed (or pasted, or dictated) text.
final class ComposerTyped extends ComposerEdit {
  const ComposerTyped(this.text);

  final String text;
}

/// The backspace key, [count] times.
///
/// A count rather than a flag because a keyboard may delete more than one
/// character in a single report, and the terminal has to be told once per
/// character — a shell deleting one character per keypress is what makes
/// backspace behave the way a person expects.
final class ComposerDeleted extends ComposerEdit {
  const ComposerDeleted(this.count);

  final int count;
}

/// The keyboard is mid-composition (pinyin, kana, a swipe being resolved).
///
/// NOTHING IS SENT while this is true, and that is a decision rather than an
/// omission: sending the letters of a composition would type `nihao` into a
/// shell before `你好` ever exists, and a language that composes would be
/// unusable. The edit is read once the composition commits, at which point the
/// committed text arrives as a single report.
final class ComposerComposing extends ComposerEdit {
  const ComposerComposing();
}

/// Nothing to do: the field is at rest, or was reset by the keyboard itself.
final class ComposerNothing extends ComposerEdit {
  const ComposerNothing();
}

/// How the sentinel buffer is read.
abstract final class ComposerBuffer {
  /// Reads one report from the keyboard.
  ///
  /// Only the LENGTH beyond the sentinel is examined, and that is deliberate:
  /// the app cannot know how far the user's IME has been rewound, and anything
  /// cleverer than a length comparison would be guessing. An edit that is
  /// neither an append nor a deletion — a keyboard replacing the whole field,
  /// which the input configuration is what prevents — reads as
  /// [ComposerNothing] and is silently resynced rather than sent as garbage.
  static ComposerEdit read({required String text, required bool composing}) {
    if (composing) return const ComposerComposing();

    final beyond = text.length - kComposerSentinel.length;
    if (beyond > 0) return ComposerTyped(text.substring(kComposerSentinel.length));
    if (beyond < 0) return ComposerDeleted(-beyond);
    return const ComposerNothing();
  }

  /// Whether the field has to be put back to the sentinel.
  ///
  /// Never while a composition is live: resetting the editing state mid-
  /// composition destroys the composing region, which is how a Chinese
  /// keyboard ends up with its candidate window stuck open over nothing.
  static bool needsReset({required String text, required bool composing}) =>
      !composing && text != kComposerSentinel;
}
