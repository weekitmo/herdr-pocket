# herdr pocket

[English](README.md) · **简体中文**

<p align="center">
  <img src="docs/logo.png" width="104" alt="herdr pocket">
</p>

[herdr](https://herdr.dev) 的 Flutter 客户端 —— 一块看板，看你自己机器上跑着的编码
agent；每个 agent 后面一步，就是活的终端。

Android 优先，桌面构建用于开发。**不用 Material Design**：界面是一套自研的 Apple
风格设计系统，外加一层可选的 Liquid Glass。

<p align="center">
  <img src="docs/screenshots/board.png" width="44%" alt="看板，一只 agent 和真实的 herdr 版本号">
  <img src="docs/screenshots/terminal.png" width="44%" alt="该 agent 窗格上的活终端">
</p>

*在 Android 模拟器上跑出来的真实截图，经 SSH 连到另一台机器上的 herdr 0.9.0
daemon。工作区名字是重新画过的 —— 打码和外框都由 `tool/make_screenshots.sh` 完成。*

---

## 功能

**看板。** 每台机器上的每个 agent，按「它需要什么」分组。排序本身就是主张：
`需要你` 在最前，安静的都在最后。

**终端。** 任意窗格都是一个真实的字符网格 —— 回滚、选中复制、bracketed
paste，以及一排软键盘发不出来的键。整个 tab 的分屏布局可以镜像过来，
所以桌面上只有 20 列的窗格，在手机上照样看得清。

**文件。** 浏览某个窗格的工作目录，读里面的文件。预览会截断，而不是无上限地读；
二进制文件会直说，而不是糊一屏乱码。长按文件可以下载到手机。

**Git 改动。** 把窗格所在目录当仓库读：已暂存 / 未暂存 / 未跟踪 / 冲突，
相对上游的 ahead / behind，以及任意一个文件的 diff。

**起一个 agent。** 选一个目录，再选一个 herdr 报上来的、这台机器上装了的 agent，
应用会建好工作区并在里面启动它。勾上 *用独立 worktree*，它会改成开一个全新的
`git worktree` 加一条自己的分支 —— 于是可以放一个 agent 出去做事，
而它碰不到你正在看的东西。还有个更小的版本：把一个 agent 放进已经空闲的 shell
窗格里，压根不建工作区。

**附件。** 粘一段文字、从相册挑张图、或者直接拍一张。它会被传到那台机器上，
路径自动打进终端 —— 「你看下这张截图」不再需要两头都备一个文件管理器。

**机器。** SSH 主机，凭据存在系统 keystore 里，主机密钥首次使用时固定。
配对一台机器是一个二维码：跑 `hdp pair` 然后扫它，地址、端口、密钥一个都不用敲。

**通知。** agent 开始等你的时候来一条本地提醒，点它直接进那个 agent 的终端。

简体中文（默认）和英文，浅色与深色配色方案（终端用的是配色方案自带的那十六色）。

---

## 跑起来

```sh
flutter pub get
flutter run -d macos          # 开发用：直接连本机 daemon
flutter run -d <android-id>   # 真正的目标平台
```

### 连一台机器

应用不会自动发现机器，机器是你自己加的。有两条路。

**扫码配对**（推荐）—— 在机器上跑 `hdp pair`，扫它打出来的码。它会替你装好这台手机
自己的密钥，地址也一并填好，所以没有要敲的东西，也没有要粘贴的密钥。
详见下面的[用手机配对](#用手机配对hdp)。

**或者手动加：**

1. 打开看板，点左上角的机器图标。
2. **添加机器**：名称、主机、端口、用户名。
3. 选 **私钥** 并粘贴一份 OpenSSH 私钥，或者选 **密码**。
4. 保存。应用会选中这台机器并连接。

首次连接时会给你看这台机器的主机密钥指纹。信它之前，去机器上对一遍
（`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`）。如果之后密钥变了，应用会
大声说出来，而不是悄悄重新信任。

### 机器上需要什么

- **herdr 0.9.0 或更新版本**，正在运行，至少有一个 agent。
- 一个允许 **stream-local forwarding** 的 SSH 服务端（OpenSSH 的默认行为）。
  如果关掉了，你会收到一条明确的提示，而不是干等到超时 —— 因为修法就是
  `sshd_config` 里的一行：`AllowStreamLocalForwarding yes`。
- 看板、终端、文件、git、起 agent，都不需要别的了。**SFTP 子系统**只在搬运
  整份文件时才需要 —— 下载一个到手机，或者给 agent 附一个文件。把 SFTP
  子系统关掉，其余功能照常工作；而且应用会明说是这两件事里的哪一件失败了。

除了 herdr 本身，什么都不用装。没有桥接二进制，没有要拷过去的辅助脚本，
也没有要开放的端口。

---

## 它是怎么连的

```
Flutter ──SSH──▶ direct-streamlocal channel ──▶ ~/.config/herdr/herdr.sock
```

daemon 的 socket 是用户自己机器上的 Unix domain socket，从不暴露到网络上。
要跨过这一段，最直接的做法是经 SSH 跑一个辅助程序 —— iOS 参考客户端正是这么做的，
所以它需要一个**加了桥接子命令的 herdr fork**。

这个客户端改用 SSH 的 `direct-streamlocal@openssh.com` channel 类型，完全不需要
辅助程序，因此能对着**原版 herdr** 工作。

同一个 socket 也决定了文件和 git 为什么是这样做的：herdr 协议里既没有文件系统
API，也没有 git API，所以这两件事是走同一条 SSH 连接去问机器的 **shell** ——
`ls -lA` 列目录，`head -c` 读文件，`git status --porcelain=v2` 和 `git diff`
支撑改动页。这跟一个终端侧栏插件用的是同一套数据源，所以两边不可能对「改了什么」
给出不一致的说法。

只有*搬运整份文件*是另一回事，因为 shell 命令不是传字节的工具：下载和附件走
**SFTP**。而搭出上传路径这件事又正好反过来 —— 用 shell 的 `mkdir -p` 建目录
（SFTP 的 mkdir 不建父目录），字节本身交给 SFTP。

| 关注点 | 在哪 |
|---|---|
| SSH 传输、主机密钥 | `lib/data/transport/ssh_socket_transport.dart` |
| 协议分帧（NDJSON，UTF-8 只在换行边界解码） | `lib/data/protocol/` |
| 终端通道（`herdr terminal session control`） | `lib/data/terminal/` |
| 看板状态、fail-closed 分组 | `lib/domain/agent/` |
| 读目录、读文件、读仓库 | `lib/data/remote_fs.dart`、`lib/data/git_client.dart` |
| 文件传输（SFTP） | `lib/data/remote_download.dart`、`lib/data/remote_upload.dart` |
| 设计 token、玻璃 | `lib/ui/design/` |

`lib/domain/` 是纯 Dart，不含 Flutter，所以最要紧的那部分逻辑（分组、排序、
什么算「我读不出来」）不需要 binding 就能测。有两条测试守着项目的结构规则，
破坏了就直接让构建失败：

- `test/architecture/no_material_test.dart` —— 任何地方都不许 import Material。
- `test/architecture/domain_purity_test.dart` —— domain 层保持纯净。

---

## 测试

三条命令，三个问题，顺序就是你真会问它们的顺序。

### `flutter analyze` + `flutter test` —— CI 跑的就是这个

```sh
flutter analyze
flutter test                   # 约 750 个测试，约 40 秒
```

凡是在一个 Dart 进程里就能判定的事情都在这里：domain 层（排序、分组、解析、
终端的状态机）、对着脚本化传输层的数据层、各个 widget，以及两条不许回退的结构
规则（`test/architecture/`：不许有 Material、domain 保持纯 Dart）。

这些大多不需要任何外部条件。`test/integration/` 下的文件要和**真的 daemon、真的
SSH 服务端**对话，没有就自己跳过 —— 这在笔记本上是对的，但作为结论毫无价值，
所以 CI 不听它们的一面之词：

### `sh tool/ci_tests.sh` —— 同一套测试，一个都不许跳过

```sh
sh tool/ci_tests.sh          # CI 跑的，在你自己的机器上跑
```

如果还没有，它会起一个 headless 的 herdr daemon 和一个一次性的 SSH 服务端，
跑完整套测试，然后**只要有东西被跳过就失败**。最后这一步才是重点：没有它，
一个坏掉的 SSH 传输照样能拿到绿色勾，因为覆盖它的那九个文件会很自觉地认定自己
无事可做。

`HP_LIVE_WRITES=1 sh tool/ci_tests.sh` 还会跑那些**会创建东西**的测试（一个工作区、
一个上传的文件）。默认关掉，因为在你自己的机器上，那个 daemon 就是你的工作现场。

那个 SSH 服务端是 **/tmp 里的第二个 sshd**，带自己的主机密钥和自己的
`authorized_keys`（`tool/test_sshd.sh`）。它刻意不碰你的 `~/.ssh`：为了让测试跑起来
就往别人的 `authorized_keys` 里加一把钥匙，那是为了图方便去改别人的安全配置。

### `patrol test` —— 装在手机上还起得来吗

```sh
flutter pub global activate patrol_cli   # 一次，把 `patrol` 放进 PATH
patrol test -d emulator-5554             # 或者任何连着的设备
```

**手动跑，不进 CI**，而且刻意做得很钝。三个冒烟测试：冷启动、每个根页面都能打开、
首次使用的路径（看板 → 机器 → 添加一台机器）能走到地方 —— 每个都只断言「没有抛
异常」。它们抓的是单元测试看不见的那一类失败：插件在引擎初始化时抛错、资源缺失、
字体加载不了。

它们断言的是**结构，从来不是一个词、一种颜色、一个尺寸或者一个像素**。文案会改、
配色会调、间距会动 —— 那些都是看一眼才能下的判断，而一套把这些钉死的测试会让每次
设计微调都变成改测试。

它不进 CI，是因为启动模拟器、构建测试 APK、装两个 APK 加起来大约十分钟。
动应用外壳、插件集合或者字体之前跑一次。

⚠️ `patrol test` **不能**用 `flutter test patrol_test/` 代替。那些测试由 Android
自己的 instrumentation runner 驱动。

---

## 限制，直说

- **文件浏览器只读，不能改。** 它能列、能预览、能下载。在手机键盘上编辑文件不是
  这个应用想擅长的事 —— 隔壁的终端才是。
- **通知只在前台。** 应用活着的时候才会响。真正的后台送达需要一个能推到手机上的
  东西，而没有东西可推：daemon 在你自己的机器上，只有手机主动开出去的那条连接能
  碰到它。这是架构上的限制，不是没做完的功能。
- **只支持原版 herdr。** Gram 消息、他们的推送通知、联邦机器都在一个 fork 里，
  这里不支持。
- **macOS 上 App Sandbox 是关的。** herdr 客户端必须读用户主目录下的一个 socket，
  并且主动开出去 SSH 连接；沙盒里的应用这两件事都做不了。
- **ssh-agent 认证**没有实现。私钥和密码实现了。

---

## 目录

```
lib/
  app/            外壳、设置、路由
  data/           传输、协议、终端、通知
  domain/         纯 Dart：agent 状态、分组、排序
  ui/             设计 token、玻璃、组件、页面
test/
  architecture/   结构规则，是强制执行的，不是写在文档里的
  data/ ui/       单元测试
  integration/    对着真 daemon 和真 SSH 服务端的测试
patrol_test/      上机冒烟测试，手动跑（见「测试」）
tool/             CI 跑的脚本，你也都可以手动跑
cli/hdp/          宿主侧配对 CLI，Go 写的
docs/             上面的 logo 和两张截图
assets/           字体、agent 图标、配色方案
```

---

## CI 与发布

| Workflow | 触发 | 做什么 |
|---|---|---|
| `.github/workflows/ci.yml` | 每次 push 和 pull request | `flutter analyze`，以及上面那道带真 daemon、**一个测试都不跳过**的测试门 |
| `.github/workflows/release.yml` | tag `v*` | release APK（split + universal）和一个 macOS `.dmg`，挂到 GitHub Release 上 |
| `.github/workflows/hdp-release.yml` | tag `hdp-v*` | `hdp` CLI 的静态二进制 |

## 用手机配对：`hdp`

应用需要在它要对话的机器上有一把 SSH 密钥。手工做这件事意味着生成密钥、找到
`authorized_keys`、再往手机里粘一段 PEM —— 所以有个小 CLI 改用二维码来做：

```sh
curl -sSL https://raw.githubusercontent.com/weekitmo/herdr-pocket/main/cli/hdp/install.sh | sh
hdp pair
```

完整文档，包括它会写入什么、以及为什么把私钥放进二维码里是安全的：
[`cli/hdp/README.md`](cli/hdp/README.md)。
