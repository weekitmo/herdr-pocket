// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Herdr Pocket';

  @override
  String get boardTitle => '智能体';

  @override
  String boardNeedsYouCount(int count) {
    return '有 $count 个待审批';
  }

  @override
  String get boardEmptyTitle => '还没有智能体';

  @override
  String get boardEmptyBody => '在你机器的 herdr 里启动一个智能体，它就会出现在这里。';

  @override
  String get groupNeedsYou => '审批';

  @override
  String get groupStopped => '已停止';

  @override
  String get groupUnrecognised => '其他';

  @override
  String get groupWorking => '进行中';

  @override
  String get groupIdle => '空闲';

  @override
  String get groupUnrecognisedHint => '当前版本读不懂这个智能体的状态。请更新应用，或检查守护进程。';

  @override
  String get groupArchived => '已归档';

  @override
  String get statusIdle => '空闲';

  @override
  String get statusWorking => '进行中';

  @override
  String get statusBlocked => '待审批';

  @override
  String get statusDone => '已完成';

  @override
  String get statusUnknown => '未知';

  @override
  String get terminalTitle => '终端';

  @override
  String get terminalReadOnly => '只读';

  @override
  String get terminalReadOnlyHint => '另一个客户端正在控制这个终端。';

  @override
  String get terminalConnecting => '连接中…';

  @override
  String get terminalDisconnected => '已断开';

  @override
  String get terminalExited => '进程已退出';

  @override
  String get actionPrompt => '回复';

  @override
  String get actionSend => '发送';

  @override
  String get actionCancel => '取消';

  @override
  String get actionRetry => '重试';

  @override
  String get actionReconnect => '重连';

  @override
  String get actionConnect => '连接';

  @override
  String get actionDisconnect => '断开';

  @override
  String get actionApprove => '批准';

  @override
  String get hostsTitle => '机器';

  @override
  String get hostAdd => '添加机器';

  @override
  String get hostEdit => '编辑机器';

  @override
  String get hostLabel => '名称';

  @override
  String get hostAddress => '主机';

  @override
  String get hostPort => '端口';

  @override
  String get hostUsername => '用户名';

  @override
  String get hostAuthMethod => '认证方式';

  @override
  String get hostAuthPassword => '密码';

  @override
  String get hostAuthKey => '私钥';

  @override
  String get hostAuthAgent => 'SSH Agent';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsAppearance => '外观';

  @override
  String get settingsTheme => '主题';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsGlass => '液态玻璃';

  @override
  String get settingsSafety => '安全边界';

  @override
  String get safetyDefault => '默认';

  @override
  String get safetyOn => '强制开启';

  @override
  String get safetyOff => '强制关闭';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageSystem => '跟随系统';

  @override
  String get settingsTextSize => '文字大小';

  @override
  String get settingsTerminalFontSize => '终端字号';

  @override
  String get settingsAbout => '关于';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsDiagnostics => '诊断';

  @override
  String get connectionStageConnecting => '正在连接…';

  @override
  String get connectionStageVerifying => '正在检验…';

  @override
  String get connectionStageLastAttempt => '正在做最后的尝试…';

  @override
  String connectionRetryAttempt(int attempt, int max) {
    return '正在重试 $attempt/$max…';
  }

  @override
  String get connectionFailed => '连接失败';

  @override
  String connectionFailedAfterRetries(int count) {
    return '试了 $count 次都没连上';
  }

  @override
  String get connectionStateOnline => '在线';

  @override
  String get connectionStateOffline => '未连接';

  @override
  String get connectionStateAuthFailed => '认证失败';

  @override
  String get connectionStateHostKeyChanged => '主机密钥已变更';

  @override
  String get connectionStateHostKeyChangedBody =>
      '这台机器的密钥与你批准过的不一样。可能是它被重装了，也可能有人在中间截获连接。';

  @override
  String get errorForwardingRefused =>
      '这台机器的 SSH 服务拒绝转发到 herdr 的 socket。需要在它的 sshd 配置里打开 AllowStreamLocalForwarding，然后重新连接。';

  @override
  String get errorGeneric => '出了点问题';

  @override
  String get errorHerdrNotFound => '这台机器上没有找到 herdr';

  @override
  String get errorHerdrNotFoundBody => '请在该机器上安装 herdr 并确保它在 PATH 中，然后重新连接。';

  @override
  String get errorTerminalUnsupported => '这个 herdr 版本太旧，不支持实时终端';

  @override
  String get errorTerminalUnsupportedBody =>
      '需要 herdr 0.9.0 或更高版本。请更新机器上的 herdr 后重新连接。';

  @override
  String get hostKeyNewTitle => '新机器';

  @override
  String get hostKeyNewBody =>
      'Herdr Pocket 之前没有连过这台机器。继续之前，请确认下面的指纹与机器上显示的一致。';

  @override
  String get hostKeyChangedTitle => '主机密钥已变更';

  @override
  String get hostKeyChangedBody =>
      '这台机器出示的密钥与你批准过的不一样。可能是机器被重装了，也可能有人在中间截获连接。只有在你确定变更原因时才继续。';

  @override
  String get hostKeyFingerprint => '指纹';

  @override
  String get hostKeyPreviously => '此前已批准';

  @override
  String get hostKeyApproveAndRemember => '信任并记住';

  @override
  String get hostKeyApproveOnce => '仅信任一次';

  @override
  String get hostKeyReject => '取消';

  @override
  String get hostKeyShowDetails => '详情';

  @override
  String get hostsNoHosts => '还没有机器';

  @override
  String get hostsNoHostsBody => '添加运行 herdr 的机器，它上面的智能体就会出现在看板上。';

  @override
  String get hostSave => '保存';

  @override
  String get hostDelete => '删除';

  @override
  String get hostSshKey => '私钥';

  @override
  String get hostSshKeyHint => '粘贴 OpenSSH 私钥';

  @override
  String get hostPasswordHint => '密码';

  @override
  String get hostUsernameHint => '用户名';

  @override
  String get hostLabelHint => '工作笔记本';

  @override
  String get hostHostHint => '10.0.0.5 或 my-host.local';

  @override
  String get hostConnect => '连接';

  @override
  String get hostConnectNow => '使用这台机器';

  @override
  String get hostMissing => '请填写主机和用户名';

  @override
  String get hostInvalidPort => '端口必须在 1 到 65535 之间';

  @override
  String get hostSecretNote => '保存在本机密钥库中，不会写进主机列表。';

  @override
  String terminalScrolledBack(Object lines) {
    return '已回看 $lines 行 — 点按回到实时';
  }

  @override
  String terminalScrolledBackOldest(int lines) {
    return '已到最早 · 已回看 $lines 行 — 点按回到实时';
  }

  @override
  String get terminalSelectionHint => '选择文本';

  @override
  String get copyAction => '复制';

  @override
  String get settingsNotifications => '通知';

  @override
  String get settingsNotificationsFooter => '应用运行期间，有智能体开始等你回答时发出通知。';

  @override
  String get navBack => '返回';

  @override
  String get navBoard => '看板';

  @override
  String get navWorkspaces => '工作区';

  @override
  String get navSettings => '设置';

  @override
  String get workspacesTitle => '工作区';

  @override
  String get workspacesEmptyTitle => '还没有工作区';

  @override
  String get workspacesEmptyBody => '在机器的 herdr 里创建一个工作区，它就会出现在这里。';

  @override
  String workspacesCounts(int tabs, int panes) {
    return '$tabs 个标签 · $panes 个窗格';
  }

  @override
  String get workspacesTabsLabel => '标签';

  @override
  String get workspacesPanesLabel => '窗格';

  @override
  String get workspacesCurrent => '当前焦点';

  @override
  String get workspacesFocusPane => '把焦点切到这里';

  @override
  String get workspacesFocusTab => '聚焦这个标签';

  @override
  String get workspacesFocusWorkspace => '聚焦这个工作区';

  @override
  String get workspacesFocusDone => '焦点已切换';

  @override
  String get workspacesFocusFailed => '切换焦点失败';

  @override
  String get workspacesNoPanes => '这个标签没有窗格';

  @override
  String get paneSwitcherTitle => '切换窗格';

  @override
  String get paneSwitcherCurrent => '当前窗格';

  @override
  String get paneSwitcherOtherTabs => '同工作区的其他标签';

  @override
  String get paneSwitcherRefresh => '刷新列表';

  @override
  String get filesTitle => '文件';

  @override
  String get filePreviewLoading => '正在读取…';

  @override
  String get filePreviewEmpty => '空文件';

  @override
  String get filePreviewBinary => '二进制文件，没法当文本看。';

  @override
  String get filePreviewFailed => '读不到这个文件';

  @override
  String filePreviewTruncated(int kb) {
    return '只显示前 $kb KB';
  }

  @override
  String filePreviewLines(int count) {
    return '$count 行';
  }

  @override
  String get gitTitle => 'Git 改动';

  @override
  String get gitClean => '工作区干净';

  @override
  String get gitStaged => '已暂存';

  @override
  String get gitUnstaged => '未暂存';

  @override
  String get gitUntracked => '未跟踪';

  @override
  String get gitConflicted => '冲突';

  @override
  String gitAheadBehind(int ahead, int behind) {
    return '领先 $ahead · 落后 $behind';
  }

  @override
  String get gitNotARepo => '这个目录不在 git 仓库里';

  @override
  String gitChangesCount(int count) {
    return '$count 处改动';
  }

  @override
  String get gitLoading => '正在读取 git 状态…';

  @override
  String get gitDiffEmpty => '没有可显示的差异';

  @override
  String get gitUnavailable => '这台机器上没有 git';

  @override
  String get actionRefresh => '刷新';

  @override
  String get actionClose => '关闭';

  @override
  String get actionOpen => '打开';

  @override
  String get settingsAutoConnect => '启动时连接';

  @override
  String get layoutTitle => '分屏';

  @override
  String get layoutEmpty => '这个标签页只有一个窗格';

  @override
  String get layoutLoading => '正在打开分屏…';

  @override
  String get layoutFollow => '跟随这里的焦点';

  @override
  String get layoutZoomed => '这个标签页处于缩放状态，只显示一个窗格';

  @override
  String get settingsBehaviour => '行为';

  @override
  String get settingsTextSizeApp => '界面文字';

  @override
  String get settingsDaemon => '守护进程';

  @override
  String get settingsAppVersion => '应用版本';

  @override
  String get hostCurrent => '当前';

  @override
  String get hostsFooter => '点按切换到这台机器；长按可编辑或删除。';

  @override
  String get settingsKeys => '快捷按键';

  @override
  String get settingsComposer => '终端聊天窗';

  @override
  String get settingsComposerNote => '在终端底部显示聊天窗。';

  @override
  String settingsKeysCount(int count) {
    return '$count 个按键';
  }

  @override
  String get settingsKeysFooter => '终端下方那一排按键。点一下选要哪些。';

  @override
  String get keysTitle => '快捷按键';

  @override
  String get keysFooter =>
      'Ctrl、Alt、Shift 是粘滞的：按下后等你的下一个按键，手机自带键盘上敲的也算。Ctrl 再敲 d 就是 Ctrl+D。';

  @override
  String get keysReset => '恢复默认';

  @override
  String get keysEmpty => '一个都没选';

  @override
  String get keysModifier => '修饰键 —— 等下一个按键';

  @override
  String get keysCopyHint => '复制和粘贴不是按键。终端里的 Ctrl+C 是 SIGINT，那是 C-c 键。';

  @override
  String get askTitle => '它在问你';

  @override
  String get askLoading => '正在读它的屏幕…';

  @override
  String get askFailedTitle => '读不到它的屏幕';

  @override
  String get askRetry => '再试一次';

  @override
  String get askUnclearNote => '看不出它在问什么。下面是它的屏幕内容——这种时候请去终端回答，这里不猜。';

  @override
  String get askTruncatedNote => '屏幕内容被截断了，只显示读得到的那部分。';

  @override
  String get askItsScreen => '它的屏幕';

  @override
  String get askSend => '发送';

  @override
  String get askSendTyped => '只输入';

  @override
  String get askTypedNote => '文字只会输入进去，不会提交 —— Enter 你自己按。';

  @override
  String get askSendFailed => '没发出去';

  @override
  String get askSent => '已交给 herdr';

  @override
  String get askSentNote => '它接下来做什么，看板上会更新。';

  @override
  String get askBackToBoard => '回看板';

  @override
  String get askOpenTerminal => '去终端回答';

  @override
  String get askStaleChanged => '它在你读的时候动过了，所以没有发送。重新打开看看它现在问的是什么。';

  @override
  String get askStaleGone => '这个窗格已经不在了。';

  @override
  String get askRefusedEmpty => '没有内容可发。';

  @override
  String get askRefusedMultiline => '多行文字在这里会被当成提交，所以没有发。';

  @override
  String get askFailedBlocked => '它正卡在菜单里，得去终端回答。';

  @override
  String get askFooter => '发送前会重新读一次它的屏幕。如果它已经变了，就不会发出去。';

  @override
  String get launchTitle => '新建';

  @override
  String get launchWhere => '在哪里';

  @override
  String get launchDirectory => '目录';

  @override
  String get launchDirectoryNote => '在机器上的哪个目录工作。';

  @override
  String get launchWorktree => '用隔离的 worktree';

  @override
  String get launchWorktreeNote =>
      '开一个新的 git worktree 并切到自己的分支，agent 动不到你正在看的东西。';

  @override
  String get launchBranch => '分支';

  @override
  String get launchBranchNote => '留空则由 herdr 决定。';

  @override
  String get launchNotARepo => '这个目录不在 git 仓库里，只能新建普通工作区。';

  @override
  String get launchAgent => '起哪个智能体';

  @override
  String get launchLoadingAgents => '正在问 herdr 有哪些智能体…';

  @override
  String get launchNoAgents => 'herdr 没有报告任何可用的智能体。';

  @override
  String get launchUnavailableNote => '灰掉的那些是这台机器上没装的。';

  @override
  String get launchName => '叫什么';

  @override
  String get launchNameLabel => '名字';

  @override
  String get launchNameNote => '在看板和终端标题里用这个名字。';

  @override
  String get launchCreating => '正在创建…';

  @override
  String get launchGo => '创建并启动';

  @override
  String get launchFooter => '会在机器上新建一个工作区，然后在它的窗格里启动这个智能体。';

  @override
  String get launchFailedRepo => '这个目录不在 git 仓库里。把「用隔离的 worktree」关掉再试。';

  @override
  String get launchFailedNotReady => '窗格还没准备好接智能体。稍等一下再试。';

  @override
  String get launchFailedName => '这个名字已经被占用了，换一个。';

  @override
  String get launchFailedNoPane => 'herdr 建好了工作区，但没有给出窗格 id。';

  @override
  String get launchFailedGeneric => '没能启动';

  @override
  String get launchMode => '在哪儿起';

  @override
  String get launchModePane => '用已有的窗格';

  @override
  String get launchModePaneNote => '不开新工作区，直接在一个空闲的 shell 窗格里起。';

  @override
  String get launchPickPane => '选窗格';

  @override
  String get launchLoadingPanes => '正在看每个窗格里跑着什么…';

  @override
  String get launchNoLaunchablePanes => '没有可以直接起 agent 的窗格。要起新的，就把上面的开关关掉。';

  @override
  String launchBlockedAlready(String holder) {
    return '已经有 $holder 在里面了';
  }

  @override
  String launchBlockedBusy(String holder) {
    return '$holder 占着前台';
  }

  @override
  String get launchBlockedUnknown => '问不到它里面在跑什么';

  @override
  String get launchBlockedGone => '窗格不在了';

  @override
  String get attachTitle => '发个文件给它';

  @override
  String get attachClipboard => '把剪贴板文字存成文件';

  @override
  String get attachFile => '从手机选文件';

  @override
  String get attachGallery => '从相册选图';

  @override
  String get attachCamera => '拍一张';

  @override
  String get attachClipboardEmpty => '剪贴板里没有文字。';

  @override
  String get attachDone => '已上传，路径已输入（按回车发给它）';

  @override
  String get attachFailed => '没上传成功';

  @override
  String get attachTooLarge => '这个文件太大了。';

  @override
  String get attachEmpty => '没有内容可上传。';

  @override
  String get attachNoHome => '问不到这台机器的 home 目录，不知道往哪放。';

  @override
  String get attachNoDirectory => '在机器上建不了上传目录。';

  @override
  String get attachUnavailable => '当前连接不支持传文件。';

  @override
  String get jumpTitle => '跳转';

  @override
  String get jumpEmpty => '机器上还没有窗格。';

  @override
  String get jumpSectionPanes => '空窗格';

  @override
  String get jumpFooter => '点一下在这里打开；长按连机器上的焦点一起移过去。';

  @override
  String get settingsColourScheme => '配色方案';

  @override
  String get themesTitle => '配色方案';

  @override
  String get themesBuiltIn => 'Herdr Pocket 默认';

  @override
  String get themesBuiltInNote => '应用自带的颜色';

  @override
  String get themesSectionDark => '深色';

  @override
  String get themesSectionLight => '浅色';

  @override
  String get themesFooter =>
      '选一套方案会给整个应用换色，终端也用它自己的那 20 色。方案自带明暗——挑深色方案就是深色，不跟系统的亮暗走。';

  @override
  String get themesUnavailable => '读不到配色方案。';

  @override
  String get terminalAttach => '上传文件';

  @override
  String get terminalPanes => '切换窗格';

  @override
  String get terminalLayout => '分屏布局';

  @override
  String terminalZoomFont(Object percent) {
    return '字号 $percent%';
  }

  @override
  String get terminalMore => '更多';

  @override
  String get terminalShowKeyboard => '打开键盘';

  @override
  String get terminalHideKeyboard => '收起键盘';

  @override
  String get terminalAllKeys => '全部按键';

  @override
  String get composerOpen => '聊天窗';

  @override
  String get composerPlaceholder => '请输入';

  @override
  String get composerSend => '发送';

  @override
  String get composerAttach => '上传手机上的图片或文件';

  @override
  String get composerCommands => '技能与 MCP';

  @override
  String get composerSectionSkills => '技能';

  @override
  String get composerSectionMcp => 'MCP';

  @override
  String get composerSectionFiles => '文件';

  @override
  String get composerReading => '正在读取远端…';

  @override
  String get composerNothingFound => '这台机器上没有找到 skills 或 MCP。';

  @override
  String get composerEmptyDir => '这个目录里没有可引用的文件。';

  @override
  String get composerNoMatch => '没有匹配的项。';

  @override
  String get composerNoSession => '终端未连接，先重连再发。';

  @override
  String composerRemoveAttachment(String name) {
    return '移除附件 $name';
  }

  @override
  String get composerUnreadable => '读取失败：';

  @override
  String get composerUnavailable => '这条连接读不了远端文件。';

  @override
  String get morePaneUnknown => '还没读到这个窗格的信息。';

  @override
  String get moreNotARepoHint => 'Git 改动要等连上以后才问得到。';

  @override
  String get iconsTitle => '图标试验';

  @override
  String get iconsVariantMono => '单色';

  @override
  String get iconsVariantThemed => '主题色';

  @override
  String get iconsVariantShowcase => '彩色';

  @override
  String get iconsDock => '底部导航';

  @override
  String get iconsToolbar => '终端顶栏';

  @override
  String get iconsMachine => '看板左上角的机器入口';

  @override
  String get iconsNote =>
      '这是个对照页，不是成品。同一个位置三种画法并排给你看——单色是现在的样子；主题色是同一套图标但颜色全部取自当前配色方案，换主题会跟着变；彩色是图标原厂的固定配色，不跟主题走。';

  @override
  String get iconsUnavailable => '这套图标有两个只有单色槽，所以主题色/彩色下它们仍然是单色。';

  @override
  String get settingsIcons => '图标';

  @override
  String get settingsIconsSystem => '系统';

  @override
  String get settingsIconsThemed => '主题色';

  @override
  String get settingsTransferTitle => '文件传输';

  @override
  String get settingsTransferEnabled => '允许文件传输';

  @override
  String get settingsTransferEnabledFooter =>
      '开启后才能在文件浏览里把文件下载到手机。需要先选一个手机上的目录。';

  @override
  String get settingsDownloadDir => '下载目录';

  @override
  String get settingsDownloadDirUnset => '未选择';

  @override
  String get settingsDownloadDirHint => '点这里选一个目录。选一次就记住，重启也不丢。';

  @override
  String get settingsDownloadDirRevoked => '这个目录的授权已失效，请重新选择。';

  @override
  String get fileActionDownload => '下载到手机';

  @override
  String get fileActionDownloadHint => '长按任意文件也可以下载';

  @override
  String get downloadTitle => '下载文件';

  @override
  String get downloadPreparing => '正在读取文件信息…';

  @override
  String downloadOf(Object done, Object name, Object total) {
    return '$name · $done / $total';
  }

  @override
  String downloadUnknownSize(Object done, Object name) {
    return '$name · 已收 $done';
  }

  @override
  String get downloadCancel => '取消';

  @override
  String downloadDone(Object dir) {
    return '已保存到 $dir';
  }

  @override
  String get downloadDoneNoDir => '已保存到手机';

  @override
  String get downloadFailedFeatureOff => '文件传输没开。到设置里打开它。';

  @override
  String get downloadFailedNoDir => '还没选下载目录。到设置里选一个。';

  @override
  String get downloadFailedRevoked => '下载目录的授权失效了，请重新选一个。';

  @override
  String get downloadFailedSftp => '这台机器没开 SFTP 子系统，传不了文件。';

  @override
  String get downloadFailedRemote => '远端读不了这个文件。';

  @override
  String get downloadFailedConnection => '连接断了，文件没传完。';

  @override
  String get downloadFailedUnknown => '下载失败了。';

  @override
  String get downloadClose => '完成';

  @override
  String get pairTitle => '设备认证';

  @override
  String get pairScanTitle => '扫描配对码';

  @override
  String get pairScanRecommended => '推荐';

  @override
  String get pairScanBody => '在电脑上运行 hdp pair，用相机对准终端里的二维码。';

  @override
  String get pairScanStart => '打开相机';

  @override
  String get pairScanDenied => '相机不可用或没有授权。用下面的手动输入一样可以配对。';

  @override
  String get pairPasteTitle => '手动输入配对信息';

  @override
  String get pairPasteBody => '粘贴 hdp pair 打印的配对字符串。扫码和粘贴是同一份数据，哪个方便用哪个。';

  @override
  String get pairPastePlaceholder => '粘贴配对字符串…';

  @override
  String get pairConnect => '配对并连接';

  @override
  String get pairRetry => '再配一次';

  @override
  String get pairStatusIdle => '粘贴配对字符串后点击配对，结果会显示在这里。';

  @override
  String pairStatusConnect(Object host) {
    return '正在连接 $host…';
  }

  @override
  String get pairStatusExchange => '正在安装这台手机的密钥…';

  @override
  String get pairStatusVerify => '正在验证新密钥…';

  @override
  String pairStatusDone(Object name) {
    return '已配对：$name';
  }

  @override
  String get pairFailedEmpty => '还没有粘贴配对字符串。';

  @override
  String get pairFailedMalformed => '这不像是一个配对字符串。它应该是一长串字母、数字、`-` 和 `_`。';

  @override
  String get pairFailedUnsupported => '这个配对字符串来自更新版本的 hdp，请先升级 hdp 再试。';

  @override
  String get pairFailedIncomplete => '这个配对字符串不完整。';

  @override
  String get pairFailedUnreachable => '连不上这台机器。检查地址，以及手机和它是否在同一网络。';

  @override
  String get pairFailedMismatch => '这台机器的主机密钥和配对码里写的不一致。可能是配对码过期了，也可能有人在中间。';

  @override
  String get pairFailedBootstrap => '配对码已经失效。到电脑上重新运行 hdp pair。';

  @override
  String get pairFailedExchange => '这台机器上的 hdp 没能装好密钥。确认它的版本和安装脚本一致。';

  @override
  String get pairFailedVerify => '密钥装上了，但用它连不通。到电脑上运行 hdp list 看看。';

  @override
  String get pairFailedUnknown => '配对失败。';

  @override
  String get hostPair => '扫码配对（推荐）';

  @override
  String get hostAddManually => '手动添加';

  @override
  String get hostPairHint => '在电脑上运行 hdp pair，用相机扫它的二维码，省掉手填地址和密钥。';

  @override
  String get actionDone => '完成';

  @override
  String get settingsUpdates => '更新';

  @override
  String get settingsCheckUpdate => '检查更新';

  @override
  String get settingsAutoUpdate => '自动检查更新';

  @override
  String get settingsAutoUpdateFooter => '每次启动应用时检查一次。默认关闭。';

  @override
  String get settingsUpdatesFooter =>
      '更新来自 GitHub Releases（weekitmo/herdr-pocket）。下载会跟随手机设置的 HTTP 代理。';

  @override
  String get updateSheetTitle => '软件更新';

  @override
  String get updateChecking => '正在向 GitHub 查询…';

  @override
  String updateUpToDate(String version) {
    return '已是最新版本 $version';
  }

  @override
  String updateAvailableTitle(String version) {
    return '有新版本 $version';
  }

  @override
  String updateResumeHint(String size) {
    return '已下载 $size，会接着下';
  }

  @override
  String get updateNotInstallable => '这台设备不支持应用内安装，请到发布页自行下载：';

  @override
  String get updateNotesTitle => '更新说明';

  @override
  String get updateDownload => '下载';

  @override
  String get updateResume => '继续下载';

  @override
  String get updateOpenRelease => '打开发布页';

  @override
  String get updateDownloading => '下载中';

  @override
  String get updateCancelDownload => '取消（保留已下载部分）';

  @override
  String get updateCancelled => '已取消。已下载的部分保留着，按「下载」可以接着下。';

  @override
  String updateReady(String version) {
    return '已下载 $version 并校验通过';
  }

  @override
  String get updateVerified => '包名与签名跟已装版本一致，可以直接覆盖安装。';

  @override
  String get updateNeedsPermission => '系统还没允许本应用安装应用。';

  @override
  String get updateAllowInstall => '去允许安装';

  @override
  String get updateInstall => '安装';

  @override
  String get updateInstallFootnote => '系统会弹出自己的确认框。装完后应用会重启到新版本。';

  @override
  String get updateFailedOffline => '连不上 GitHub，检查一下网络。';

  @override
  String updateFailedProxy(String address) {
    return '代理 $address 没有响应。';
  }

  @override
  String get updateFailedProxyUnknown => '系统配了代理，但它没有响应。';

  @override
  String get updateFailedTls => 'HTTPS 证书被拒绝。解密型代理需要系统信任它的 CA，而本应用不信任用户安装的 CA。';

  @override
  String get updateFailedTimedOut => '连上了，但一分钟没有任何数据。';

  @override
  String get updateFailedRateLimited => 'GitHub 的匿名额度用完了（每小时 60 次），过一会儿再试。';

  @override
  String get updateFailedHttp => 'GitHub 返回了错误。';

  @override
  String get updateFailedPayload => '返回的内容不是预期格式（公共 Wi-Fi 的登录页会这样）。';

  @override
  String get updateFailedNoRelease => '这个应用还没有发布任何版本。';

  @override
  String get updateFailedNoAsset => '这个版本没有适配本机 CPU 的安装包。';

  @override
  String get updateFailedStorage => '写不进手机存储，可能是空间不够。';

  @override
  String get updateFailedChecksum => '文件校验失败，已经删掉了；重试会重新下载。';

  @override
  String get updateFailedSize => '下载的字节数不对，已经删掉了。';

  @override
  String get updateFailedInstallBlocked => '系统不允许本应用安装应用。';

  @override
  String get updateFailedSignature =>
      '这个安装包和已装版本的签名不同，系统会拒绝安装。手机上这个多半是你自己构建的 debug 包；要装这个就得先卸载，而卸载会删掉已保存的机器和 SSH 密钥。';

  @override
  String get updateFailedWrongPackage => '这个安装包不是 Herdr Pocket。';

  @override
  String get updateFailedVersionOld => '这个包比已装的版本旧，系统会拒绝安装。';

  @override
  String get updateFailedUnknown => '更新失败。';

  @override
  String get updateRowChecking => '检查中…';

  @override
  String updateRowAvailable(String version) {
    return '有新版本 $version';
  }

  @override
  String get updateRowUpToDate => '已是最新';

  @override
  String get updateRowFailed => '上次检查失败';

  @override
  String get updateRowNever => '还没检查过';

  @override
  String updateToast(String version) {
    return '有新版本 $version，可在设置里更新';
  }

  @override
  String get updateUrlCopied => '链接已复制';

  @override
  String get shellConnecting => '正在打开终端…';

  @override
  String get shellConnectingBody => '正在通过 SSH 连接并申请一个终端。';

  @override
  String get shellFailed => '打不开终端';

  @override
  String get shellEnded => '会话已结束';

  @override
  String get shellExitUnknown => '远端没有报告退出码。';

  @override
  String get shellReopen => '重新打开';

  @override
  String get shellBackToLive => '回到最新';

  @override
  String shellExitCode(int code) {
    return '进程退出码 $code。';
  }

  @override
  String get shellOpen => '打开终端';

  @override
  String get shellPickMachine => '在哪台机器上打开终端？';

  @override
  String get shellNoMachines => '还没有保存任何机器。先到「机器」里添一台，配好 SSH 之后就能在这里开终端了。';

  @override
  String get shellCommandTitle => '终端命令';

  @override
  String get shellCommandLabel => '打开时运行';

  @override
  String get shellCommandNote => '这条命令在远端 PTY 里直接执行，不经过登录 shell。';

  @override
  String get shellCommandPlaceholder => '留空 = 登录 shell';

  @override
  String get shellCommandRestore => '恢复默认命令';

  @override
  String get shellCommandFooter =>
      '默认是 tmux new -A -s herdr-pocket：有就接上、没有就新建，所以关掉 App 再回来，看到的是同一个会话和它的回滚缓冲。\n\n⚠️ 这条命令跑在非登录 shell 里，PATH 比你平时用的窄——macOS 的 /opt/homebrew/bin、Linux 的 ~/.local/bin 通常都不在里面，于是 tmux 会以退出码 127（command not found）结束。装在非默认位置的命令请写全路径（如 /opt/homebrew/bin/tmux）。留空则直接开登录 shell，PATH 就是你熟悉的那个。';

  @override
  String get shellScrollbackTitle => '回滚行数';

  @override
  String get shellScrollbackLabel => '保留多少行';

  @override
  String get shellScrollbackNote => '终端缓冲区里留着的历史。往上拖就能读到。';

  @override
  String shellScrollbackFooter(int min, int max) {
    return '这一个数字同时是「能往回读多久」和「一个会话占多少内存」——每一行是一整行的格子，不是一行文本。取值范围 $min 到 $max，改完下次打开终端生效。';
  }

  @override
  String shellScrollbackLines(int lines) {
    return '$lines 行';
  }
}
