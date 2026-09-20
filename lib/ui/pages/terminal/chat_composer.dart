import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';

/// The composer's text field, for tests and for the tooltip-free world of a
/// screen with three round buttons on it.
const Key composerFieldKey = ValueKey('terminal.composer.field');

/// The send button: the only thing that sends.
const Key composerSendKey = ValueKey('terminal.composer.send');

/// The attach button — this PHONE's files.
const Key composerAttachKey = ValueKey('terminal.composer.attach');

/// The `/` button — the pane's skills and MCP servers.
const Key composerSlashKey = ValueKey('terminal.composer.slash');

/// The `@` button — files and folders to mention.
const Key composerMentionKey = ValueKey('terminal.composer.mention');

/// What the chat window can say about this pane's `/` menu.
///
/// THREE STATES, AND THE THIRD ONE IS THE POINT. `absent` and `ready` are facts
/// about the pane; `pending` is a fact about the PHONE — the census that answers
/// "which pane runs an agent" is three socket requests, and on a slow link the
/// chat window is open long before they land. With a bool the only available
/// answer was "no button", so the control appeared out of nowhere a few seconds
/// after the window did, which reads as a glitch rather than as loading.
///
/// Drawn dimmed and inert instead: nothing is promised, nothing is hidden, and
/// when the answer arrives the button either lights up ([ready]) or leaves
/// ([absent] — a plain shell has no skills, and its `/` is a path separator).
enum SlashAvailability {
  /// A plain shell. The button is not drawn at all: there is no menu behind it,
  /// and a button that opens nothing is a worse lie than an absent one.
  absent,

  /// Nobody knows yet. Drawn, dimmed, not tappable.
  pending,

  /// An agent is running here.
  ready,
}

/// The chat window: type a whole message on the phone, send it in one go.
///
/// ## What it is FOR
///
/// The terminal below it sends one `terminal.input` per keystroke — correct for a
/// key you press and watch, wrong for a paragraph on a train, where every
/// character is a round trip and a dropped link leaves the far end holding half a
/// sentence. This holds the text locally and puts ONE write on the wire when the
/// user says so. The pane's own echo is the receipt.
///
/// ## What it is NOT
///
/// Not a replacement for the key bar, and not a second terminal view. It is a
/// text field with three buttons, and the reason it is worth a file of its own is
/// everything that had to be decided about the FIELD:
///
///  * **The keyboard's own REWRITES are off; its suggestions are not.** Autocorrect
///    and the dash/quote substitutions are disabled, for the same reason the
///    credential fields disable them: what leaves here goes to a shell and to an
///    agent that will act on it, and a smart quote is not a typo — it is a
///    different command. (The punctuation pair matters most: `--flag` becoming an
///    en dash is a silent, plausible-looking corruption.)
///    Suggestions are a different thing and are left alone — turning them off
///    makes Android hand the field a `VISIBLE_PASSWORD` input type, which some
///    Chinese keyboards answer with a secure keyboard that cannot type Chinese.
///    See [_entryField], where the engine's own bytecode is quoted.
///  * **Return inserts a newline.** There is a send button, and it is the only
///    thing that sends. A field whose return key submits is a field that cannot
///    hold a paragraph, which is the entire point of the thing.
///  * **It grows, up to a point.** Five lines is a message; more than that is a
///    document, and the terminal underneath has to stay usable.
///
/// The row under the field is the reference layout the user asked for: attach,
/// the two TRIGGERS, and send.
///
///   * **`/` and `@` are two buttons, never one.** The first version of this
///     row had a single `…` whose meaning depended on the pane: it opened the
///     skills menu for a pane running an agent and the file menu for a plain
///     shell. That is one button asking the USER to know what the pane is
///     running, and the two lists are different questions — a skill is a
///     command, a file is a reference. They are drawn as the two characters the
///     terminal actually understands (`/` and `@`), because that is what they
///     insert: the same rule the key strip uses when it draws `C-c` as a word
///     and Copy as an icon.
///   * **On a pane with no agent the `/` button is not drawn.** A shell has no
///     skills, and a `/` there is a path separator — a button that opened an
///     empty menu would be a worse lie than an absent one. `@` stays, because a
///     file reference is useful in a shell too.
///   * **And while nobody knows yet, it is drawn DIM.** The answer comes from a
///     three-request census of the machine, so there is a real window on a slow
///     link where the truth is "not yet" — see [SlashAvailability]. That window
///     used to be rendered as "no button", which then appeared by itself.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.controller,
    required this.focusNode,
    required this.l10n,
    required this.palette,
    required this.colors,
    required this.onSend,
    required this.onAttach,
    required this.onSlash,
    required this.onMention,
    required this.onChanged,
    this.slash = SlashAvailability.ready,
    this.canSend = true,
    this.uploading = false,
    this.attachments = const [],
    this.onRemoveAttachment,
    this.hint,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final AppLocalizations l10n;

  /// The terminal's own colours: this strip sits ON the terminal, which is a
  /// different kind of place from the rest of the app.
  final TerminalColors palette;
  final HerdrColors colors;

  final VoidCallback onSend;
  final VoidCallback onAttach;

  /// Types `/` and opens the skills-and-MCP menu for this pane.
  final VoidCallback onSlash;

  /// Types `@` and opens the files-and-folders menu for this pane.
  final VoidCallback onMention;

  /// Whether the pane has an agent at all, and whether that is known yet.
  ///
  /// See [SlashAvailability]: `absent` hides the button rather than disabling
  /// it (a shell cannot run a skill, so there is no menu behind it), while
  /// `pending` draws it inert so that its arrival is not a layout surprise.
  final SlashAvailability slash;

  /// Fires on every edit AND every caret move — the menu trigger lives on the
  /// caret, so a tap that moves it has to be heard too.
  final VoidCallback onChanged;

  /// False when there is nothing to send (or nowhere to send it).
  final bool canSend;

  /// True while an attachment is being picked or pushed up.
  final bool uploading;

  /// Files that will ride along with the message.
  final List<ComposerAttachment> attachments;

  final void Function(int index)? onRemoveAttachment;

  /// Why the composer cannot send, when it cannot. A disabled button with no
  /// explanation is the thing this line exists to prevent.
  final String? hint;

  static const double _buttonSize = 38;
  static const int _maxLines = 5;

  @override
  Widget build(BuildContext context) {
    // A FLOATING CARD, not a full-width strip. It keeps the margins the user
    // asked for, and it is the shape the reference composer has: the terminal
    // stays visible around it, so the chat window reads as something laid OVER
    // the machine rather than as another row of chrome welded to the edges.
    //
    // It still takes LAYOUT space rather than covering the terminal, and that is
    // deliberate: the whole reason Phase 22 exists is that hiding the bottom of
    // a pane hides the line an agent is waiting on. Margins give the floating
    // look without the cost of an overlay.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.sm,
        Space.md,
        Space.sm,
      ),
      // The ring is on the CARD, not on the field: inside a card this size a
      // second outline around the text is a box inside a box.
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            color: colors.surfaceRaised,
            borderRadius: BorderRadius.circular(Radii.uniform),
            border: Border.all(
              color: focusNode.hasFocus
                  ? colors.cardEdgeActive
                  : colors.hairline,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.sm,
            Space.sm,
            Space.sm,
          ),
          child: child,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hint != null) _hintLine(hint!),
            if (attachments.isNotEmpty) _attachments(),
            _field(),
            const SizedBox(height: Space.xs),
            Row(
              children: [
                if (uploading)
                  _spinner()
                else
                  _circle(
                    icon: CupertinoIcons.plus,
                    label: l10n.composerAttach,
                    onTap: onAttach,
                    buttonKey: composerAttachKey,
                  ),
                const SizedBox(width: Space.sm),
                if (slash != SlashAvailability.absent) ...[
                  _glyph(
                    glyph: '/',
                    label: l10n.composerCommands,
                    // Inert while the pane is still being read: the trigger
                    // character is a path separator in a shell, and a menu that
                    // opened over `/usr/local` because we guessed would be the
                    // bug this button's three states exist to avoid.
                    onTap: slash == SlashAvailability.ready ? onSlash : null,
                    buttonKey: composerSlashKey,
                  ),
                  const SizedBox(width: Space.sm),
                ],
                _glyph(
                  glyph: '@',
                  label: l10n.composerMention,
                  onTap: onMention,
                  buttonKey: composerMentionKey,
                ),
                const Spacer(),
                _sendButton(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// One pill per attached file.
  ///
  /// The NAME, not the path: what the user picked was a photo called
  /// `IMG_0421.HEIC`, and the absolute path it now lives at on the host is an
  /// implementation detail of the upload — one they can still see in full by
  /// putting the message in a browser, but not one worth a line of the composer.
  Widget _attachments() {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.xs,
        children: [
          for (var i = 0; i < attachments.length; i++)
            _chip(attachments[i], i),
        ],
      ),
    );
  }

  Widget _chip(ComposerAttachment attachment, int index) {
    return Container(
      padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
      decoration: BoxDecoration(
        // One step BELOW the card, because the card is now the raised surface:
        // a chip in the card's own colour is a chip that is not there.
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.uniform),
        border: Border.all(color: colors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            attachment.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textDim, fontSize: TextSize.meta),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            onPressed: onRemoveAttachment == null
                ? null
                : () => onRemoveAttachment!(index),
            child: Semantics(
              label: l10n.composerRemoveAttachment(attachment.name),
              button: true,
              child: Padding(
                padding: const EdgeInsets.all(Space.xs),
                child: Icon(
                  CupertinoIcons.xmark,
                  size: 13,
                  color: colors.textFaint,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _spinner() => SizedBox(
    width: _buttonSize,
    height: _buttonSize,
    child: Center(
      child: CupertinoActivityIndicator(radius: 9, color: colors.textDim),
    ),
  );

  Widget _hintLine(String text) => Padding(
    padding: const EdgeInsets.only(
      left: Space.sm,
      right: Space.sm,
      bottom: Space.sm,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: colors.waiting,
          fontSize: TextSize.meta,
          height: 1.3,
        ),
      ),
    ),
  );

  /// The text itself, with no box of its own.
  ///
  /// The CARD is the field. A second rounded rectangle inside a card this size
  /// is a box inside a box, and the reference composer — the one this shape was
  /// asked for — is exactly that: one gray panel whose top two thirds are text.
  Widget _field() => _entryField();

  Widget _entryField() {
    return CupertinoTextField(
        key: composerFieldKey,
        controller: controller,
        focusNode: focusNode,
        minLines: 1,
        maxLines: _maxLines,
        // Return is a newline, not a send: see the class comment.
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        // The keyboard's own REWRITES are off; its SUGGESTIONS are not.
        //
        // The difference is not a preference, it is the difference between a
        // field that takes Chinese and one that does not. On Android the engine
        // implements `enableSuggestions: false` by ORing
        // `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` (144) into the editor's input
        // type — read out of `TextInputPlugin.inputTypeFromTextInputType` in
        // this machine's own `flutter.jar` — and a field that looks like a
        // password box gets the password treatment: MIUI answers it with its
        // secure keyboard, which cannot produce Chinese at all. The user hit
        // exactly that, on this field.
        //
        // What actually had to be disabled stays disabled: autocorrect (which
        // rewrites words in place), and the punctuation substitutions (which
        // turn `--flag` into an en dash — a silent corruption of a command).
        // A suggestion the user taps is text they meant to type, which is also
        // why the terminal's own composer keeps them on.
        autocorrect: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        onChanged: (_) => onChanged(),
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        placeholder: l10n.composerPlaceholder,
        // A CupertinoTextField hands its style straight to `EditableText` and
        // never merges the ambient text style, so the fallback face for Han has
        // to be written out here — without it, Chinese prose in this field would
        // fall back to the platform's proportional font and the composer would be
        // the one screen in the app that is a different typeface.
        style: TextStyle(
          color: colors.text,
          fontSize: TextSize.body,
          fontFamily: HerdrFonts.mono,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
        placeholderStyle: TextStyle(
          color: colors.textFaint,
          fontSize: TextSize.body,
          fontFamily: HerdrFonts.mono,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
        decoration: null,
    );
  }

  Widget _sendButton() {
    final enabled = canSend;
    return CupertinoButton(
      key: composerSendKey,
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: enabled ? 0.7 : 1,
      onPressed: enabled ? onSend : null,
      child: Semantics(
        label: l10n.composerSend,
        button: true,
        enabled: enabled,
        child: Container(
          width: _buttonSize,
          height: _buttonSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: enabled ? colors.accent : colors.surface,
            border: Border.all(color: enabled ? colors.accent : colors.hairline),
          ),
          child: Icon(
            CupertinoIcons.arrow_up,
            size: 18,
            color: enabled ? colors.ground : colors.textFaint,
          ),
        ),
      ),
    );
  }

  Widget _circle({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Key? buttonKey,
  }) {
    return _button(
      buttonKey: buttonKey,
      label: label,
      onTap: onTap,
      child: Icon(icon, size: 17, color: colors.textDim),
    );
  }

  /// A button whose face is the character it inserts.
  ///
  /// The monospace face is the point: `/` and `@` are shown as the terminal
  /// shows them, and the two buttons read as a pair because they are drawn in
  /// the same voice.
  ///
  /// A NULL [onTap] MEANS "NOT YET", not "never" — the glyph stays in place,
  /// drawn in the faintest ink, so that the answer arriving changes its colour
  /// rather than its existence.
  Widget _glyph({
    required String glyph,
    required String label,
    required VoidCallback? onTap,
    Key? buttonKey,
  }) {
    final enabled = onTap != null;
    return _button(
      buttonKey: buttonKey,
      label: label,
      onTap: onTap,
      child: Text(
        glyph,
        style: TextStyle(
          color: enabled ? colors.textDim : colors.textFaint,
          fontSize: 19,
          height: 1,
          fontFamily: HerdrFonts.mono,
          fontFamilyFallback: HerdrFonts.monoFallback,
        ),
      ),
    );
  }

  Widget _button({
    required Key? buttonKey,
    required String label,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return CupertinoButton(
      key: buttonKey,
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Semantics(
        label: label,
        button: true,
        enabled: onTap != null,
        child: Container(
          width: _buttonSize,
          height: _buttonSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // As the chips: a step below the card it sits on.
            color: colors.surface,
            border: Border.all(color: colors.hairline),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

/// One attached file, as the composer shows it.
///
/// A type of this widget's own rather than the uploader's, so the UI layer does
/// not have to know what an `UploadedAttachment` is: all this needs is something
/// to display and something to remove.
class ComposerAttachment {
  const ComposerAttachment({required this.name, required this.path});

  final String name;
  final String path;
}
