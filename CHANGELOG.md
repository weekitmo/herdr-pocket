# Changelog / 更新日志

[中文](#中文) · [English](#english)

版本与版本之间**改了什么**，按时间倒序排在这里；每个版本末尾的 Full Changelog 链接是完整的
逐提交对比（`v0.1.0...v0.2.0` 那种），需要细节时点进去看。发布时 CI 会把对应小节取出来，
作为那个 release 的正文 —— 所以**先写这里，再打 tag**。

| 版本 | 日期 | 一句话 |
|---|---|---|
| [0.3.1](#v031) | 2026-09-17 | 断了会自己接上；后台也保持连接；聊天窗能打中文 |
| [0.3.0](#v030) | 2026-09-17 | 没有 herdr 的机器也能开终端；终端里可以整段说话，而且 `/` 和 `@` 菜单还在 |
| [0.2.1](#v021) | 2026-09-17 | 终端软键盘：输入框不再被键盘盖住、退格能删、画面完整；`hdp` 能配第二台手机 |
| [0.2.0](#v020) | 2026-09-16 | 应用内更新：检查 / 下载 / 校验 / 交给系统安装器 |
| [0.1.0](#v010) | 2026-09-16 | 首个版本：看板、终端、文件、Git、启动 agent、`hdp` 配对 CLI |

---

<a id="v031"></a>
## [0.3.1] — 2026-09-17

### 中文

**新增**

- **后台保活**（设置 → 行为 → 后台保活，默认开）：切到后台时用前台服务拿住进程，
  连接不再被系统冻结掐断，状态栏会有一条常驻通知。**可以随时关掉**，关掉立即停服务、
  通知消失。走 SSH shell 页（自己那条连接）时同样生效。
- **断线即自愈**：连接一断就自己重拨（先三次，然后每 30 秒一轮、最多四轮），
  期间状态栏文案是「连接断了，正在重连…」；回到前台会先做一次往返校验
  （进程被冻结时 socket 看起来还是开着的）。终端页给了一条回得来的路：
  失败/结束的浮层上有「重试」或「重新打开」，连接恢复后自动重挂。

**修复**

- **断线之后再也没接上，只能跑去机器上重连**：死掉的 SSH 会话被永久当成活的
  （只检查了「有过一个 client」），拨号器也永远没人通知，于是状态停在「已连接」、看板还是旧数据。
  现在传输层自己报告死亡（`ConnectionLiveness`），死掉的连接不会被交出去，也不会懒重拨。
- **断线被误报成「这台机器上没有找到 herdr」**：判断用的是「消息里含哨兵字符串」，
  而哨兵字面量就写在我们自己生成的命令里、报错消息又把整条命令拼了进去 —— 必然命中。
  现在按**整行相等**判断，错误消息也不再带命令原文（会截断并带上真正的原因）。
- **聊天窗在真机上弹安全输入法、打不了中文**：字段设了 `enableSuggestions: false`，
  而 Android 引擎拿它来实现「不外传学习」的方式是给输入框加上
  `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` —— 输入法据此当成密码框。现在保留联想、
  仍然关掉自动更正与标点改写（那两个会悄悄改命令）。真机实测输入类型为
  `0x20001`（普通多行文本）。
- **`/` 菜单报错时把 8KB 的命令原文甩到屏幕上**：现在只给一句人话和失败原因。
- **重连期间看板不再清空**：空白等于说「agent 都没了」，而真相是「连接没了」。

### English

**Added**

- **Keep-alive in the background** (Settings → Behaviour, on by default): a foreground service
  holds the process while the app is away, so the connection is not frozen to death, with a
  persistent notification. **It can be turned off at any time** — the service stops and the
  notification goes with it. The SSH shell page keeps its own connection alive the same way.
- **A dropped connection heals itself**: the app re-dials on its own (three quick tries, then up
  to four rounds thirty seconds apart) and says so — "Connection lost — reconnecting…". Coming
  back to the foreground gets a round-trip check first, because a frozen process is not a closed
  socket. The terminal offers a way back from a dead session and re-attaches when the connection
  returns.

**Fixed**

- **After a drop it never reconnected; the only way back was walking to the machine.** A dead SSH
  session was handed out forever (the only test was "a client exists"), nothing told the dialler,
  and the status stayed "connected" with a stale board underneath it. The transport now reports
  its own end and a dead one is never reused.
- **A dropped link was reported as "herdr is not installed on this machine"**: the check was a
  substring match on a sentinel that this app writes into its own commands, so any message
  quoting a command matched. It is a line-exact match now, and error messages carry the reason
  instead of the command.
- **The chat field brought up a secure keyboard on the phone, with no Chinese input**:
  `enableSuggestions: false` makes Android's engine add
  `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD`, which keyboards read as a password box. Suggestions
  stay on; autocorrect and the punctuation rewrites stay off, because those corrupt a command.
  Measured on the device: the field's input type is `0x20001`, plain multiline text.
- **8 KB of shell command on the screen when a menu failed**: one sentence and the reason now.
- **The board no longer blanks itself while reconnecting**: blank says "the agents are gone"
  when what is gone is the connection.

---

<a id="v030"></a>
## [0.3.0] — 2026-09-17

### 中文

**新增**

- **一条不走 herdr 的终端**：看板右下角的按钮 → 选一台机器 → 一个真正的 PTY。
  默认命令是 `tmux new -A -s herdr-pocket`（有 tmux 就接上去、没有就退化成登录 shell），
  命令自带 PATH 前缀，因为 `ssh host <cmd>` 跑的是非登录 shell。
  会话结束时退出码显示在横幅上，而不是盖掉整屏输出；回滚缓冲在本地，断线了也能往回读。
  跑什么命令、留多少行回滚，都是设置项。
- **聊天窗**：在手机上敲一整条消息，一次写出去 —— 一次 bracketed paste，隔 120 ms 再单独发一个
  Enter（好几个 TUI 会把紧跟粘贴尾巴的 CR 当成粘贴的一部分，于是消息躺在输入框里不发出）。
  `/` 菜单列这台机器的 skills 与 MCP，`@` 菜单列窗格目录下的文件：这两个菜单必须自带，
  因为 TUI 是靠**逐键**弹菜单的，一整段粘贴它一个按键都看不到。`+` 走手机自己的文件选择器。
- **工作区分组的身份色**：编号徽章的颜色是 workspace number 的纯函数，等相对亮度，
  相邻 ΔE ≥ 14.7，且离四种状态色足够远 —— `test/ui/workspace_palette_test.dart`
  从常量重算这三个数，改错颜色是构建失败，而不是等用户发现。
- **`tool/probe_release.dart`**：拿 GitHub 上**真的** payload 跑一遍发布挑选逻辑
  （`parseReleases` / `pickAppRelease` / `pickApkAsset` / `parseChecksums`）；`--download`
  还会沿手机走的那条 302 路径把资源抓下来，对着 release 自己的 `checksums.txt` 校验。

**改动**

- **液态玻璃与自动检查更新改为默认打开**（用户决策）。磁盘上存着的 `false` 依然优先 ——
  默认值的改动不该推翻有人专门关过的东西，2018 年的机器仍然可以在设置里关掉。

**修复**

- **删光机器之后还在「正在重试 2/3」**：被取代的那一轮拨号会继续写 `state`。现在每轮开工前
  重读「我要连的机器还在不在」，并且每一次写都过 generation 检查 —— 包括最后那次失败。
- **终端回滚条谎报历史**：本地计数器加的是「我请求了多少」，而 daemon 会拒绝、或在 max 处夹紧，
  且被夹紧的那一次不发事件。现在以 daemon 为准（`pane.scroll_changed` 按 pane 订阅），
  本地镜像只负责跟手，没有历史的 pane 不发请求，到顶了就说「已经到最旧」。
- **shell 页在真机上打不开 pty**：`Stream<List<int>>` 和 dartssh2 实际给的
  `Stream<Uint8List>` 在运行时对不上 —— 单元测试喂的是宽的那个，所以全绿。
- **退出码把终端内容盖掉了**：改成横幅，占按键条的位置，输出留在屏幕上；
  那句 `command not found: tmux` 才是用户真正需要的解释。
- **复制出来的是 `Instance of 'BufferLine'`**：改用 `Buffer.getText()`。
- **键盘弹出时那次 resize 被静默丢掉**：会话还没建立就去抖到期，守卫把它扔了，远端于是永远
  停在 66 行 —— tmux 把状态栏画在可见区之外，而且只重画变化过的行，所以永不出现。
  现在拨号返回后会对一次账。
- **设置页被长文本撑爆 547 像素**，以及值贴着标签（`expandTrailing` 用错了地方）。
  值现在是一个短语，真正的命令在它后面那一页。
- **聊天窗的三个静默失败**：监听器在菜单没开时短路（于是打开菜单的那个 `/` 恰恰是它唯一
  没看见的键）；回复的分隔符只在「还没打开任何文件」时检查（于是第二个配置文件被并进第一个，
  每台机器的 MCP 都是空的）；zsh 在 glob 不匹配时中止整个探测脚本（现在跑在 `/bin/sh -c` 里）。

**其他**

- 设置页每个页面只留一行脚注。
- 按键条抽成 `key_strip.dart`，两个终端页面共用；终端基准字号挪到渲染层。
- README 缩短，架构与实现细节移进 `docs/TECHNICAL.md`。
- `sh tool/ci_tests.sh` 的跳过计数补上了滚动探针那 4 个：它一直只认 `live_writes_test.dart`
  的 3 个，于是加了探针之后，本地跑这道门槛会直接判失败。

### English

**Added**

- **A terminal that does not go through herdr**: the button on the board → pick a machine → a
  real PTY. The default command is `tmux new -A -s herdr-pocket` (attach if it exists, a login
  shell if it does not), with the usual PATH prefix, because `ssh host <cmd>` runs a non-login
  shell. When the session ends the exit status is shown in a banner rather than replacing the
  screen, and the scrollback is local, so reading back keeps working when the link does not.
  Which command to run, and how many lines to keep, are both settings.
- **A composer**: type a whole message on the phone and put it on the wire in one write — one
  bracketed paste, then a separate Enter 120 ms later (several TUIs treat a carriage return that
  arrives in the same read as the paste as part of the paste, and leave the message unsent).
  A `/` menu of the machine's skills and MCP servers, an `@` menu of the files under the pane's
  directory: both have to be drawn here, because a TUI opens its menus by seeing each keystroke
  and a paste gives it none. The `+` button uses the phone's own document picker.
- **Identity colours for workspace groups**: the number badge's colour is a pure function of the
  workspace number, at a constant relative luminance, with adjacent entries ΔE ≥ 14.7 and every
  entry far from the four status hues. `test/ui/workspace_palette_test.dart` re-derives all three
  from the constants, so a careless colour edit fails the build instead of a user's eyes.
- **`tool/probe_release.dart`**: runs the release-picking logic against the **real** GitHub
  payload (`parseReleases`, `pickAppRelease`, `pickApkAsset`, `parseChecksums`); `--download`
  goes further and fetches the picked asset along the 302 path the phone takes, checking it
  against the release's own `checksums.txt`.

**Changed**

- **Liquid glass and the automatic update check now default to on** (the user's decision). A
  stored `false` still wins — a default change may not overrule somebody who turned a thing off
  on purpose — and the 2018 phone can still turn both off in Settings.

**Fixed**

- **The board kept saying "retrying 2 of 3" for a machine that had been deleted**: a superseded
  dial keeps writing to `state`. Each round now re-reads whether the machine still exists, and
  every write is guarded by a generation check — including the final failure.
- **The terminal's scroll bar announced a scrollback that was not there**: the local counter
  advanced by what was *asked* for, while the daemon refuses, or clamps at the maximum, and a
  clamped request emits no event. The daemon is the source of truth now
  (`pane.scroll_changed`, subscribed per pane), the mirror is optimistic only so the bar follows
  the finger, a pane with no history is never asked, and the bar says "at the oldest" at the top.
- **The shell page could not open a pty on a real device**: `Stream<List<int>>` does not match
  the `Stream<Uint8List>` dartssh2 actually hands over — the unit test fed it the wide one, so
  every test was green.
- **The exit code replaced the terminal's contents**: it is a banner now, in the key strip's
  place, with the output still on screen — `command not found: tmux` was the explanation the
  user needed.
- **Copy produced `Instance of 'BufferLine'`**: `Buffer.getText()` now does what the loop tried to.
- **A resize was silently dropped when the keyboard opened**: the debounce fired before the
  session existed, the guard threw the resize away, and the far end stayed at 66 rows — so tmux
  drew its status bar below the visible area and never repainted a row that had not changed.
  The page now reconciles the size it asked for once the dial comes back.
- **A long value overflowed a settings row by 547 pixels** and then sat against its label
  (`expandTrailing` used in the wrong place). The value is a phrase now, and the full command
  lives on the page behind it.
- **Three silent failures in the composer**: a listener that short-circuited while no menu was
  open never saw the `/` that opens one; the reply's file marker was checked only while no file
  was open, so every config after the first was appended to the first and every machine's MCP
  list was empty; and zsh aborts a script at the first unmatched glob, which killed the probe
  (it runs inside `/bin/sh -c` now).

**Chores**

- One line of footnote per settings page.
- The key strip moves to `key_strip.dart`, shared by both terminal screens; the base font size
  moves to the render layer.
- A shorter README, with the architecture and the implementation details in `docs/TECHNICAL.md`.
- `sh tool/ci_tests.sh` now counts the scroll probe's four tests among the opt-in skips: it only
  ever knew about `live_writes_test.dart`'s three, so adding the probe made the gate fail on
  every laptop.

---

<a id="v021"></a>
## [0.2.1] — 2026-09-17

### 中文

**修复**

- **软键盘下的终端**：TUI 的输入框不再被键盘盖住。原因是 daemon 在窗格比请求的尺寸大时
  **从左上角裁剪**、且不会改动窗格本身的尺寸 —— 键盘一弹出，请求的行数跟着变矮，丢掉的
  正好是光标所在的那一端。现在请求按**窗格自己的行数**发出，可视窗口按**底部对齐**，
  于是键盘弹出不再产生任何往返，窗格最后一行永远贴在按键条上沿。
- **退格键能删掉 TUI 里已输入的文本**。原来输入框每次按键后就被清空，退格在 IME 看来
  "没有变化"，于是一个字节都不会发给终端 —— 整会话退格皆死。现在字段常驻两个用户看不见的
  空格作哨兵，比它长是打字、比它短是退格（每删一个字符发一个 DEL）。
- **终端画面不再只剩三行**。本地缓冲区没有跟着 daemon 实际渲染的几何走，一直停在默认的
  80×24，底部对齐的窗口算术于是一行都画不出来。现在以帧声明的尺寸为准，只在真的变了时才
  resize（xterm 的 resize 会重排内容）。
- **已配对一台手机后，第二台永远配不上**。等待逻辑把 `hdp-pocket` 注释的出现当成了
  "我的手机到了"，而那是**所有**手机共用的注释 —— 于是它在第一条轮询就误判成功、删掉自己的
  一次性密钥，扫码的人拿到的只能是"配对码已经失效"。现在按**启动前的快照做差集**，
  并且一次性密钥在 `__exchange` 里被用掉的瞬间就删除。

**新增**

- 中文/日文等**组合输入不再泄进终端**：IME 组词期间一个字节都不发，提交时才发出去。
- **硬件键盘**（蓝牙键盘，或 `adb` 注入的按键）也能打字、退格、回车 —— 这条路不经过 IME，
  自写的输入客户端必须自己接。

**其他**

- 新增 `CHANGELOG.md`（就是这份），并且 release 的正文改为**取自它**：条目缺失时发布任务
  直接失败，而不是发一个什么都不说的 release。

### English

**Fixed**

- **The terminal under a soft keyboard**: a TUI's composer is no longer covered. The daemon
  *crops* a pane from its top-left when the requested size is smaller than the pane and never
  resizes the pane itself — so opening the keyboard shortened the request and threw away
  exactly the end the cursor lives at. The grid is now asked for at the **pane's own height**
  and the visible window is anchored to the **bottom**, which also removes every round trip
  the keyboard used to cost.
- **Backspace deletes again.** The composer cleared its field after every keystroke, so a
  backspace was "no change" to the IME, no byte reached the terminal, and deleting was dead for
  the whole session. The field now keeps two invisible spaces as a sentinel: longer is typing,
  shorter is a backspace (one DEL per character deleted).
- **The screen is no longer three lines.** The local buffer never followed the geometry the
  daemon actually rendered — it stayed at xterm's default 80×24, and the bottom-anchored window
  arithmetic could not draw anything. The model now matches the frame's declared size, and is
  resized only when it really differs (xterm's resize reflows content).
- **A second phone could never pair** on a machine that already had one. The wait treated the
  `hdp-pocket` comment — which every paired phone carries — as "my phone has arrived", reported
  success on the first poll, deleted its own one-time key, and left the person scanning a code
  that could only say "expired". It now diffs against a snapshot taken before the key was
  written, and the one-time key is removed the instant `__exchange` uses it.

**Added**

- **Composing input (Chinese, Japanese) no longer leaks into the terminal**: nothing is sent
  while the IME is composing; the committed text is sent once.
- **Hardware keyboards** (Bluetooth, or anything driving the phone through `adb`) can type,
  backspace and press Enter — that path never touches the IME, so a hand-written input client
  has to handle it itself.

**Chores**

- Added `CHANGELOG.md` (this file), and a release body is now **taken from it**: a tag with no
  entry fails the release job instead of publishing a body that says nothing.

---

<a id="v020"></a>
## [0.2.0] — 2026-09-16

### 中文

**新增**

- **应用内更新**：设置 → 「检查更新」，从 GitHub Releases 取最新版本、带进度条下载 APK
  （可取消，取消后保留已下载的部分，下次接着下）、按 release 自带的 `checksums.txt` 校验，
  再交给系统安装器。开启「启动时检查」则每次启动查一次，有新版本只用一行轻提示。
- 下载**跟随手机的 HTTP 代理**：代理慢的时候不让更新默默走直连。
- 发布流程：Android APK（arm64 / armeabi-v7a / universal）与 macOS `.dmg` 一起产出，
  带 `checksums.txt`。

### English

**Added**

- **Updates from inside the app**: Settings → *Check for updates* asks GitHub Releases for the
  newest version, downloads the APK with a cancellable progress bar (a cancelled download keeps
  what arrived and resumes next time), verifies it against the release's own `checksums.txt`,
  and hands it to the system installer. *Check automatically* asks once per launch and says so
  with a single line.
- Downloads **follow the phone's HTTP proxy**, so an update never quietly bypasses it.
- Releases now ship the Android APKs (arm64, armeabi-v7a, universal) and a macOS `.dmg`, with
  `checksums.txt` beside them.

---

<a id="v010"></a>
## [0.1.0] — 2026-09-16

### 中文

**首个版本。**

- **看板**：每台机器上的每个 agent，按"需要你 / 已停止 / 在忙 / 空闲"分组，需要你的一律在前。
- **终端**：真正的字符网格 —— 回滚、选区复制、bracketed paste，以及一条软键盘发不出来的
  按键条；整个 tab 的分屏布局也能镜像到手机上。
- **文件**：浏览窗格的工作目录、读文件；长按可下载到手机。
- **Git**：把窗格目录当仓库读 —— 已暂存 / 未暂存 / 未跟踪 / 冲突、与 upstream 的领先落后数、
  单个文件的 diff。
- **启动 agent**：选目录 + 选 herdr 报告的可用 agent（可选**独立 worktree**），或把一个 agent
  放进已经空闲的 shell 窗格。
- **附件**：粘贴文本 / 选图 / 拍照，上传到机器并把路径打进终端。
- **机器**：SSH 主机与 keystore 凭据、首次使用即固定的主机密钥；配对就是扫一次二维码。
- **通知**：agent 开始等你时本地提醒，点开就是它的终端。
- 简体中文（默认）+ 英文，浅色 / 深色配色（终端用配色方案自己的十六色）。
- **`hdp` 配对 CLI**：把一次性、带 `restrict` 和 `command=` 的引导密钥画成二维码，
  手机扫完装自己的公钥，引导键立刻删除 —— 不需要密码、不需要改 `sshd_config`、
  也不需要在两端之间有一条能互通的局域网（只要 SSH 那条路通）。

### English

**First release.**

- **The board**: every agent on every machine, grouped by what it needs, `needs you` first.
- **The terminal**: a real character grid — scrollback, selection and copy, bracketed paste, and
  a key bar for the keys a soft keyboard cannot send; the whole tab's split layout can be
  mirrored to the phone.
- **Files**: browse a pane's working directory and read a file; long-press to download it.
- **Git**: the pane's directory read as a repository — staged, unstaged, untracked, conflicted,
  ahead/behind against upstream, and a diff per file.
- **Starting an agent**: pick a directory and one of the agents herdr offers (optionally in a
  fresh **git worktree**), or put one into an idle shell pane.
- **Attachments**: paste text, pick a photo or take one — uploaded, then its path typed into the
  terminal.
- **Machines**: SSH hosts with keystore credentials and host keys pinned on first use; pairing is
  one QR code.
- **Notifications**: a local alert when an agent starts waiting on you, opening its terminal.
- Simplified Chinese (default) and English, with light and dark colour schemes (the terminal
  takes the scheme's own sixteen colours).
- **The `hdp` pairing CLI**: a one-time key with `restrict` and `command=` rendered as a QR code;
  the phone installs its own key and the bootstrap key is deleted at once — no password, no
  `sshd_config` change, and no requirement that the two ends can reach each other except for the
  SSH connection itself.
