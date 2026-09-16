import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Herdr Pocket'**
  String get appTitle;

  /// No description provided for @boardTitle.
  ///
  /// In en, this message translates to:
  /// **'Agents'**
  String get boardTitle;

  /// Headline above the agent board. Only shown when at least one agent needs attention.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Nothing to approve} =1{{count} awaiting approval} other{{count} awaiting approval}}'**
  String boardNeedsYouCount(int count);

  /// No description provided for @boardEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No agents yet'**
  String get boardEmptyTitle;

  /// No description provided for @boardEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Start an agent in herdr on your machine and it will appear here.'**
  String get boardEmptyBody;

  /// No description provided for @groupNeedsYou.
  ///
  /// In en, this message translates to:
  /// **'Approvals'**
  String get groupNeedsYou;

  /// No description provided for @groupStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get groupStopped;

  /// No description provided for @groupUnrecognised.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get groupUnrecognised;

  /// No description provided for @groupWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get groupWorking;

  /// No description provided for @groupIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get groupIdle;

  /// No description provided for @groupUnrecognisedHint.
  ///
  /// In en, this message translates to:
  /// **'This build cannot read this agent\'s state. Update the app, or check the daemon.'**
  String get groupUnrecognisedHint;

  /// No description provided for @groupArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get groupArchived;

  /// No description provided for @statusIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get statusIdle;

  /// No description provided for @statusWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get statusWorking;

  /// No description provided for @statusBlocked.
  ///
  /// In en, this message translates to:
  /// **'Awaiting approval'**
  String get statusBlocked;

  /// No description provided for @statusDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get statusDone;

  /// No description provided for @statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get statusUnknown;

  /// No description provided for @terminalTitle.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get terminalTitle;

  /// No description provided for @terminalReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read only'**
  String get terminalReadOnly;

  /// No description provided for @terminalReadOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Another client is controlling this terminal.'**
  String get terminalReadOnlyHint;

  /// No description provided for @terminalConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get terminalConnecting;

  /// No description provided for @terminalDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get terminalDisconnected;

  /// No description provided for @terminalExited.
  ///
  /// In en, this message translates to:
  /// **'Process exited'**
  String get terminalExited;

  /// No description provided for @actionPrompt.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get actionPrompt;

  /// No description provided for @actionSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get actionSend;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @actionReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get actionReconnect;

  /// No description provided for @actionConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get actionConnect;

  /// No description provided for @actionDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get actionDisconnect;

  /// No description provided for @actionApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get actionApprove;

  /// No description provided for @hostsTitle.
  ///
  /// In en, this message translates to:
  /// **'Machines'**
  String get hostsTitle;

  /// No description provided for @hostAdd.
  ///
  /// In en, this message translates to:
  /// **'Add machine'**
  String get hostAdd;

  /// No description provided for @hostEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit machine'**
  String get hostEdit;

  /// No description provided for @hostLabel.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get hostLabel;

  /// No description provided for @hostAddress.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get hostAddress;

  /// No description provided for @hostPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get hostPort;

  /// No description provided for @hostUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get hostUsername;

  /// No description provided for @hostAuthMethod.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get hostAuthMethod;

  /// No description provided for @hostAuthPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get hostAuthPassword;

  /// No description provided for @hostAuthKey.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get hostAuthKey;

  /// No description provided for @hostAuthAgent.
  ///
  /// In en, this message translates to:
  /// **'SSH agent'**
  String get hostAuthAgent;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsTheme;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsGlass.
  ///
  /// In en, this message translates to:
  /// **'Liquid Glass'**
  String get settingsGlass;

  /// No description provided for @settingsSafety.
  ///
  /// In en, this message translates to:
  /// **'Safety margin'**
  String get settingsSafety;

  /// No description provided for @safetyDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get safetyDefault;

  /// No description provided for @safetyOn.
  ///
  /// In en, this message translates to:
  /// **'Always on'**
  String get safetyOn;

  /// No description provided for @safetyOff.
  ///
  /// In en, this message translates to:
  /// **'Always off'**
  String get safetyOff;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsLanguageSystem;

  /// No description provided for @settingsTextSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get settingsTextSize;

  /// No description provided for @settingsTerminalFontSize.
  ///
  /// In en, this message translates to:
  /// **'Terminal font size'**
  String get settingsTerminalFontSize;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// No description provided for @settingsDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get settingsDiagnostics;

  /// No description provided for @connectionStageConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectionStageConnecting;

  /// No description provided for @connectionStageVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying…'**
  String get connectionStageVerifying;

  /// No description provided for @connectionStageLastAttempt.
  ///
  /// In en, this message translates to:
  /// **'One last attempt…'**
  String get connectionStageLastAttempt;

  /// No description provided for @connectionRetryAttempt.
  ///
  /// In en, this message translates to:
  /// **'Retrying {attempt}/{max}…'**
  String connectionRetryAttempt(int attempt, int max);

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailed;

  /// No description provided for @connectionFailedAfterRetries.
  ///
  /// In en, this message translates to:
  /// **'Tried {count} times'**
  String connectionFailedAfterRetries(int count);

  /// No description provided for @connectionStateOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get connectionStateOnline;

  /// No description provided for @connectionStateOffline.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get connectionStateOffline;

  /// No description provided for @connectionStateAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed'**
  String get connectionStateAuthFailed;

  /// No description provided for @connectionStateHostKeyChanged.
  ///
  /// In en, this message translates to:
  /// **'Host key changed'**
  String get connectionStateHostKeyChanged;

  /// No description provided for @connectionStateHostKeyChangedBody.
  ///
  /// In en, this message translates to:
  /// **'The machine\'s key is different from the one you approved. This can mean it was rebuilt — or that someone is intercepting the connection.'**
  String get connectionStateHostKeyChangedBody;

  /// No description provided for @errorForwardingRefused.
  ///
  /// In en, this message translates to:
  /// **'The machine\'s SSH server refuses to forward to the herdr socket. Turn on AllowStreamLocalForwarding on it, then reconnect.'**
  String get errorForwardingRefused;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get errorGeneric;

  /// No description provided for @errorHerdrNotFound.
  ///
  /// In en, this message translates to:
  /// **'herdr was not found on this machine'**
  String get errorHerdrNotFound;

  /// No description provided for @errorHerdrNotFoundBody.
  ///
  /// In en, this message translates to:
  /// **'Install herdr on the machine and make sure it is on your PATH, then reconnect.'**
  String get errorHerdrNotFoundBody;

  /// No description provided for @errorTerminalUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This herdr is too old for the live terminal'**
  String get errorTerminalUnsupported;

  /// No description provided for @errorTerminalUnsupportedBody.
  ///
  /// In en, this message translates to:
  /// **'herdr 0.9.0 or newer is required. Update herdr on the machine and reconnect.'**
  String get errorTerminalUnsupportedBody;

  /// No description provided for @hostKeyNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New machine'**
  String get hostKeyNewTitle;

  /// No description provided for @hostKeyNewBody.
  ///
  /// In en, this message translates to:
  /// **'Herdr Pocket has not connected to this machine before. Check the fingerprint matches the one shown by your machine before continuing.'**
  String get hostKeyNewBody;

  /// No description provided for @hostKeyChangedTitle.
  ///
  /// In en, this message translates to:
  /// **'Host key changed'**
  String get hostKeyChangedTitle;

  /// No description provided for @hostKeyChangedBody.
  ///
  /// In en, this message translates to:
  /// **'The key this machine presented is different from the one you approved. This can mean the machine was rebuilt — or that someone is intercepting the connection. Only continue if you know why it changed.'**
  String get hostKeyChangedBody;

  /// No description provided for @hostKeyFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get hostKeyFingerprint;

  /// No description provided for @hostKeyPreviously.
  ///
  /// In en, this message translates to:
  /// **'Previously approved'**
  String get hostKeyPreviously;

  /// No description provided for @hostKeyApproveAndRemember.
  ///
  /// In en, this message translates to:
  /// **'Trust and remember'**
  String get hostKeyApproveAndRemember;

  /// No description provided for @hostKeyApproveOnce.
  ///
  /// In en, this message translates to:
  /// **'Trust once'**
  String get hostKeyApproveOnce;

  /// No description provided for @hostKeyReject.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get hostKeyReject;

  /// No description provided for @hostKeyShowDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get hostKeyShowDetails;

  /// No description provided for @hostsNoHosts.
  ///
  /// In en, this message translates to:
  /// **'No machines yet'**
  String get hostsNoHosts;

  /// No description provided for @hostsNoHostsBody.
  ///
  /// In en, this message translates to:
  /// **'Add the machine running herdr and its agents will appear on the board.'**
  String get hostsNoHostsBody;

  /// No description provided for @hostSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get hostSave;

  /// No description provided for @hostDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get hostDelete;

  /// No description provided for @hostSshKey.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get hostSshKey;

  /// No description provided for @hostSshKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Paste an OpenSSH private key'**
  String get hostSshKeyHint;

  /// No description provided for @hostPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get hostPasswordHint;

  /// No description provided for @hostUsernameHint.
  ///
  /// In en, this message translates to:
  /// **'you'**
  String get hostUsernameHint;

  /// No description provided for @hostLabelHint.
  ///
  /// In en, this message translates to:
  /// **'Work laptop'**
  String get hostLabelHint;

  /// No description provided for @hostHostHint.
  ///
  /// In en, this message translates to:
  /// **'10.0.0.5 or my-host.local'**
  String get hostHostHint;

  /// No description provided for @hostConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get hostConnect;

  /// No description provided for @hostConnectNow.
  ///
  /// In en, this message translates to:
  /// **'Use this machine'**
  String get hostConnectNow;

  /// No description provided for @hostMissing.
  ///
  /// In en, this message translates to:
  /// **'Fill in host and username'**
  String get hostMissing;

  /// No description provided for @hostInvalidPort.
  ///
  /// In en, this message translates to:
  /// **'Port must be between 1 and 65535'**
  String get hostInvalidPort;

  /// No description provided for @hostSecretNote.
  ///
  /// In en, this message translates to:
  /// **'Stored in this device\'s keystore, never in the host list.'**
  String get hostSecretNote;

  /// No description provided for @terminalScrolledBack.
  ///
  /// In en, this message translates to:
  /// **'{lines} lines back — tap to return to live'**
  String terminalScrolledBack(Object lines);

  /// No description provided for @terminalSelectionHint.
  ///
  /// In en, this message translates to:
  /// **'Select text'**
  String get terminalSelectionHint;

  /// No description provided for @copyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyAction;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// No description provided for @settingsNotificationsFooter.
  ///
  /// In en, this message translates to:
  /// **'A notification when an agent starts waiting on you, while the app is running.'**
  String get settingsNotificationsFooter;

  /// No description provided for @navBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get navBack;

  /// No description provided for @navBoard.
  ///
  /// In en, this message translates to:
  /// **'Board'**
  String get navBoard;

  /// No description provided for @navWorkspaces.
  ///
  /// In en, this message translates to:
  /// **'Workspaces'**
  String get navWorkspaces;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @workspacesTitle.
  ///
  /// In en, this message translates to:
  /// **'Workspaces'**
  String get workspacesTitle;

  /// No description provided for @workspacesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No workspaces'**
  String get workspacesEmptyTitle;

  /// No description provided for @workspacesEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Create a workspace in herdr on your machine and it will show up here.'**
  String get workspacesEmptyBody;

  /// No description provided for @workspacesCounts.
  ///
  /// In en, this message translates to:
  /// **'{tabs} tabs · {panes} panes'**
  String workspacesCounts(int tabs, int panes);

  /// No description provided for @workspacesTabsLabel.
  ///
  /// In en, this message translates to:
  /// **'Tabs'**
  String get workspacesTabsLabel;

  /// No description provided for @workspacesPanesLabel.
  ///
  /// In en, this message translates to:
  /// **'Panes'**
  String get workspacesPanesLabel;

  /// No description provided for @workspacesCurrent.
  ///
  /// In en, this message translates to:
  /// **'Focused'**
  String get workspacesCurrent;

  /// No description provided for @workspacesFocusPane.
  ///
  /// In en, this message translates to:
  /// **'Move focus here'**
  String get workspacesFocusPane;

  /// No description provided for @workspacesFocusTab.
  ///
  /// In en, this message translates to:
  /// **'Focus this tab'**
  String get workspacesFocusTab;

  /// No description provided for @workspacesFocusWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Focus this workspace'**
  String get workspacesFocusWorkspace;

  /// No description provided for @workspacesFocusDone.
  ///
  /// In en, this message translates to:
  /// **'Focus moved'**
  String get workspacesFocusDone;

  /// No description provided for @workspacesFocusFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not move focus'**
  String get workspacesFocusFailed;

  /// No description provided for @workspacesNoPanes.
  ///
  /// In en, this message translates to:
  /// **'This tab has no panes'**
  String get workspacesNoPanes;

  /// No description provided for @paneSwitcherTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch pane'**
  String get paneSwitcherTitle;

  /// No description provided for @paneSwitcherCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current pane'**
  String get paneSwitcherCurrent;

  /// No description provided for @paneSwitcherOtherTabs.
  ///
  /// In en, this message translates to:
  /// **'Other tabs in this workspace'**
  String get paneSwitcherOtherTabs;

  /// No description provided for @paneSwitcherRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh list'**
  String get paneSwitcherRefresh;

  /// No description provided for @filesTitle.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get filesTitle;

  /// No description provided for @filePreviewLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading…'**
  String get filePreviewLoading;

  /// No description provided for @filePreviewEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty file'**
  String get filePreviewEmpty;

  /// No description provided for @filePreviewBinary.
  ///
  /// In en, this message translates to:
  /// **'Binary file — not shown as text.'**
  String get filePreviewBinary;

  /// No description provided for @filePreviewFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read this file'**
  String get filePreviewFailed;

  /// No description provided for @filePreviewTruncated.
  ///
  /// In en, this message translates to:
  /// **'Showing the first {kb} KB'**
  String filePreviewTruncated(int kb);

  /// No description provided for @filePreviewLines.
  ///
  /// In en, this message translates to:
  /// **'{count} lines'**
  String filePreviewLines(int count);

  /// No description provided for @gitTitle.
  ///
  /// In en, this message translates to:
  /// **'Git changes'**
  String get gitTitle;

  /// No description provided for @gitClean.
  ///
  /// In en, this message translates to:
  /// **'Working tree clean'**
  String get gitClean;

  /// No description provided for @gitStaged.
  ///
  /// In en, this message translates to:
  /// **'Staged'**
  String get gitStaged;

  /// No description provided for @gitUnstaged.
  ///
  /// In en, this message translates to:
  /// **'Unstaged'**
  String get gitUnstaged;

  /// No description provided for @gitUntracked.
  ///
  /// In en, this message translates to:
  /// **'Untracked'**
  String get gitUntracked;

  /// No description provided for @gitConflicted.
  ///
  /// In en, this message translates to:
  /// **'Conflicted'**
  String get gitConflicted;

  /// No description provided for @gitAheadBehind.
  ///
  /// In en, this message translates to:
  /// **'{ahead} ahead · {behind} behind'**
  String gitAheadBehind(int ahead, int behind);

  /// No description provided for @gitNotARepo.
  ///
  /// In en, this message translates to:
  /// **'This directory is not inside a git repository'**
  String get gitNotARepo;

  /// No description provided for @gitChangesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} changes'**
  String gitChangesCount(int count);

  /// No description provided for @gitLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading git status…'**
  String get gitLoading;

  /// No description provided for @gitDiffEmpty.
  ///
  /// In en, this message translates to:
  /// **'No diff to show'**
  String get gitDiffEmpty;

  /// No description provided for @gitUnavailable.
  ///
  /// In en, this message translates to:
  /// **'git is not installed on that machine'**
  String get gitUnavailable;

  /// No description provided for @actionRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get actionRefresh;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @actionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get actionOpen;

  /// No description provided for @settingsAutoConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect on launch'**
  String get settingsAutoConnect;

  /// No description provided for @layoutTitle.
  ///
  /// In en, this message translates to:
  /// **'Split view'**
  String get layoutTitle;

  /// No description provided for @layoutEmpty.
  ///
  /// In en, this message translates to:
  /// **'This tab has only one pane'**
  String get layoutEmpty;

  /// No description provided for @layoutLoading.
  ///
  /// In en, this message translates to:
  /// **'Opening the split view…'**
  String get layoutLoading;

  /// No description provided for @layoutFollow.
  ///
  /// In en, this message translates to:
  /// **'Follow focus here'**
  String get layoutFollow;

  /// No description provided for @layoutZoomed.
  ///
  /// In en, this message translates to:
  /// **'This tab is zoomed, so only one pane is shown'**
  String get layoutZoomed;

  /// No description provided for @settingsBehaviour.
  ///
  /// In en, this message translates to:
  /// **'Behaviour'**
  String get settingsBehaviour;

  /// No description provided for @settingsTextSizeApp.
  ///
  /// In en, this message translates to:
  /// **'App text'**
  String get settingsTextSizeApp;

  /// No description provided for @settingsDaemon.
  ///
  /// In en, this message translates to:
  /// **'Daemon'**
  String get settingsDaemon;

  /// No description provided for @settingsAppVersion.
  ///
  /// In en, this message translates to:
  /// **'App version'**
  String get settingsAppVersion;

  /// No description provided for @hostCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get hostCurrent;

  /// No description provided for @hostsFooter.
  ///
  /// In en, this message translates to:
  /// **'Tap to switch to a machine. Press and hold to edit or delete.'**
  String get hostsFooter;

  /// No description provided for @settingsKeys.
  ///
  /// In en, this message translates to:
  /// **'Key bar'**
  String get settingsKeys;

  /// No description provided for @settingsKeysCount.
  ///
  /// In en, this message translates to:
  /// **'{count} keys'**
  String settingsKeysCount(int count);

  /// No description provided for @settingsKeysFooter.
  ///
  /// In en, this message translates to:
  /// **'The row of keys under the terminal. Tap to choose which ones it offers.'**
  String get settingsKeysFooter;

  /// No description provided for @keysTitle.
  ///
  /// In en, this message translates to:
  /// **'Key bar'**
  String get keysTitle;

  /// No description provided for @keysFooter.
  ///
  /// In en, this message translates to:
  /// **'Ctrl, Alt and Shift are sticky: they wait for the next key you press, including on your own keyboard. Ctrl then d sends Ctrl+D.'**
  String get keysFooter;

  /// No description provided for @keysReset.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get keysReset;

  /// No description provided for @keysEmpty.
  ///
  /// In en, this message translates to:
  /// **'No keys chosen'**
  String get keysEmpty;

  /// No description provided for @keysModifier.
  ///
  /// In en, this message translates to:
  /// **'Modifier — waits for the next key'**
  String get keysModifier;

  /// No description provided for @keysCopyHint.
  ///
  /// In en, this message translates to:
  /// **'Copy and Paste are not keystrokes. Ctrl+C in a terminal is SIGINT, and is the C-c key.'**
  String get keysCopyHint;

  /// No description provided for @askTitle.
  ///
  /// In en, this message translates to:
  /// **'It is asking you'**
  String get askTitle;

  /// No description provided for @askLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading its screen…'**
  String get askLoading;

  /// No description provided for @askFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not read its screen'**
  String get askFailedTitle;

  /// No description provided for @askRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get askRetry;

  /// No description provided for @askUnclearNote.
  ///
  /// In en, this message translates to:
  /// **'Could not tell what it is asking. Below is its screen — in this state, answer it in the terminal rather than here, because this screen does not guess.'**
  String get askUnclearNote;

  /// No description provided for @askTruncatedNote.
  ///
  /// In en, this message translates to:
  /// **'The screen was cut off, so only the readable part is shown.'**
  String get askTruncatedNote;

  /// No description provided for @askItsScreen.
  ///
  /// In en, this message translates to:
  /// **'Its screen'**
  String get askItsScreen;

  /// No description provided for @askSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get askSend;

  /// No description provided for @askSendTyped.
  ///
  /// In en, this message translates to:
  /// **'Type only'**
  String get askSendTyped;

  /// No description provided for @askTypedNote.
  ///
  /// In en, this message translates to:
  /// **'The text is typed in but not submitted — you press Enter yourself.'**
  String get askTypedNote;

  /// No description provided for @askSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Not sent'**
  String get askSendFailed;

  /// No description provided for @askSent.
  ///
  /// In en, this message translates to:
  /// **'Handed to herdr'**
  String get askSent;

  /// No description provided for @askSentNote.
  ///
  /// In en, this message translates to:
  /// **'The board will update with what it does next.'**
  String get askSentNote;

  /// No description provided for @askBackToBoard.
  ///
  /// In en, this message translates to:
  /// **'Back to the board'**
  String get askBackToBoard;

  /// No description provided for @askOpenTerminal.
  ///
  /// In en, this message translates to:
  /// **'Answer in the terminal'**
  String get askOpenTerminal;

  /// No description provided for @askStaleChanged.
  ///
  /// In en, this message translates to:
  /// **'It moved while you were reading, so nothing was sent. Open it again to see what it is asking now.'**
  String get askStaleChanged;

  /// No description provided for @askStaleGone.
  ///
  /// In en, this message translates to:
  /// **'That pane is gone.'**
  String get askStaleGone;

  /// No description provided for @askRefusedEmpty.
  ///
  /// In en, this message translates to:
  /// **'There is nothing to send.'**
  String get askRefusedEmpty;

  /// No description provided for @askRefusedMultiline.
  ///
  /// In en, this message translates to:
  /// **'Multi-line text would count as a submission here, so it was not sent.'**
  String get askRefusedMultiline;

  /// No description provided for @askFailedBlocked.
  ///
  /// In en, this message translates to:
  /// **'It is stuck in a menu, so this has to be answered in the terminal.'**
  String get askFailedBlocked;

  /// No description provided for @askFooter.
  ///
  /// In en, this message translates to:
  /// **'Its screen is re-read before sending. If it has changed, nothing is sent.'**
  String get askFooter;

  /// No description provided for @launchTitle.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get launchTitle;

  /// No description provided for @launchWhere.
  ///
  /// In en, this message translates to:
  /// **'Where'**
  String get launchWhere;

  /// No description provided for @launchDirectory.
  ///
  /// In en, this message translates to:
  /// **'Directory'**
  String get launchDirectory;

  /// No description provided for @launchDirectoryNote.
  ///
  /// In en, this message translates to:
  /// **'Which directory on the machine to work in.'**
  String get launchDirectoryNote;

  /// No description provided for @launchWorktree.
  ///
  /// In en, this message translates to:
  /// **'Use an isolated worktree'**
  String get launchWorktree;

  /// No description provided for @launchWorktreeNote.
  ///
  /// In en, this message translates to:
  /// **'Opens a fresh git worktree on its own branch, so the agent cannot touch what you are looking at.'**
  String get launchWorktreeNote;

  /// No description provided for @launchBranch.
  ///
  /// In en, this message translates to:
  /// **'Branch'**
  String get launchBranch;

  /// No description provided for @launchBranchNote.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to let herdr decide.'**
  String get launchBranchNote;

  /// No description provided for @launchNotARepo.
  ///
  /// In en, this message translates to:
  /// **'That directory is not inside a git repository, so this can only be a plain workspace.'**
  String get launchNotARepo;

  /// No description provided for @launchAgent.
  ///
  /// In en, this message translates to:
  /// **'Which agent'**
  String get launchAgent;

  /// No description provided for @launchLoadingAgents.
  ///
  /// In en, this message translates to:
  /// **'Asking herdr what it can start…'**
  String get launchLoadingAgents;

  /// No description provided for @launchNoAgents.
  ///
  /// In en, this message translates to:
  /// **'herdr reported no agents it can start.'**
  String get launchNoAgents;

  /// No description provided for @launchUnavailableNote.
  ///
  /// In en, this message translates to:
  /// **'The grey ones are not installed on this machine.'**
  String get launchUnavailableNote;

  /// No description provided for @launchName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get launchName;

  /// No description provided for @launchNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get launchNameLabel;

  /// No description provided for @launchNameNote.
  ///
  /// In en, this message translates to:
  /// **'Used on the board and as the terminal title.'**
  String get launchNameNote;

  /// No description provided for @launchCreating.
  ///
  /// In en, this message translates to:
  /// **'Creating…'**
  String get launchCreating;

  /// No description provided for @launchGo.
  ///
  /// In en, this message translates to:
  /// **'Create and start'**
  String get launchGo;

  /// No description provided for @launchFooter.
  ///
  /// In en, this message translates to:
  /// **'Creates a workspace on the machine, then starts this agent in its pane.'**
  String get launchFooter;

  /// No description provided for @launchFailedRepo.
  ///
  /// In en, this message translates to:
  /// **'That directory is not inside a git repository. Turn the worktree switch off and try again.'**
  String get launchFailedRepo;

  /// No description provided for @launchFailedNotReady.
  ///
  /// In en, this message translates to:
  /// **'The pane was not ready to take an agent yet. Try again in a moment.'**
  String get launchFailedNotReady;

  /// No description provided for @launchFailedName.
  ///
  /// In en, this message translates to:
  /// **'That name is already taken — pick another.'**
  String get launchFailedName;

  /// No description provided for @launchFailedNoPane.
  ///
  /// In en, this message translates to:
  /// **'herdr created the workspace but returned no pane id.'**
  String get launchFailedNoPane;

  /// No description provided for @launchFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Could not start it'**
  String get launchFailedGeneric;

  /// No description provided for @launchMode.
  ///
  /// In en, this message translates to:
  /// **'Where to start it'**
  String get launchMode;

  /// No description provided for @launchModePane.
  ///
  /// In en, this message translates to:
  /// **'In an existing pane'**
  String get launchModePane;

  /// No description provided for @launchModePaneNote.
  ///
  /// In en, this message translates to:
  /// **'No new workspace — an agent in a shell pane that is already free.'**
  String get launchModePaneNote;

  /// No description provided for @launchPickPane.
  ///
  /// In en, this message translates to:
  /// **'Pick a pane'**
  String get launchPickPane;

  /// No description provided for @launchLoadingPanes.
  ///
  /// In en, this message translates to:
  /// **'Checking what is running in each pane…'**
  String get launchLoadingPanes;

  /// No description provided for @launchNoLaunchablePanes.
  ///
  /// In en, this message translates to:
  /// **'No pane can take an agent right now. Turn the switch off to create a new workspace.'**
  String get launchNoLaunchablePanes;

  /// No description provided for @launchBlockedAlready.
  ///
  /// In en, this message translates to:
  /// **'{holder} is already in it'**
  String launchBlockedAlready(String holder);

  /// No description provided for @launchBlockedBusy.
  ///
  /// In en, this message translates to:
  /// **'{holder} owns the foreground'**
  String launchBlockedBusy(String holder);

  /// No description provided for @launchBlockedUnknown.
  ///
  /// In en, this message translates to:
  /// **'its process list could not be read'**
  String get launchBlockedUnknown;

  /// No description provided for @launchBlockedGone.
  ///
  /// In en, this message translates to:
  /// **'the pane is gone'**
  String get launchBlockedGone;

  /// No description provided for @attachTitle.
  ///
  /// In en, this message translates to:
  /// **'Send it a file'**
  String get attachTitle;

  /// No description provided for @attachClipboard.
  ///
  /// In en, this message translates to:
  /// **'Clipboard text as a file'**
  String get attachClipboard;

  /// No description provided for @attachGallery.
  ///
  /// In en, this message translates to:
  /// **'Pick a photo'**
  String get attachGallery;

  /// No description provided for @attachCamera.
  ///
  /// In en, this message translates to:
  /// **'Take a photo'**
  String get attachCamera;

  /// No description provided for @attachClipboardEmpty.
  ///
  /// In en, this message translates to:
  /// **'There is no text on the clipboard.'**
  String get attachClipboardEmpty;

  /// No description provided for @attachDone.
  ///
  /// In en, this message translates to:
  /// **'Uploaded — the path is typed in (press return to send it)'**
  String get attachDone;

  /// No description provided for @attachFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get attachFailed;

  /// No description provided for @attachTooLarge.
  ///
  /// In en, this message translates to:
  /// **'That file is too large.'**
  String get attachTooLarge;

  /// No description provided for @attachEmpty.
  ///
  /// In en, this message translates to:
  /// **'There is nothing to upload.'**
  String get attachEmpty;

  /// No description provided for @attachNoHome.
  ///
  /// In en, this message translates to:
  /// **'Could not find the machine\'s home directory, so there is nowhere to put it.'**
  String get attachNoHome;

  /// No description provided for @attachNoDirectory.
  ///
  /// In en, this message translates to:
  /// **'Could not create the upload directory on the machine.'**
  String get attachNoDirectory;

  /// No description provided for @attachUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This connection cannot carry files.'**
  String get attachUnavailable;

  /// No description provided for @jumpTitle.
  ///
  /// In en, this message translates to:
  /// **'Jump to'**
  String get jumpTitle;

  /// No description provided for @jumpEmpty.
  ///
  /// In en, this message translates to:
  /// **'There are no panes on the machine yet.'**
  String get jumpEmpty;

  /// No description provided for @jumpSectionPanes.
  ///
  /// In en, this message translates to:
  /// **'Empty panes'**
  String get jumpSectionPanes;

  /// No description provided for @jumpFooter.
  ///
  /// In en, this message translates to:
  /// **'Tap to open it here; press and hold to move the machine\'s focus too.'**
  String get jumpFooter;

  /// No description provided for @settingsColourScheme.
  ///
  /// In en, this message translates to:
  /// **'Colour scheme'**
  String get settingsColourScheme;

  /// No description provided for @themesTitle.
  ///
  /// In en, this message translates to:
  /// **'Colour scheme'**
  String get themesTitle;

  /// No description provided for @themesBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Herdr Pocket default'**
  String get themesBuiltIn;

  /// No description provided for @themesBuiltInNote.
  ///
  /// In en, this message translates to:
  /// **'The app\'s own colours'**
  String get themesBuiltInNote;

  /// No description provided for @themesSectionDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themesSectionDark;

  /// No description provided for @themesSectionLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themesSectionLight;

  /// No description provided for @themesFooter.
  ///
  /// In en, this message translates to:
  /// **'A scheme recolours the whole app, and the terminal uses that scheme\'s own twenty colours. A scheme carries its own light-or-dark: picking a dark scheme makes the app dark, regardless of the system setting.'**
  String get themesFooter;

  /// No description provided for @themesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the colour schemes.'**
  String get themesUnavailable;

  /// No description provided for @terminalAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach a file'**
  String get terminalAttach;

  /// No description provided for @terminalPanes.
  ///
  /// In en, this message translates to:
  /// **'Switch pane'**
  String get terminalPanes;

  /// No description provided for @terminalLayout.
  ///
  /// In en, this message translates to:
  /// **'Pane layout'**
  String get terminalLayout;

  /// No description provided for @terminalZoomFont.
  ///
  /// In en, this message translates to:
  /// **'Font {percent}%'**
  String terminalZoomFont(Object percent);

  /// No description provided for @terminalMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get terminalMore;

  /// No description provided for @terminalShowKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Show keyboard'**
  String get terminalShowKeyboard;

  /// No description provided for @terminalHideKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Hide keyboard'**
  String get terminalHideKeyboard;

  /// No description provided for @terminalAllKeys.
  ///
  /// In en, this message translates to:
  /// **'All keys'**
  String get terminalAllKeys;

  /// No description provided for @morePaneUnknown.
  ///
  /// In en, this message translates to:
  /// **'This pane\'s details have not arrived yet.'**
  String get morePaneUnknown;

  /// No description provided for @moreNotARepoHint.
  ///
  /// In en, this message translates to:
  /// **'Git changes need a live connection to be read.'**
  String get moreNotARepoHint;

  /// No description provided for @iconsTitle.
  ///
  /// In en, this message translates to:
  /// **'Icons, three ways'**
  String get iconsTitle;

  /// No description provided for @iconsVariantMono.
  ///
  /// In en, this message translates to:
  /// **'Mono'**
  String get iconsVariantMono;

  /// No description provided for @iconsVariantThemed.
  ///
  /// In en, this message translates to:
  /// **'Themed'**
  String get iconsVariantThemed;

  /// No description provided for @iconsVariantShowcase.
  ///
  /// In en, this message translates to:
  /// **'Fixed'**
  String get iconsVariantShowcase;

  /// No description provided for @iconsDock.
  ///
  /// In en, this message translates to:
  /// **'Dock'**
  String get iconsDock;

  /// No description provided for @iconsToolbar.
  ///
  /// In en, this message translates to:
  /// **'Terminal toolbar'**
  String get iconsToolbar;

  /// No description provided for @iconsMachine.
  ///
  /// In en, this message translates to:
  /// **'Machine entry, board top-left'**
  String get iconsMachine;

  /// No description provided for @iconsNote.
  ///
  /// In en, this message translates to:
  /// **'A comparison, not a feature. The same positions drawn three ways: Mono is what ships today; Themed uses this icon set with every colour taken from the active scheme, so it changes when the scheme does; Fixed is the set\'s own palette, which follows nothing.'**
  String get iconsNote;

  /// No description provided for @iconsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Two icons in this set have a single colour slot, so they stay flat in both coloured variants.'**
  String get iconsUnavailable;

  /// No description provided for @settingsIcons.
  ///
  /// In en, this message translates to:
  /// **'Icons'**
  String get settingsIcons;

  /// No description provided for @settingsIconsSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsIconsSystem;

  /// No description provided for @settingsIconsThemed.
  ///
  /// In en, this message translates to:
  /// **'Themed'**
  String get settingsIconsThemed;

  /// No description provided for @settingsTransferTitle.
  ///
  /// In en, this message translates to:
  /// **'File transfer'**
  String get settingsTransferTitle;

  /// No description provided for @settingsTransferEnabled.
  ///
  /// In en, this message translates to:
  /// **'Allow file transfer'**
  String get settingsTransferEnabled;

  /// No description provided for @settingsTransferEnabledFooter.
  ///
  /// In en, this message translates to:
  /// **'Turns on downloading files to the phone from the file browser. Needs a folder on the phone first.'**
  String get settingsTransferEnabledFooter;

  /// No description provided for @settingsDownloadDir.
  ///
  /// In en, this message translates to:
  /// **'Download folder'**
  String get settingsDownloadDir;

  /// No description provided for @settingsDownloadDirUnset.
  ///
  /// In en, this message translates to:
  /// **'Not selected'**
  String get settingsDownloadDirUnset;

  /// No description provided for @settingsDownloadDirHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to pick a folder. Chosen once, remembered across restarts.'**
  String get settingsDownloadDirHint;

  /// No description provided for @settingsDownloadDirRevoked.
  ///
  /// In en, this message translates to:
  /// **'This folder\'s permission is gone. Pick it again.'**
  String get settingsDownloadDirRevoked;

  /// No description provided for @fileActionDownload.
  ///
  /// In en, this message translates to:
  /// **'Download to phone'**
  String get fileActionDownload;

  /// No description provided for @fileActionDownloadHint.
  ///
  /// In en, this message translates to:
  /// **'Long press any file to download it too'**
  String get fileActionDownloadHint;

  /// No description provided for @downloadTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get downloadTitle;

  /// No description provided for @downloadPreparing.
  ///
  /// In en, this message translates to:
  /// **'Reading file info…'**
  String get downloadPreparing;

  /// No description provided for @downloadOf.
  ///
  /// In en, this message translates to:
  /// **'{name} · {done} / {total}'**
  String downloadOf(Object done, Object name, Object total);

  /// No description provided for @downloadUnknownSize.
  ///
  /// In en, this message translates to:
  /// **'{name} · {done} received'**
  String downloadUnknownSize(Object done, Object name);

  /// No description provided for @downloadCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get downloadCancel;

  /// No description provided for @downloadDone.
  ///
  /// In en, this message translates to:
  /// **'Saved to {dir}'**
  String downloadDone(Object dir);

  /// No description provided for @downloadDoneNoDir.
  ///
  /// In en, this message translates to:
  /// **'Saved to the phone'**
  String get downloadDoneNoDir;

  /// No description provided for @downloadFailedFeatureOff.
  ///
  /// In en, this message translates to:
  /// **'File transfer is off. Turn it on in Settings.'**
  String get downloadFailedFeatureOff;

  /// No description provided for @downloadFailedNoDir.
  ///
  /// In en, this message translates to:
  /// **'No download folder yet. Pick one in Settings.'**
  String get downloadFailedNoDir;

  /// No description provided for @downloadFailedRevoked.
  ///
  /// In en, this message translates to:
  /// **'The download folder\'s permission is gone. Pick it again.'**
  String get downloadFailedRevoked;

  /// No description provided for @downloadFailedSftp.
  ///
  /// In en, this message translates to:
  /// **'This host has no SFTP subsystem, so files cannot move.'**
  String get downloadFailedSftp;

  /// No description provided for @downloadFailedRemote.
  ///
  /// In en, this message translates to:
  /// **'The remote file could not be read.'**
  String get downloadFailedRemote;

  /// No description provided for @downloadFailedConnection.
  ///
  /// In en, this message translates to:
  /// **'The connection dropped before the transfer finished.'**
  String get downloadFailedConnection;

  /// No description provided for @downloadFailedUnknown.
  ///
  /// In en, this message translates to:
  /// **'The download failed.'**
  String get downloadFailedUnknown;

  /// No description provided for @downloadClose.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get downloadClose;

  /// No description provided for @pairTitle.
  ///
  /// In en, this message translates to:
  /// **'Device pairing'**
  String get pairTitle;

  /// No description provided for @pairScanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan the pairing code'**
  String get pairScanTitle;

  /// No description provided for @pairScanRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get pairScanRecommended;

  /// No description provided for @pairScanBody.
  ///
  /// In en, this message translates to:
  /// **'Run hdp pair on the computer, then point the camera at the QR code in the terminal.'**
  String get pairScanBody;

  /// No description provided for @pairScanStart.
  ///
  /// In en, this message translates to:
  /// **'Open camera'**
  String get pairScanStart;

  /// No description provided for @pairScanDenied.
  ///
  /// In en, this message translates to:
  /// **'The camera is unavailable or not permitted. Manual entry below works just as well.'**
  String get pairScanDenied;

  /// No description provided for @pairPasteTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter pairing information'**
  String get pairPasteTitle;

  /// No description provided for @pairPasteBody.
  ///
  /// In en, this message translates to:
  /// **'Paste the pairing string hdp pair printed. The scan and the paste are the same data — use whichever is easier.'**
  String get pairPasteBody;

  /// No description provided for @pairPastePlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Paste the pairing string…'**
  String get pairPastePlaceholder;

  /// No description provided for @pairConnect.
  ///
  /// In en, this message translates to:
  /// **'Pair and connect'**
  String get pairConnect;

  /// No description provided for @pairRetry.
  ///
  /// In en, this message translates to:
  /// **'Pair again'**
  String get pairRetry;

  /// No description provided for @pairStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'Paste a pairing string and tap Pair. The result appears here.'**
  String get pairStatusIdle;

  /// No description provided for @pairStatusConnect.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {host}…'**
  String pairStatusConnect(Object host);

  /// No description provided for @pairStatusExchange.
  ///
  /// In en, this message translates to:
  /// **'Installing this phone\'s key…'**
  String get pairStatusExchange;

  /// No description provided for @pairStatusVerify.
  ///
  /// In en, this message translates to:
  /// **'Verifying the new key…'**
  String get pairStatusVerify;

  /// No description provided for @pairStatusDone.
  ///
  /// In en, this message translates to:
  /// **'Paired: {name}'**
  String pairStatusDone(Object name);

  /// No description provided for @pairFailedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No pairing string has been pasted yet.'**
  String get pairFailedEmpty;

  /// No description provided for @pairFailedMalformed.
  ///
  /// In en, this message translates to:
  /// **'That does not look like a pairing string. It should be a long run of letters, digits, `-` and `_`.'**
  String get pairFailedMalformed;

  /// No description provided for @pairFailedUnsupported.
  ///
  /// In en, this message translates to:
  /// **'That pairing string comes from a newer hdp. Update hdp and try again.'**
  String get pairFailedUnsupported;

  /// No description provided for @pairFailedIncomplete.
  ///
  /// In en, this message translates to:
  /// **'That pairing string is incomplete.'**
  String get pairFailedIncomplete;

  /// No description provided for @pairFailedUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the machine. Check the address, and whether the phone is on the same network.'**
  String get pairFailedUnreachable;

  /// No description provided for @pairFailedMismatch.
  ///
  /// In en, this message translates to:
  /// **'This machine\'s host key does not match the one in the pairing code. The code may have expired, or something is in the middle.'**
  String get pairFailedMismatch;

  /// No description provided for @pairFailedBootstrap.
  ///
  /// In en, this message translates to:
  /// **'The pairing code has expired. Run hdp pair again on the computer.'**
  String get pairFailedBootstrap;

  /// No description provided for @pairFailedExchange.
  ///
  /// In en, this message translates to:
  /// **'The hdp on that machine could not install the key. Check that its version matches the install script.'**
  String get pairFailedExchange;

  /// No description provided for @pairFailedVerify.
  ///
  /// In en, this message translates to:
  /// **'The key was installed but does not connect. Run hdp list on the computer.'**
  String get pairFailedVerify;

  /// No description provided for @pairFailedUnknown.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed.'**
  String get pairFailedUnknown;

  /// No description provided for @hostPair.
  ///
  /// In en, this message translates to:
  /// **'Pair by QR code (recommended)'**
  String get hostPair;

  /// No description provided for @hostAddManually.
  ///
  /// In en, this message translates to:
  /// **'Add manually'**
  String get hostAddManually;

  /// No description provided for @hostPairHint.
  ///
  /// In en, this message translates to:
  /// **'Run hdp pair on the computer and scan its QR code — no address, port or key to type.'**
  String get hostPairHint;

  /// No description provided for @actionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// No description provided for @settingsUpdates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get settingsUpdates;

  /// No description provided for @settingsCheckUpdate.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get settingsCheckUpdate;

  /// No description provided for @settingsAutoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Check automatically'**
  String get settingsAutoUpdate;

  /// No description provided for @settingsAutoUpdateFooter.
  ///
  /// In en, this message translates to:
  /// **'Checks once each time the app starts. Off by default.'**
  String get settingsAutoUpdateFooter;

  /// No description provided for @settingsUpdatesFooter.
  ///
  /// In en, this message translates to:
  /// **'Updates come from GitHub Releases (weekitmo/herdr-pocket). Downloads follow the phone\'s HTTP proxy when one is set.'**
  String get settingsUpdatesFooter;

  /// No description provided for @updateSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Software update'**
  String get updateSheetTitle;

  /// No description provided for @updateChecking.
  ///
  /// In en, this message translates to:
  /// **'Asking GitHub…'**
  String get updateChecking;

  /// No description provided for @updateUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date — {version}'**
  String updateUpToDate(String version);

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available'**
  String updateAvailableTitle(String version);

  /// No description provided for @updateResumeHint.
  ///
  /// In en, this message translates to:
  /// **'{size} already downloaded — it will continue from there'**
  String updateResumeHint(String size);

  /// No description provided for @updateNotInstallable.
  ///
  /// In en, this message translates to:
  /// **'This platform cannot install an update itself. The release page has the file:'**
  String get updateNotInstallable;

  /// No description provided for @updateNotesTitle.
  ///
  /// In en, this message translates to:
  /// **'RELEASE NOTES'**
  String get updateNotesTitle;

  /// No description provided for @updateDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get updateDownload;

  /// No description provided for @updateResume.
  ///
  /// In en, this message translates to:
  /// **'Continue download'**
  String get updateResume;

  /// No description provided for @updateOpenRelease.
  ///
  /// In en, this message translates to:
  /// **'Open release page'**
  String get updateOpenRelease;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get updateDownloading;

  /// No description provided for @updateCancelDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel — keep what has arrived'**
  String get updateCancelDownload;

  /// No description provided for @updateCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled. What arrived is kept; press Download to continue.'**
  String get updateCancelled;

  /// No description provided for @updateReady.
  ///
  /// In en, this message translates to:
  /// **'{version} downloaded and checked'**
  String updateReady(String version);

  /// No description provided for @updateVerified.
  ///
  /// In en, this message translates to:
  /// **'Package name and signing key match the installed app, so it can be installed over it.'**
  String get updateVerified;

  /// No description provided for @updateNeedsPermission.
  ///
  /// In en, this message translates to:
  /// **'Android has not allowed this app to install packages yet.'**
  String get updateNeedsPermission;

  /// No description provided for @updateAllowInstall.
  ///
  /// In en, this message translates to:
  /// **'Allow installing apps'**
  String get updateAllowInstall;

  /// No description provided for @updateInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get updateInstall;

  /// No description provided for @updateInstallFootnote.
  ///
  /// In en, this message translates to:
  /// **'Android will show its own confirmation. The app restarts into the new version afterwards.'**
  String get updateInstallFootnote;

  /// No description provided for @updateFailedOffline.
  ///
  /// In en, this message translates to:
  /// **'Could not reach GitHub. Check the connection.'**
  String get updateFailedOffline;

  /// No description provided for @updateFailedProxy.
  ///
  /// In en, this message translates to:
  /// **'The proxy at {address} did not answer.'**
  String updateFailedProxy(String address);

  /// No description provided for @updateFailedProxyUnknown.
  ///
  /// In en, this message translates to:
  /// **'A proxy is configured but did not answer.'**
  String get updateFailedProxyUnknown;

  /// No description provided for @updateFailedTls.
  ///
  /// In en, this message translates to:
  /// **'The HTTPS certificate was rejected. An intercepting proxy needs its CA trusted by the system; this app does not trust user-installed CAs.'**
  String get updateFailedTls;

  /// No description provided for @updateFailedTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Connected, then nothing arrived for a minute.'**
  String get updateFailedTimedOut;

  /// No description provided for @updateFailedRateLimited.
  ///
  /// In en, this message translates to:
  /// **'GitHub\'s anonymous limit is used up (60 requests an hour). Try again later.'**
  String get updateFailedRateLimited;

  /// No description provided for @updateFailedHttp.
  ///
  /// In en, this message translates to:
  /// **'GitHub returned an error.'**
  String get updateFailedHttp;

  /// No description provided for @updateFailedPayload.
  ///
  /// In en, this message translates to:
  /// **'The answer was not what was expected — a Wi-Fi sign-in page can look like this.'**
  String get updateFailedPayload;

  /// No description provided for @updateFailedNoRelease.
  ///
  /// In en, this message translates to:
  /// **'No release is published for this app yet.'**
  String get updateFailedNoRelease;

  /// No description provided for @updateFailedNoAsset.
  ///
  /// In en, this message translates to:
  /// **'That release has no build for this device\'s CPU.'**
  String get updateFailedNoAsset;

  /// No description provided for @updateFailedStorage.
  ///
  /// In en, this message translates to:
  /// **'Could not write the file to the phone. Out of space?'**
  String get updateFailedStorage;

  /// No description provided for @updateFailedChecksum.
  ///
  /// In en, this message translates to:
  /// **'The file did not match the release\'s checksum. It has been deleted; retrying downloads it again.'**
  String get updateFailedChecksum;

  /// No description provided for @updateFailedSize.
  ///
  /// In en, this message translates to:
  /// **'The download ended with the wrong number of bytes. It has been deleted.'**
  String get updateFailedSize;

  /// No description provided for @updateFailedInstallBlocked.
  ///
  /// In en, this message translates to:
  /// **'Android is not letting this app install packages.'**
  String get updateFailedInstallBlocked;

  /// No description provided for @updateFailedSignature.
  ///
  /// In en, this message translates to:
  /// **'This APK is signed with a different key than the installed app, so Android would refuse it. The copy on this phone is probably one built locally with the debug key — installing this one means uninstalling first, WHICH DELETES THE SAVED MACHINES AND SSH KEYS.'**
  String get updateFailedSignature;

  /// No description provided for @updateFailedWrongPackage.
  ///
  /// In en, this message translates to:
  /// **'That file is not Herdr Pocket.'**
  String get updateFailedWrongPackage;

  /// No description provided for @updateFailedVersionOld.
  ///
  /// In en, this message translates to:
  /// **'The file is older than what is installed, so Android would refuse it.'**
  String get updateFailedVersionOld;

  /// No description provided for @updateFailedUnknown.
  ///
  /// In en, this message translates to:
  /// **'The update failed.'**
  String get updateFailedUnknown;

  /// No description provided for @updateRowChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get updateRowChecking;

  /// No description provided for @updateRowAvailable.
  ///
  /// In en, this message translates to:
  /// **'Version {version} available'**
  String updateRowAvailable(String version);

  /// No description provided for @updateRowUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get updateRowUpToDate;

  /// No description provided for @updateRowFailed.
  ///
  /// In en, this message translates to:
  /// **'Last check failed'**
  String get updateRowFailed;

  /// No description provided for @updateRowNever.
  ///
  /// In en, this message translates to:
  /// **'Never checked'**
  String get updateRowNever;

  /// No description provided for @updateToast.
  ///
  /// In en, this message translates to:
  /// **'Herdr Pocket {version} is available — see Settings'**
  String updateToast(String version);

  /// No description provided for @updateUrlCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get updateUrlCopied;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
