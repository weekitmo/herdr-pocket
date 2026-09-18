// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Herdr Pocket';

  @override
  String get boardTitle => 'Agents';

  @override
  String boardNeedsYouCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count awaiting approval',
      one: '$count awaiting approval',
      zero: 'Nothing to approve',
    );
    return '$_temp0';
  }

  @override
  String get boardEmptyTitle => 'No agents yet';

  @override
  String get boardEmptyBody =>
      'Start an agent in herdr on your machine and it will appear here.';

  @override
  String get groupNeedsYou => 'Approvals';

  @override
  String get groupStopped => 'Stopped';

  @override
  String get groupUnrecognised => 'Other';

  @override
  String get groupWorking => 'Working';

  @override
  String get groupIdle => 'Idle';

  @override
  String get groupUnrecognisedHint =>
      'This build cannot read this agent\'s state. Update the app, or check the daemon.';

  @override
  String get groupArchived => 'Archived';

  @override
  String get statusIdle => 'Idle';

  @override
  String get statusWorking => 'Working';

  @override
  String get statusBlocked => 'Awaiting approval';

  @override
  String get statusDone => 'Done';

  @override
  String get statusUnknown => 'Unknown';

  @override
  String get terminalTitle => 'Terminal';

  @override
  String get terminalReadOnly => 'Read only';

  @override
  String get terminalReadOnlyHint =>
      'Another client is controlling this terminal.';

  @override
  String get terminalConnecting => 'Connecting…';

  @override
  String get terminalDisconnected => 'Disconnected';

  @override
  String get terminalExited => 'Process exited';

  @override
  String get actionPrompt => 'Reply';

  @override
  String get actionSend => 'Send';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionRetry => 'Retry';

  @override
  String get actionReconnect => 'Reconnect';

  @override
  String get actionConnect => 'Connect';

  @override
  String get actionDisconnect => 'Disconnect';

  @override
  String get actionApprove => 'Approve';

  @override
  String get hostsTitle => 'Machines';

  @override
  String get hostAdd => 'Add machine';

  @override
  String get hostEdit => 'Edit machine';

  @override
  String get hostLabel => 'Label';

  @override
  String get hostAddress => 'Host';

  @override
  String get hostPort => 'Port';

  @override
  String get hostUsername => 'Username';

  @override
  String get hostAuthMethod => 'Authentication';

  @override
  String get hostAuthPassword => 'Password';

  @override
  String get hostAuthKey => 'Private key';

  @override
  String get hostAuthAgent => 'SSH agent';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsGlass => 'Liquid Glass';

  @override
  String get settingsSafety => 'Safety margin';

  @override
  String get safetyDefault => 'Default';

  @override
  String get safetyOn => 'Always on';

  @override
  String get safetyOff => 'Always off';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageSystem => 'System';

  @override
  String get settingsTextSize => 'Text size';

  @override
  String get settingsTerminalFontSize => 'Terminal font size';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsDiagnostics => 'Diagnostics';

  @override
  String get connectionStageConnecting => 'Connecting…';

  @override
  String get connectionStageVerifying => 'Verifying…';

  @override
  String get connectionStageLastAttempt => 'One last attempt…';

  @override
  String connectionRetryAttempt(int attempt, int max) {
    return 'Retrying $attempt/$max…';
  }

  @override
  String get connectionFailed => 'Connection failed';

  @override
  String get settingsKeepAlive => 'Keep alive in background';

  @override
  String get settingsKeepAliveNote =>
      'Stays connected when you leave the app. Shows a persistent notification.';

  @override
  String keepAliveNotificationBody(String host) {
    return 'Keeping the connection to $host open';
  }

  @override
  String get keepAliveNotificationBodyNoHost => 'Keeping the connection open';

  @override
  String get connectionLost => 'Connection lost';

  @override
  String get connectionLostRetrying => 'Connection lost — reconnecting…';

  @override
  String get connectionLostBody =>
      'It will keep trying on its own — or tap reconnect to try now.';

  @override
  String get connectionLostGaveUpBody =>
      'The connection to this machine dropped and would not come back.';

  @override
  String connectionFailedAfterRetries(int count) {
    return 'Tried $count times';
  }

  @override
  String get connectionStateOnline => 'Online';

  @override
  String get connectionStateOffline => 'Not connected';

  @override
  String get connectionStateAuthFailed => 'Authentication failed';

  @override
  String get connectionStateHostKeyChanged => 'Host key changed';

  @override
  String get connectionStateHostKeyChangedBody =>
      'The machine\'s key is different from the one you approved. This can mean it was rebuilt — or that someone is intercepting the connection.';

  @override
  String get errorForwardingRefused =>
      'The machine\'s SSH server refuses to forward to the herdr socket. Turn on AllowStreamLocalForwarding on it, then reconnect.';

  @override
  String get errorGeneric => 'Something went wrong';

  @override
  String get errorHerdrNotFound => 'herdr was not found on this machine';

  @override
  String get errorHerdrNotFoundBody =>
      'Install herdr on the machine and make sure it is on your PATH, then reconnect.';

  @override
  String get errorTerminalUnsupported =>
      'This herdr is too old for the live terminal';

  @override
  String get errorTerminalUnsupportedBody =>
      'herdr 0.9.0 or newer is required. Update herdr on the machine and reconnect.';

  @override
  String get hostKeyNewTitle => 'New machine';

  @override
  String get hostKeyNewBody =>
      'Herdr Pocket has not connected to this machine before. Check the fingerprint matches the one shown by your machine before continuing.';

  @override
  String get hostKeyChangedTitle => 'Host key changed';

  @override
  String get hostKeyChangedBody =>
      'The key this machine presented is different from the one you approved. This can mean the machine was rebuilt — or that someone is intercepting the connection. Only continue if you know why it changed.';

  @override
  String get hostKeyFingerprint => 'Fingerprint';

  @override
  String get hostKeyPreviously => 'Previously approved';

  @override
  String get hostKeyApproveAndRemember => 'Trust and remember';

  @override
  String get hostKeyApproveOnce => 'Trust once';

  @override
  String get hostKeyReject => 'Cancel';

  @override
  String get hostKeyShowDetails => 'Details';

  @override
  String get hostsNoHosts => 'No machines yet';

  @override
  String get hostsNoHostsBody =>
      'Add the machine running herdr and its agents will appear on the board.';

  @override
  String get hostSave => 'Save';

  @override
  String get hostDelete => 'Delete';

  @override
  String get hostSshKey => 'Private key';

  @override
  String get hostSshKeyHint => 'Paste an OpenSSH private key';

  @override
  String get hostPasswordHint => 'Password';

  @override
  String get hostUsernameHint => 'you';

  @override
  String get hostLabelHint => 'Work laptop';

  @override
  String get hostHostHint => '10.0.0.5 or my-host.local';

  @override
  String get hostConnect => 'Connect';

  @override
  String get hostConnectNow => 'Use this machine';

  @override
  String get hostMissing => 'Fill in host and username';

  @override
  String get hostInvalidPort => 'Port must be between 1 and 65535';

  @override
  String get hostSecretNote =>
      'Stored in this device\'s keystore, never in the host list.';

  @override
  String terminalScrolledBack(Object lines) {
    return '$lines lines back — tap to return to live';
  }

  @override
  String terminalScrolledBackOldest(int lines) {
    return 'at the oldest · $lines lines back — tap to return to live';
  }

  @override
  String get terminalSelectionHint => 'Select text';

  @override
  String get copyAction => 'Copy';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsNotificationsFooter =>
      'A notification when an agent starts waiting on you, while the app is running.';

  @override
  String get navBack => 'Back';

  @override
  String get navBoard => 'Board';

  @override
  String get navWorkspaces => 'Workspaces';

  @override
  String get navSettings => 'Settings';

  @override
  String get workspacesTitle => 'Workspaces';

  @override
  String get workspacesEmptyTitle => 'No workspaces';

  @override
  String get workspacesEmptyBody =>
      'Create a workspace in herdr on your machine and it will show up here.';

  @override
  String workspacesCounts(int tabs, int panes) {
    return '$tabs tabs · $panes panes';
  }

  @override
  String get workspacesTabsLabel => 'Tabs';

  @override
  String get workspacesPanesLabel => 'Panes';

  @override
  String get workspacesCurrent => 'Focused';

  @override
  String get workspacesFocusPane => 'Move focus here';

  @override
  String get workspacesFocusTab => 'Focus this tab';

  @override
  String get workspacesFocusWorkspace => 'Focus this workspace';

  @override
  String get workspacesFocusDone => 'Focus moved';

  @override
  String get workspacesFocusFailed => 'Could not move focus';

  @override
  String get workspacesNoPanes => 'This tab has no panes';

  @override
  String get paneSwitcherTitle => 'Switch pane';

  @override
  String get paneSwitcherCurrent => 'Current pane';

  @override
  String get paneSwitcherOtherTabs => 'Other tabs in this workspace';

  @override
  String get paneSwitcherRefresh => 'Refresh list';

  @override
  String get filesTitle => 'Files';

  @override
  String get filePreviewLoading => 'Reading…';

  @override
  String get filePreviewEmpty => 'Empty file';

  @override
  String get filePreviewBinary => 'Binary file — not shown as text.';

  @override
  String get filePreviewFailed => 'Could not read this file';

  @override
  String filePreviewTruncated(int kb) {
    return 'Showing the first $kb KB';
  }

  @override
  String filePreviewLines(int count) {
    return '$count lines';
  }

  @override
  String get gitTitle => 'Git changes';

  @override
  String get gitClean => 'Working tree clean';

  @override
  String get gitStaged => 'Staged';

  @override
  String get gitUnstaged => 'Unstaged';

  @override
  String get gitUntracked => 'Untracked';

  @override
  String get gitConflicted => 'Conflicted';

  @override
  String gitAheadBehind(int ahead, int behind) {
    return '$ahead ahead · $behind behind';
  }

  @override
  String get gitNotARepo => 'This directory is not inside a git repository';

  @override
  String gitChangesCount(int count) {
    return '$count changes';
  }

  @override
  String get gitLoading => 'Reading git status…';

  @override
  String get gitDiffEmpty => 'No diff to show';

  @override
  String get gitUnavailable => 'git is not installed on that machine';

  @override
  String get actionRefresh => 'Refresh';

  @override
  String get actionClose => 'Close';

  @override
  String get actionOpen => 'Open';

  @override
  String get settingsAutoConnect => 'Connect on launch';

  @override
  String get layoutTitle => 'Split view';

  @override
  String get layoutEmpty => 'This tab has only one pane';

  @override
  String get layoutLoading => 'Opening the split view…';

  @override
  String get layoutFollow => 'Follow focus here';

  @override
  String get layoutZoomed => 'This tab is zoomed, so only one pane is shown';

  @override
  String get settingsBehaviour => 'Behaviour';

  @override
  String get settingsTextSizeApp => 'App text';

  @override
  String get settingsDaemon => 'Daemon';

  @override
  String get settingsAppVersion => 'App version';

  @override
  String get hostCurrent => 'Current';

  @override
  String get hostsFooter =>
      'Tap to switch to a machine. Press and hold to edit or delete.';

  @override
  String get settingsKeys => 'Key bar';

  @override
  String get settingsComposer => 'Terminal composer';

  @override
  String get settingsComposerNote =>
      'Show the composer at the bottom of the terminal.';

  @override
  String settingsKeysCount(int count) {
    return '$count keys';
  }

  @override
  String get settingsKeysFooter =>
      'The row of keys under the terminal. Tap to choose which ones it offers.';

  @override
  String get keysTitle => 'Key bar';

  @override
  String get keysFooter =>
      'Ctrl, Alt and Shift are sticky: they wait for the next key you press, including on your own keyboard. Ctrl then d sends Ctrl+D.';

  @override
  String get keysReset => 'Reset to default';

  @override
  String get keysEmpty => 'No keys chosen';

  @override
  String get keysModifier => 'Modifier — waits for the next key';

  @override
  String get keysCopyHint =>
      'Copy and Paste are not keystrokes. Ctrl+C in a terminal is SIGINT, and is the C-c key.';

  @override
  String get askTitle => 'It is asking you';

  @override
  String get askLoading => 'Reading its screen…';

  @override
  String get askFailedTitle => 'Could not read its screen';

  @override
  String get askRetry => 'Try again';

  @override
  String get askUnclearNote =>
      'Could not tell what it is asking. Below is its screen — in this state, answer it in the terminal rather than here, because this screen does not guess.';

  @override
  String get askTruncatedNote =>
      'The screen was cut off, so only the readable part is shown.';

  @override
  String get askItsScreen => 'Its screen';

  @override
  String get askSend => 'Send';

  @override
  String get askSendTyped => 'Type only';

  @override
  String get askTypedNote =>
      'The text is typed in but not submitted — you press Enter yourself.';

  @override
  String get askSendFailed => 'Not sent';

  @override
  String get askSent => 'Handed to herdr';

  @override
  String get askSentNote => 'The board will update with what it does next.';

  @override
  String get askBackToBoard => 'Back to the board';

  @override
  String get askOpenTerminal => 'Answer in the terminal';

  @override
  String get askStaleChanged =>
      'It moved while you were reading, so nothing was sent. Open it again to see what it is asking now.';

  @override
  String get askStaleGone => 'That pane is gone.';

  @override
  String get askRefusedEmpty => 'There is nothing to send.';

  @override
  String get askRefusedMultiline =>
      'Multi-line text would count as a submission here, so it was not sent.';

  @override
  String get askFailedBlocked =>
      'It is stuck in a menu, so this has to be answered in the terminal.';

  @override
  String get askFooter =>
      'Its screen is re-read before sending. If it has changed, nothing is sent.';

  @override
  String get launchTitle => 'New';

  @override
  String get launchWhere => 'Where';

  @override
  String get launchDirectory => 'Directory';

  @override
  String get launchDirectoryNote =>
      'Which directory on the machine to work in.';

  @override
  String get launchWorktree => 'Use an isolated worktree';

  @override
  String get launchWorktreeNote =>
      'Opens a fresh git worktree on its own branch, so the agent cannot touch what you are looking at.';

  @override
  String get launchBranch => 'Branch';

  @override
  String get launchBranchNote => 'Leave blank to let herdr decide.';

  @override
  String get launchNotARepo =>
      'That directory is not inside a git repository, so this can only be a plain workspace.';

  @override
  String get launchAgent => 'Which agent';

  @override
  String get launchLoadingAgents => 'Asking herdr what it can start…';

  @override
  String get launchNoAgents => 'herdr reported no agents it can start.';

  @override
  String get launchUnavailableNote =>
      'The grey ones are not installed on this machine.';

  @override
  String get launchName => 'Name';

  @override
  String get launchNameLabel => 'Name';

  @override
  String get launchNameNote => 'Used on the board and as the terminal title.';

  @override
  String get launchCreating => 'Creating…';

  @override
  String get launchGo => 'Create and start';

  @override
  String get launchFooter =>
      'Creates a workspace on the machine, then starts this agent in its pane.';

  @override
  String get launchFailedRepo =>
      'That directory is not inside a git repository. Turn the worktree switch off and try again.';

  @override
  String get launchFailedNotReady =>
      'The pane was not ready to take an agent yet. Try again in a moment.';

  @override
  String get launchFailedName => 'That name is already taken — pick another.';

  @override
  String get launchFailedNoPane =>
      'herdr created the workspace but returned no pane id.';

  @override
  String get launchFailedGeneric => 'Could not start it';

  @override
  String get launchMode => 'Where to start it';

  @override
  String get launchModePane => 'In an existing pane';

  @override
  String get launchModePaneNote =>
      'No new workspace — an agent in a shell pane that is already free.';

  @override
  String get launchPickPane => 'Pick a pane';

  @override
  String get launchLoadingPanes => 'Checking what is running in each pane…';

  @override
  String get launchNoLaunchablePanes =>
      'No pane can take an agent right now. Turn the switch off to create a new workspace.';

  @override
  String launchBlockedAlready(String holder) {
    return '$holder is already in it';
  }

  @override
  String launchBlockedBusy(String holder) {
    return '$holder owns the foreground';
  }

  @override
  String get launchBlockedUnknown => 'its process list could not be read';

  @override
  String get launchBlockedGone => 'the pane is gone';

  @override
  String get attachTitle => 'Send it a file';

  @override
  String get attachClipboard => 'Clipboard text as a file';

  @override
  String get attachFile => 'Pick a file on this phone';

  @override
  String get attachGallery => 'Pick a photo';

  @override
  String get attachCamera => 'Take a photo';

  @override
  String get attachClipboardEmpty => 'There is no text on the clipboard.';

  @override
  String get attachDone =>
      'Uploaded — the path is typed in (press return to send it)';

  @override
  String get attachFailed => 'Upload failed';

  @override
  String get attachTooLarge => 'That file is too large.';

  @override
  String get attachEmpty => 'There is nothing to upload.';

  @override
  String get attachNoHome =>
      'Could not find the machine\'s home directory, so there is nowhere to put it.';

  @override
  String get attachNoDirectory =>
      'Could not create the upload directory on the machine.';

  @override
  String get attachUnavailable => 'This connection cannot carry files.';

  @override
  String get jumpTitle => 'Jump to';

  @override
  String get jumpEmpty => 'There are no panes on the machine yet.';

  @override
  String get jumpSectionPanes => 'Empty panes';

  @override
  String get jumpFooter =>
      'Tap to open it here; press and hold to move the machine\'s focus too.';

  @override
  String get settingsColourScheme => 'Colour scheme';

  @override
  String get themesTitle => 'Colour scheme';

  @override
  String get themesBuiltIn => 'Herdr Pocket default';

  @override
  String get themesBuiltInNote => 'The app\'s own colours';

  @override
  String get themesSectionDark => 'Dark';

  @override
  String get themesSectionLight => 'Light';

  @override
  String get themesFooter =>
      'A scheme recolours the whole app, and the terminal uses that scheme\'s own twenty colours. A scheme carries its own light-or-dark: picking a dark scheme makes the app dark, regardless of the system setting.';

  @override
  String get themesUnavailable => 'Couldn\'t read the colour schemes.';

  @override
  String get terminalAttach => 'Attach a file';

  @override
  String get terminalPanes => 'Switch pane';

  @override
  String get terminalLayout => 'Pane layout';

  @override
  String terminalZoomFont(Object percent) {
    return 'Font $percent%';
  }

  @override
  String get terminalMore => 'More';

  @override
  String get terminalShowKeyboard => 'Show keyboard';

  @override
  String get terminalHideKeyboard => 'Hide keyboard';

  @override
  String get terminalAllKeys => 'All keys';

  @override
  String get composerOpen => 'Composer';

  @override
  String get composerPlaceholder => 'Type here';

  @override
  String get composerSend => 'Send';

  @override
  String get composerAttach => 'Upload a picture or file from this phone';

  @override
  String get composerCommands => 'Skills and MCP';

  @override
  String get composerMention => 'Mention a file or folder';

  @override
  String get composerSectionSkills => 'skills';

  @override
  String get composerSectionMcp => 'MCP';

  @override
  String get composerSectionFiles => 'files';

  @override
  String get composerReading => 'Reading the machine…';

  @override
  String get composerNothingFound =>
      'No skills or MCP servers found on this machine.';

  @override
  String get composerEmptyDir => 'Nothing in this directory to reference.';

  @override
  String get composerNoMatch => 'Nothing matches.';

  @override
  String get composerNoSession =>
      'Not connected — send once the terminal is back.';

  @override
  String composerRemoveAttachment(String name) {
    return 'Remove attachment $name';
  }

  @override
  String get composerUnreadable => 'Could not read it:';

  @override
  String get composerUnavailable =>
      'This connection cannot read the remote machine.';

  @override
  String get morePaneUnknown => 'This pane\'s details have not arrived yet.';

  @override
  String get moreNotARepoHint =>
      'Git changes need a live connection to be read.';

  @override
  String get iconsTitle => 'Icons, three ways';

  @override
  String get iconsVariantMono => 'Mono';

  @override
  String get iconsVariantThemed => 'Themed';

  @override
  String get iconsVariantShowcase => 'Fixed';

  @override
  String get iconsDock => 'Dock';

  @override
  String get iconsToolbar => 'Terminal toolbar';

  @override
  String get iconsMachine => 'Machine entry, board top-left';

  @override
  String get iconsNote =>
      'A comparison, not a feature. The same positions drawn three ways: Mono is what ships today; Themed uses this icon set with every colour taken from the active scheme, so it changes when the scheme does; Fixed is the set\'s own palette, which follows nothing.';

  @override
  String get iconsUnavailable =>
      'Two icons in this set have a single colour slot, so they stay flat in both coloured variants.';

  @override
  String get settingsIcons => 'Icons';

  @override
  String get settingsIconsSystem => 'System';

  @override
  String get settingsIconsThemed => 'Themed';

  @override
  String get settingsTransferTitle => 'File transfer';

  @override
  String get settingsTransferEnabled => 'Allow file transfer';

  @override
  String get settingsTransferEnabledFooter =>
      'Turns on downloading files to the phone from the file browser. Needs a folder on the phone first.';

  @override
  String get settingsDownloadDir => 'Download folder';

  @override
  String get settingsDownloadDirUnset => 'Not selected';

  @override
  String get settingsDownloadDirHint =>
      'Tap to pick a folder. Chosen once, remembered across restarts.';

  @override
  String get settingsDownloadDirRevoked =>
      'This folder\'s permission is gone. Pick it again.';

  @override
  String get fileActionDownload => 'Download to phone';

  @override
  String get fileActionDownloadHint => 'Long press any file to download it too';

  @override
  String get downloadTitle => 'Downloading';

  @override
  String get downloadPreparing => 'Reading file info…';

  @override
  String downloadOf(Object done, Object name, Object total) {
    return '$name · $done / $total';
  }

  @override
  String downloadUnknownSize(Object done, Object name) {
    return '$name · $done received';
  }

  @override
  String get downloadCancel => 'Cancel';

  @override
  String downloadDone(Object dir) {
    return 'Saved to $dir';
  }

  @override
  String get downloadDoneNoDir => 'Saved to the phone';

  @override
  String get downloadFailedFeatureOff =>
      'File transfer is off. Turn it on in Settings.';

  @override
  String get downloadFailedNoDir =>
      'No download folder yet. Pick one in Settings.';

  @override
  String get downloadFailedRevoked =>
      'The download folder\'s permission is gone. Pick it again.';

  @override
  String get downloadFailedSftp =>
      'This host has no SFTP subsystem, so files cannot move.';

  @override
  String get downloadFailedRemote => 'The remote file could not be read.';

  @override
  String get downloadFailedConnection =>
      'The connection dropped before the transfer finished.';

  @override
  String get downloadFailedUnknown => 'The download failed.';

  @override
  String get downloadClose => 'Done';

  @override
  String get pairTitle => 'Device pairing';

  @override
  String get pairScanTitle => 'Scan the pairing code';

  @override
  String get pairScanRecommended => 'Recommended';

  @override
  String get pairScanBody =>
      'Run hdp pair on the computer, then point the camera at the QR code in the terminal.';

  @override
  String get pairScanStart => 'Open camera';

  @override
  String get pairScanDenied =>
      'The camera is unavailable or not permitted. Manual entry below works just as well.';

  @override
  String get pairPasteTitle => 'Enter pairing information';

  @override
  String get pairPasteBody =>
      'Paste the pairing string hdp pair printed. The scan and the paste are the same data — use whichever is easier.';

  @override
  String get pairPastePlaceholder => 'Paste the pairing string…';

  @override
  String get pairConnect => 'Pair and connect';

  @override
  String get pairRetry => 'Pair again';

  @override
  String get pairStatusIdle =>
      'Paste a pairing string and tap Pair. The result appears here.';

  @override
  String pairStatusConnect(Object host) {
    return 'Connecting to $host…';
  }

  @override
  String get pairStatusExchange => 'Installing this phone\'s key…';

  @override
  String get pairStatusVerify => 'Verifying the new key…';

  @override
  String pairStatusDone(Object name) {
    return 'Paired: $name';
  }

  @override
  String get pairFailedEmpty => 'No pairing string has been pasted yet.';

  @override
  String get pairFailedMalformed =>
      'That does not look like a pairing string. It should be a long run of letters, digits, `-` and `_`.';

  @override
  String get pairFailedUnsupported =>
      'That pairing string comes from a newer hdp. Update hdp and try again.';

  @override
  String get pairFailedIncomplete => 'That pairing string is incomplete.';

  @override
  String get pairFailedUnreachable =>
      'Could not reach the machine. Check the address, and whether the phone is on the same network.';

  @override
  String get pairFailedMismatch =>
      'This machine\'s host key does not match the one in the pairing code. The code may have expired, or something is in the middle.';

  @override
  String get pairFailedBootstrap =>
      'The pairing code has expired. Run hdp pair again on the computer.';

  @override
  String get pairFailedExchange =>
      'The hdp on that machine could not install the key. Check that its version matches the install script.';

  @override
  String get pairFailedVerify =>
      'The key was installed but does not connect. Run hdp list on the computer.';

  @override
  String get pairFailedUnknown => 'Pairing failed.';

  @override
  String get hostPair => 'Pair by QR code (recommended)';

  @override
  String get hostAddManually => 'Add manually';

  @override
  String get hostPairHint =>
      'Run hdp pair on the computer and scan its QR code — no address, port or key to type.';

  @override
  String get actionDone => 'Done';

  @override
  String get settingsUpdates => 'Updates';

  @override
  String get settingsCheckUpdate => 'Check for updates';

  @override
  String get settingsAutoUpdate => 'Check automatically';

  @override
  String get updateSheetTitle => 'Software update';

  @override
  String get updateChecking => 'Asking GitHub…';

  @override
  String updateUpToDate(String version) {
    return 'Up to date — $version';
  }

  @override
  String updateAvailableTitle(String version) {
    return 'Version $version is available';
  }

  @override
  String updateResumeHint(String size) {
    return '$size already downloaded — it will continue from there';
  }

  @override
  String get updateNotInstallable =>
      'This platform cannot install an update itself. The release page has the file:';

  @override
  String get updateNotesTitle => 'RELEASE NOTES';

  @override
  String get updateDownload => 'Download';

  @override
  String get updateResume => 'Continue download';

  @override
  String get updateOpenRelease => 'Open release page';

  @override
  String get updateDownloading => 'Downloading';

  @override
  String get updateCancelDownload => 'Cancel';

  @override
  String get updateCancelled => 'Cancelled.';

  @override
  String updateReady(String version) {
    return '$version downloaded and checked';
  }

  @override
  String get updateVerified =>
      'Package name and signing key match the installed app, so it can be installed over it.';

  @override
  String get updateNeedsPermission =>
      'Android has not allowed this app to install packages yet.';

  @override
  String get updateAllowInstall => 'Allow installing apps';

  @override
  String get updateInstall => 'Install';

  @override
  String get updateInstallFootnote =>
      'Android will show its own confirmation. The app restarts into the new version afterwards.';

  @override
  String get updateFailedOffline =>
      'Could not reach GitHub. Check the connection.';

  @override
  String updateFailedProxy(String address) {
    return 'The proxy at $address did not answer.';
  }

  @override
  String get updateFailedProxyUnknown =>
      'A proxy is configured but did not answer.';

  @override
  String get updateFailedTls =>
      'The HTTPS certificate was rejected. An intercepting proxy needs its CA trusted by the system; this app does not trust user-installed CAs.';

  @override
  String get updateFailedTimedOut =>
      'Connected, then nothing arrived for a minute.';

  @override
  String get updateFailedRateLimited =>
      'GitHub\'s anonymous limit is used up (60 requests an hour). Try again later.';

  @override
  String get updateFailedHttp => 'GitHub returned an error.';

  @override
  String get updateFailedPayload =>
      'The answer was not what was expected — a Wi-Fi sign-in page can look like this.';

  @override
  String get updateFailedNoRelease =>
      'No release is published for this app yet.';

  @override
  String get updateFailedNoAsset =>
      'That release has no build for this device\'s CPU.';

  @override
  String get updateFailedStorage =>
      'Could not write the file to the phone. Out of space?';

  @override
  String get updateFailedChecksum =>
      'The file did not match the release\'s checksum. It has been deleted; retrying downloads it again.';

  @override
  String get updateFailedSize =>
      'The download ended with the wrong number of bytes. It has been deleted.';

  @override
  String get updateFailedInstallBlocked =>
      'Android is not letting this app install packages.';

  @override
  String get updateFailedSignature =>
      'This APK is signed with a different key than the installed app, so Android would refuse it. The copy on this phone is probably one built locally with the debug key — installing this one means uninstalling first, WHICH DELETES THE SAVED MACHINES AND SSH KEYS.';

  @override
  String get updateFailedWrongPackage => 'That file is not Herdr Pocket.';

  @override
  String get updateFailedVersionOld =>
      'The file is older than what is installed, so Android would refuse it.';

  @override
  String get updateFailedUnknown => 'The update failed.';

  @override
  String get updateRowChecking => 'Checking…';

  @override
  String updateRowAvailable(String version) {
    return 'Version $version available';
  }

  @override
  String get updateRowUpToDate => 'Up to date';

  @override
  String get updateRowFailed => 'Last check failed';

  @override
  String get updateRowNever => 'Never checked';

  @override
  String get updateUrlCopied => 'Link copied';

  @override
  String get shellConnecting => 'Opening a terminal…';

  @override
  String get shellConnectingBody => 'Connecting over SSH and asking for a pty.';

  @override
  String get shellFailed => 'Could not open a terminal';

  @override
  String get shellEnded => 'The session ended';

  @override
  String get shellExitUnknown => 'The remote side did not report an exit code.';

  @override
  String get shellReopen => 'Open again';

  @override
  String get shellBackToLive => 'Back to live';

  @override
  String shellExitCode(int code) {
    return 'The process exited with code $code.';
  }

  @override
  String get shellOpen => 'Open a terminal';

  @override
  String get shellPickMachine => 'Open a terminal on which machine?';

  @override
  String get shellNoMachines =>
      'No machines are saved yet. Add one under Machines, and once its SSH is set up you can open a terminal from here.';

  @override
  String get shellCommandTitle => 'Terminal command';

  @override
  String get shellCommandLabel => 'Run on open';

  @override
  String get shellCommandPlaceholder => 'blank = login shell';

  @override
  String get shellCommandRestore => 'Restore the default command';

  @override
  String get shellCommandFooter =>
      'Runs in a non-login shell, so PATH is narrow — use a full path for anything missing from it.';

  @override
  String get shellScrollbackTitle => 'Scrollback';

  @override
  String get shellScrollbackLabel => 'Lines to keep';

  @override
  String shellScrollbackFooter(int min, int max) {
    return 'Accepts $min–$max. Applies the next time a terminal is opened.';
  }

  @override
  String shellScrollbackLines(int lines) {
    return '$lines lines';
  }

  @override
  String get shellCommandDefaultValue => 'tmux, or a login shell';

  @override
  String get shellCommandCustom => 'Custom';
}
