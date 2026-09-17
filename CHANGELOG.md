# Changelog / 更新日志

[中文](#中文) · [English](#english)

版本与版本之间**改了什么**，按时间倒序排在这里；每个版本末尾的 Full Changelog 链接是完整的
逐提交对比（`v0.1.0...v0.2.0` 那种），需要细节时点进去看。发布时 CI 会把对应小节取出来，
作为那个 release 的正文 —— 所以**先写这里，再打 tag**。

| 版本 | 日期 | 一句话 |
|---|---|---|
| [0.2.1](#v021) | 未发布 | 终端软键盘：输入框不再被键盘盖住、退格能删、画面完整；`hdp` 能配第二台手机 |
| [0.2.0](#v020) | 2026-09-16 | 应用内更新：检查 / 下载 / 校验 / 交给系统安装器 |
| [0.1.0](#v010) | 2026-09-16 | 首个版本：看板、终端、文件、Git、启动 agent、`hdp` 配对 CLI |

---

<a id="v021"></a>
## [0.2.1] — 未发布 · Unreleased

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
