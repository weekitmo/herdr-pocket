import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/data/host_profile.dart';
import 'package:herdr_pocket/data/providers/connection.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:herdr_pocket/data/transport/herdr_transport.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/components/agent_visuals.dart';
import 'package:herdr_pocket/ui/components/connection_status_line.dart';
import 'package:herdr_pocket/ui/components/herdr_sheet.dart';
import 'package:herdr_pocket/ui/components/menu_popover.dart';
import 'package:herdr_pocket/ui/components/settings_list.dart';
import 'package:herdr_pocket/ui/components/top_bar.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/design/ui_ids.dart';
import 'package:herdr_pocket/ui/pages/pairing/pairing_page.dart';

/// Machines the user has told us about.
///
/// This screen is the entry point on a phone: without it the app has nothing to
/// connect to and the board can only ever say "offline". It is also where the
/// distinction the whole transport rests on becomes visible — a saved machine
/// keeps its credential in the keystore and its host key pinned, and either can
/// be revoked from here.
class HostsPage extends ConsumerWidget {
  const HostsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final hosts = ref.watch(hostListProvider);

    return CupertinoPageScaffold(
      backgroundColor: colors.ground,
      child: Stack(
        children: [
          CustomScrollView(
        slivers: [
          HerdrSliverTopBar(
            title: l10n.hostsTitle,
            leading: HerdrBackButton(label: l10n.navBack),
            // NO ACTION IN THE BAR. Adding a machine moved to a floating
            // button at the bottom right — see the `_AddButton` in the stack
            // below — because the top-right corner is the hardest place on a
            // phone for one hand to reach, and this is the action a user with
            // no machines has to find before the app does anything at all.
          ),
          if (hosts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _Empty(
                colors: colors,
                title: l10n.hostsNoHosts,
                body: l10n.hostsNoHostsBody,
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: SettingsGroup(
                rows: [
                  for (final host in hosts)
                    _HostRow(
                      key: ValueKey(host.id),
                      host: host,
                      onUse: () => _useHost(ref, host),
                      onActions: () => _hostActions(context, ref, host),
                    ),
                ],
              ),
            ),
            // Both gestures are invisible, so they are stated once here rather
            // than hinted at on every row. A row with no affordance and no
            // explanation is a row nobody edits.
            SliverToBoxAdapter(child: SettingsNote(text: l10n.hostsFooter)),
          ],
          // Room for the floating button, so the last row is never sitting
          // under it.
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 56 + Space.xl * 2,
            ),
          ),
        ],
          ),
          Positioned(
            right: Space.lg,
            // Above the system gesture area, which on a phone with a home
            // indicator is a strip that eats taps.
            bottom: MediaQuery.paddingOf(context).bottom + Space.lg,
            child: HerdrFloatingButton(
              identifier: UiId.addMachine,
              label: l10n.hostAdd,
              onPressed: () => unawaited(_addMachine(context, ref)),
            ),
          ),
        ],
      ),
    );
  }

  /// Points the app at this machine and reconnects.
  ///
  /// Explicitly reconnects rather than relying on the selection change alone:
  /// tapping the machine that is ALREADY selected has to mean "try again", and
  /// without this it would mean nothing at all.
  void _useHost(WidgetRef ref, HostProfile host) {
    unawaited(ref.read(selectedHostIdProvider.notifier).select(host.id));
    ref.read(connectionProvider.notifier).reconnect();
  }

  /// Offers the two ways to add a machine.
  ///
  /// `showCupertinoModalPopup` rather than a routes push: this is a question
  /// with two answers and a cancel, which is what an action sheet is, and the
  /// two answers are the whole sheet.
  /// Opens the add-machine sheet.
  ///
  /// ONE SHEET, TWO MODES. The choice between scanning and typing depends on
  /// where the user is standing relative to the machine — at its screen,
  /// scanning is two taps; anywhere else the pairing string has to be typed or
  /// pasted — so it belongs inside the sheet as a switch, not as a second sheet
  /// stacked on the first. Two sheets in a row means two transitions to sit
  /// through and two places to look for the way back.
  Future<void> _addMachine(BuildContext context, WidgetRef ref) =>
      _openEditor(context, ref);

  /// Opens the editor as a sheet, for a new machine or an existing one.
  ///
  /// A SHEET IN BOTH CASES, because it is the same form and the user reached it
  /// from the same list. Editing used to be a pushed page and adding was going
  /// to be one too; two presentations of one form is how the two copies drift.
  ///
  /// The header's save button lives HERE rather than inside the editor because
  /// the header belongs to the sheet — and a `GlobalKey` is what lets the
  /// parent's chrome invoke the child's action. It is the standard shape for
  /// this and it stays typed: the key cannot reach anything but `save()`.
  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref, {
    HostProfile? existing,
  }) async {
    final l10n = AppLocalizations.of(context);
    final editorKey = GlobalKey<HostEditorPageState>();

    await showHerdrSheet<void>(
      context: context,
      title: existing == null ? l10n.hostAdd : l10n.hostEdit,
      // 完成 in the top right, which is where the checkmark used to be and
      // what the reference design shows. NOT 保存: the same button is on screen
      // in pairing mode, where there is nothing to save — it is the sheet's
      // "I am finished here", and the body decides what that means.
      action: HerdrSheetAction(
        label: l10n.actionDone,
        onPressed: () => editorKey.currentState?.done(),
      ),
      builder: (_, _) => HostEditorPage(key: editorKey, existing: existing),
    );
  }

  /// Edit and delete, behind a long press.
  ///
  /// WHY NOT TWO ICONS ON THE ROW, which is what this replaced: they sat inside
  /// the row's own tap target, at 20 points, with DELETE one of them. A thumb
  /// reaching for "connect" was a thumb's width from destroying a saved machine
  /// and its keystore entry, and there was no confirmation between the two. The
  /// sheet puts a deliberate gesture in front of both, and it is the same
  /// gesture the pane rows on the workspace screen already use.
  Future<void> _hostActions(
    BuildContext context,
    WidgetRef ref,
    HostProfile host,
  ) async {
    final l10n = AppLocalizations.of(context);
    final action = await showCupertinoModalPopup<_HostAction>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(host.label.isEmpty ? host.displayTarget : host.label),
        message: Text(
          host.isLocal
              ? host.displayTarget
              : '${host.username}@${host.host}:${host.port}',
          style: const TextStyle(
            fontFamily: HerdrFonts.mono,
            fontSize: TextSize.meta,
          ),
        ),
        actions: [
          if (!host.isLocal)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(_HostAction.edit),
              child: actionSheetLabel(l10n.hostEdit),
            ),
          if (!host.isLocal)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () =>
                  Navigator.of(sheetContext).pop(_HostAction.delete),
              child: actionSheetLabel(l10n.hostDelete),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: actionSheetLabel(l10n.actionCancel),
        ),
      ),
    );

    if (!context.mounted || action == null) return;
    switch (action) {
      case _HostAction.edit:
        await _openEditor(context, ref, existing: host);
      case _HostAction.delete:
        await _confirmDelete(context, ref, host);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    HostProfile host,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.hostDelete),
        content: Text(host.label),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: actionSheetLabel(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: actionSheetLabel(l10n.hostDelete),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(hostListProvider.notifier).remove(host.id);
    }
  }
}

enum _HostAction { edit, delete }

/// One saved machine, and how it is doing.
///
/// The card carries its own CONNECTION STATE rather than leaving it to the
/// board. Selecting a machine and having nothing visibly happen is the worst
/// possible outcome here: the user cannot tell whether the tap registered, the
/// credential is wrong, or the network is down. Every one of those has a
/// different fix, so every one of them gets a different word.
class _HostRow extends ConsumerWidget {
  const _HostRow({
    required this.host,
    required this.onUse,
    required this.onActions,
    super.key,
  });

  final HostProfile host;
  final VoidCallback onUse;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final isCurrent = ref.watch(currentHostProvider)?.id == host.id;
    final connection = ref.watch(connectionProvider);
    final status = connection.value;

    // The row carries its own CONNECTION STATE rather than leaving it to the
    // board. Selecting a machine and having nothing visibly happen is the worst
    // possible outcome here: the user cannot tell whether the tap registered,
    // the credential is wrong, or the network is down. Every one of those has a
    // different fix, so every one of them gets a different word.
    //
    // AND IT HAS TO MOVE. The row this replaced printed one word — the short
    // reason — the instant a dial failed, so the whole experience of entering a
    // machine on a bad network was: save, land here, read "unreachable". It now
    // narrates the same three-try sequence the dialler actually runs, which is
    // the difference between "this failed" and "this is being worked on".
    final dialling = isCurrent && (connection.isLoading || status is Connecting);
    final (String label, Color tint) = switch ((isCurrent, status)) {
      (false, _) => (l10n.hostConnect, colors.textFaint),
      (true, _) when dialling => (
        connectionStatusLabel(l10n, status, loading: true),
        colors.textFaint,
      ),
      (true, Online(:final hello)) => (hello.version, colors.statusTextDone),
      (true, ConnectionFailed(:final error)) => (
        _HostRow._shortReason(l10n, error),
        colors.statusTextDied,
      ),
      _ => (l10n.connectionStateOffline, colors.textFaint),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        onUse();
      },
      onLongPress: () {
        unawaited(HapticFeedback.mediumImpact());
        onActions();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.lg,
          Space.md,
          Space.lg,
          Space.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: AgentStatusDot(
                color: isCurrent ? tint : colors.textFaint,
                isActive: isCurrent && status is Connecting,
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host.label.isEmpty ? host.displayTarget : host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: TextSize.strong,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    host.isLocal
                        ? host.displayTarget
                        : '${host.username}@${host.host}:${host.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textDim,
                      fontSize: TextSize.meta,
                      fontFamily: HerdrFonts.mono,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tint,
                      fontSize: TextSize.note,
                      fontFamily: HerdrFonts.mono,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            // Only the machine in use gets a badge. A "not current" badge on
            // every other row would be four fifths noise.
            if (isCurrent) ...[
              const SizedBox(width: Space.sm),
              Text(
                l10n.hostCurrent,
                style: TextStyle(
                  color: colors.accent,
                  fontSize: TextSize.note,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A few words for the status line.
  ///
  /// The full message belongs on the board, where there is room to explain it.
  /// Here it only has to be enough to tell one failure from another — and, for
  /// the password and host-key cases, to name the thing the user has to go and
  /// fix, since a retry will not.
  static String _shortReason(AppLocalizations l10n, Object error) {
    if (error is! HerdrTransportException) return l10n.connectionFailed;
    // Line-exact, because the sentinel also appears inside the commands this
    // app builds — see [reportsHerdrMissing].
    if (reportsHerdrMissing(error.message)) {
      return l10n.errorHerdrNotFound;
    }
    return switch (error.failure) {
      TransportFailure.authenticationFailed => l10n.connectionStateAuthFailed,
      TransportFailure.hostKeyUnknown ||
      TransportFailure.hostKeyChanged =>
        l10n.connectionStateHostKeyChanged,
      TransportFailure.forwardingRefused => l10n.connectionFailed,
      TransportFailure.connectFailed => l10n.connectionFailed,
      _ => l10n.connectionFailed,
    };
  }
}

/// Add or edit one machine.
class HostEditorPage extends ConsumerStatefulWidget {
  const HostEditorPage({this.existing, super.key});

  final HostProfile? existing;

  @override
  HostEditorPageState createState() => HostEditorPageState();
}

class HostEditorPageState extends ConsumerState<HostEditorPage> {
  /// Which mode the sheet is in. Pairing is the default, because running
  /// `hdp pair` removes the address, the port, the username and the key — and a
  /// form that asks for four things when a QR code could have answered all of
  /// them should not be the one that opens first.
  _AddMode _mode = _AddMode.pair;

  late final TextEditingController _label = TextEditingController(
    text: widget.existing?.label ?? '',
  );
  late final TextEditingController _host = TextEditingController(
    text: widget.existing?.host ?? '',
  );
  late final TextEditingController _port = TextEditingController(
    text: '${widget.existing?.port ?? 22}',
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  final _password = TextEditingController();
  final _privateKey = TextEditingController();

  /// Which credential to use. Kept separate from the text fields so switching
  /// the method does not silently discard what the user pasted.
  bool _useKey = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // An existing host may already have a secret; we cannot read it back into a
    // field (reading a secret back into the UI is how it ends up in a
    // screenshot), so the fields start empty and an empty field means "keep
    // what is stored".
    unawaited(_loadExistingSecretShape());
  }

  Future<void> _loadExistingSecretShape() async {
    final existing = widget.existing;
    if (existing == null) return;
    final secrets = await ref.read(hostSecretsStoreProvider).read(existing.id);
    if (!mounted || secrets == null) return;
    setState(() => _useKey = secrets.privateKeyPem != null);
  }

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _privateKey.dispose();
    super.dispose();
  }

  /// What the sheet's 完成 button means in the mode the sheet is in.
  ///
  /// In the manual form it commits; in pairing mode there is nothing to commit
  /// — the pairing button in the body is the action — so it just closes. One
  /// label over two behaviours is not a fudge here: both are the user saying
  /// they are finished with the sheet, and which one runs is decided by the
  /// switch the user can see at the top.
  Future<void> done() async {
    if (widget.existing == null && _mode == _AddMode.pair) {
      Navigator.of(context).maybePop();
      return;
    }
    await save();
  }

  /// Commits the form.
  Future<void> save() async {
    final l10n = AppLocalizations.of(context);
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());

    if (host.isEmpty || user.isEmpty) {
      setState(() => _error = l10n.hostMissing);
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = l10n.hostInvalidPort);
      return;
    }

    final profile = HostProfile(
      id:
          widget.existing?.id ??
          // Ids are only ever compared, never parsed, so a timestamp is enough
          // and avoids a uuid dependency for one field.
          'host-${DateTime.now().microsecondsSinceEpoch}',
      label: _label.text.trim().isEmpty ? host : _label.text.trim(),
      username: user,
      host: host,
      port: port,
    );

    final secrets = _useKey
        ? SshSecrets(
            privateKeyPem: _privateKey.text.trim().isEmpty
                ? null
                : _privateKey.text,
          )
        : SshSecrets(password: _password.text.isEmpty ? null : _password.text);

    // THE CREDENTIAL IS WRITTEN FIRST, AND THE ORDER IS LOAD-BEARING.
    //
    // Adding the profile mutates the host list, and the connection layer
    // watches that list — so it reacts immediately. If the secret is not on
    // disk yet, that reaction is an authentication failure, and nothing
    // afterwards retries: selecting a host that the connection already had
    // selected changes nothing, so no rebuild is triggered. The user sees a
    // save that appears to do nothing at all.
    //
    // Only overwrite stored secrets when the user actually typed something;
    // otherwise editing a label would wipe the key.
    if (secrets.privateKeyPem != null || secrets.password != null) {
      await ref.read(hostSecretsStoreProvider).write(profile.id, secrets);
    }

    final notifier = ref.read(hostListProvider.notifier);
    if (widget.existing == null) {
      await notifier.add(profile);
    } else {
      await notifier.update(profile);
    }
    await ref.read(selectedHostIdProvider.notifier).select(profile.id);

    // Selection alone is not enough. Saving an EDIT to the already-selected
    // host produces no observable change for the connection layer, so it would
    // never reconnect with the new address or the new key.
    ref.read(connectionProvider.notifier).reconnect();

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final l10n = AppLocalizations.of(context);

    // A BOTTOM SHEET, not a pushed page, and the chrome came with it: the
    // panel, the dim, the slide and the header all belong to `HerdrSheet`, so
    // this widget is only the inside. It used to draw a top bar with a
    // back chevron and a tick, which is three pieces of chrome for a form with
    // four short fields — and the tick in particular had to be guessed at,
    // where the word 保存 does not.
    final modes = widget.existing == null
        ? _ModeSwitch(
            colors: colors,
            l10n: l10n,
            mode: _mode,
            onChanged: (m) => setState(() => _mode = m),
          )
        : null;

    return Column(
      children: [
        ?modes,
        Expanded(
          child: _mode == _AddMode.pair && widget.existing == null
              ? const PairingView(sheetMode: true)
              : _form(context, colors, l10n),
        ),
      ],
    );
  }

  Widget _form(BuildContext context, HerdrColors colors, AppLocalizations l10n) {
    return Builder(
      builder: (context) {
        return ScrollConfiguration(
          behavior: settingsScrollBehavior(context),
          child: ListView(
            // Sized to its content so the sheet can hug it. Cheap here — the
            // list is a fixed handful of cards — and wrong for anything long,
            // which is why it is set at the call site rather than in the sheet.
            shrinkWrap: true,
            // The sheet supplies the surrounding padding, so this is only the
            // room the content needs below the last card.
            padding: const EdgeInsets.only(bottom: Space.xxl),
            children: [
              // One card of rows, label left and field right — the shape every
              // phone user already knows from the Wi-Fi screen. The first version
              // stacked a small label above a full-width field, four times, which
              // is 40% of the screen for four short strings.
              SettingsGroup(
                rows: [
                  _FieldRow(
                    label: l10n.hostLabel,
                    controller: _label,
                    hint: l10n.hostLabelHint,
                  ),
                  _FieldRow(
                    label: l10n.hostAddress,
                    controller: _host,
                    hint: l10n.hostHostHint,
                  ),
                  _FieldRow(
                    label: l10n.hostPort,
                    controller: _port,
                    keyboardType: TextInputType.number,
                  ),
                  _FieldRow(
                    label: l10n.hostUsername,
                    controller: _user,
                    hint: l10n.hostUsernameHint,
                  ),
                ],
              ),
              SettingsGroup(
                rows: [
                  _MethodPicker(
                    useKey: _useKey,
                    colors: colors,
                    l10n: l10n,
                    onChanged: (v) => setState(() => _useKey = v),
                  ),
                ],
              ),
              // The credential keeps the label ABOVE the field, because a private
              // key is five lines of PEM and does not fit beside anything. It is
              // the one row here that is genuinely a block, not a value.
              SettingsGroup(
                rows: [
                  if (_useKey)
                    _KeyArea(
                      label: l10n.hostSshKey,
                      controller: _privateKey,
                      hint: l10n.hostSshKeyHint,
                    )
                  else
                    _FieldRow(
                      label: l10n.hostAuthPassword,
                      controller: _password,
                      hint: l10n.hostPasswordHint,
                      obscure: true,
                    ),
                ],
              ),
              SettingsNote(text: l10n.hostSecretNote),
              if (_error != null) SettingsNote(text: _error!, isError: true),

              // No second save button down here. There was one, and on the
              // device the sheet then had the SAME action in two places — a
              // rounded 保存 in the header and a full-width one at the bottom —
              // which reads as two different things that happen to share a
              // word. The header one is the one that survived, because it is
              // the position the checkmark used to occupy.
            ],
          ),
        );
      },
    );
  }
}

class _MethodPicker extends StatelessWidget {
  const _MethodPicker({
    required this.useKey,
    required this.colors,
    required this.l10n,
    required this.onChanged,
  });

  final bool useKey;
  final HerdrColors colors;
  final AppLocalizations l10n;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Labelled, and stacked under the label. A bare full-width segmented
    // control is not a settings row — it is a control that swallowed its own
    // row, and it left the card looking like a coloured box rather than a list
    // item.
    return SettingsRow(
      label: l10n.hostAuthMethod,
      below: CupertinoSlidingSegmentedControl<bool>(
        groupValue: useKey,
        backgroundColor: colors.surfaceRaised,
        thumbColor: colors.surface,
        onValueChanged: (v) {
          unawaited(HapticFeedback.selectionClick());
          onChanged(v ?? true);
        },
        children: {
          true: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 6,
              horizontal: Space.sm,
            ),
            child: Text(
              l10n.hostAuthKey,
              style: TextStyle(color: colors.text, fontSize: TextSize.note),
            ),
          ),
          false: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 6,
              horizontal: Space.sm,
            ),
            child: Text(
              l10n.hostAuthPassword,
              style: TextStyle(color: colors.text, fontSize: TextSize.note),
            ),
          ),
        },
      ),
    );
  }
}

/// A short value on the same line as its label.
///
/// Borderless, because the card is already the boundary. A bordered field inside
/// a bordered card is a box in a box, and four of them is a form that looks like
/// a spreadsheet.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.keyboardType,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return SettingsRow(
      label: label,
      labelFontSize: 15,
      labelColor: colors.textDim,
      expandTrailing: true,
      trailing: CupertinoTextField(
        controller: controller,
        placeholder: hint,
        obscureText: obscure,
        keyboardType: keyboardType,
        textAlign: TextAlign.right,
        // See the note on `_KeyArea`: every field here is a credential or an
        // address, and none of them wants the keyboard's opinion.
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        style: TextStyle(color: colors.text, fontSize: TextSize.strong),
        placeholderStyle: TextStyle(
          color: colors.textFaint,
          fontSize: TextSize.strong,
        ),
        padding: EdgeInsets.zero,
        decoration: null,
      ),
    );
  }
}

/// The private key: a label, then the whole width for five lines of PEM.
class _KeyArea extends StatelessWidget {
  const _KeyArea({
    required this.label,
    required this.controller,
    required this.hint,
  });

  final String label;
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return SettingsRow(
      label: label,
      below: CupertinoTextField(
        controller: controller,
        placeholder: hint,
        maxLines: 5,
        // EVERY field here is a credential or an address, and none of them
        // wants the keyboard's opinion. `autocorrect` and `enableSuggestions`
        // cover spelling; SMART DASHES AND QUOTES are the ones that bite a
        // private key, because they rewrite the PUNCTUATION — `-----BEGIN`
        // becomes an em dash and the PEM header stops being a PEM header. The
        // failure looks like a rejected password, which sends the user hunting
        // for a problem that is in their keyboard.
        //
        // Found the hard way: entering a key through the emulator produced a
        // key whose fingerprint did not match the file, while every base64
        // character had come through byte for byte.
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        style: TextStyle(
          color: colors.text,
          fontSize: TextSize.note,
          fontFamily: HerdrFonts.mono,
          height: 1.25,
        ),
        placeholderStyle: TextStyle(
          color: colors.textFaint,
          fontSize: TextSize.note,
        ),
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: colors.ground,
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(color: colors.hairlineQuiet),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.colors, required this.title, required this.body});

  final HerdrColors colors;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(color: colors.hairline, width: 1.5),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(height: Space.lg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.text,
              fontSize: TextSize.title,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Space.sm),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textDim,
              fontSize: TextSize.strong,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Which way the user is adding a machine.
///
/// One sheet with a switch, rather than two sheets or an action sheet in front
/// of a form: the choice depends on where the user is standing relative to the
/// machine, it is cheap to change once made, and stacking a second panel on the
/// first costs a transition and hides the way back.
enum _AddMode { pair, manual }

/// The switch at the top of the add-machine sheet.
///
/// A segmented control and not two buttons: the two options are exclusive, they
/// are the same kind of thing, and picking one is not an action — it is a
/// choice about which form to fill in. It is also the shape the reference
/// design uses for the same question.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.colors,
    required this.l10n,
    required this.mode,
    required this.onChanged,
  });

  final HerdrColors colors;
  final AppLocalizations l10n;
  final _AddMode mode;
  final ValueChanged<_AddMode> onChanged;

  /// One segment's label, at the same size on both sides.
  ///
  /// The horizontal padding is what stops the thumb snapping tight around the
  /// shorter word and jumping width when the selection changes.
  static Widget _segment(String label, HerdrColors colors) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Space.sm),
        child: Text(
          label,
          style: TextStyle(color: colors.text, fontSize: TextSize.note),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
      child: CupertinoSlidingSegmentedControl<_AddMode>(
        groupValue: mode,
        backgroundColor: colors.surfaceRaised,
        thumbColor: colors.surface,
        onValueChanged: (v) {
          if (v == null) return;
          unawaited(HapticFeedback.selectionClick());
          onChanged(v);
        },
        children: {
          // A map literal, so the entries are spelled out rather than built
          // with a `for`: a collection-`for` inside a MAP has to produce
          // key-value pairs, and one that produces bare widgets is a
          // compile error rather than a shorthand.
          _AddMode.pair: _segment(l10n.hostPair, colors),
          _AddMode.manual: _segment(l10n.hostAddManually, colors),
        },
      ),
    );
  }
}
