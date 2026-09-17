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

/// The `/` menu, opened by a button.
const Key composerCommandsKey = ValueKey('terminal.composer.commands');

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
///  * **The keyboard's own "helpful" rewrites are off.** Autocorrect, suggestions
///    and the dash/quote substitutions are all disabled, for the same reason the
///    credential fields disable them: what leaves here goes to a shell and to an
///    agent that will act on it, and a smart quote is not a typo — it is a
///    different command. (The punctuation pair matters most: `--flag` becoming an
///    en dash is a silent, plausible-looking corruption.)
///  * **Return inserts a newline.** There is a send button, and it is the only
///    thing that sends. A field whose return key submits is a field that cannot
///    hold a paragraph, which is the entire point of the thing.
///  * **It grows, up to a point.** Five lines is a message; more than that is a
///    document, and the terminal underneath has to stay usable.
///
/// The row under the field is the reference layout the user asked for: attach and
/// commands on the left, send on the right, and nothing else competing for the
/// thumb.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.controller,
    required this.focusNode,
    required this.l10n,
    required this.palette,
    required this.colors,
    required this.onSend,
    required this.onAttach,
    required this.onCommands,
    required this.commandsLabel,
    required this.onChanged,
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
  final VoidCallback onCommands;

  /// What the `…` button opens, in this pane's own words. The page knows
  /// whether it is opening an agent's skills or the workspace's files; this
  /// widget only knows the label.
  final String commandsLabel;

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
                _circle(
                  icon: CupertinoIcons.ellipsis,
                  label: commandsLabel,
                  onTap: onCommands,
                  buttonKey: composerCommandsKey,
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
        autocorrect: false,
        enableSuggestions: false,
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
    return CupertinoButton(
      key: buttonKey,
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Semantics(
        label: label,
        button: true,
        child: Container(
          width: _buttonSize,
          height: _buttonSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // As the chips: a step below the card it sits on.
            color: colors.surface,
            border: Border.all(color: colors.hairline),
          ),
          child: Icon(icon, size: 17, color: colors.textDim),
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
