# AGENTS.md — herdr-pocket

> 这个 Flutter 项目自己的长期记忆。**动手前先读 [`docs/TECHNICAL.md`](docs/TECHNICAL.md)**：
> 四条通路、协议里会静默出错的地方、两条终端通路的分工、代码地图、发布流程和
> 「哪些限制是架构决定的、不要去修」全在那份里。
> 工作区级的约定与踩坑史在 [`../AGENTS.md`](../AGENTS.md)（`whip/`、`herdrup/` 只读参考，
> 调研在 `../docs/research/`）。
> 本文件保持精炼 —— 它每次会话都会被加载。

## 这是什么

[herdr](https://herdr.dev) 的 Flutter 客户端（**Herdr Pocket**，两个词都大写）：
看板 + 工作区树 + 终端镜像 + 一条不经 herdr 的 SSH 终端，外加文件、git、起 agent、
`hdp` 配对。跨平台：手机与桌面一份 Flutter 代码；**实机验证主要走 Android**
（MiX 2S / `herdr_test` 模拟器）。

## 红线

1. **不许 Material Design** —— 不引入 Material widget / 视觉 / 图标。
   `test/architecture/no_material_test.dart` 会让构建失败。
2. **`lib/domain/` 保持纯 Dart**（不含 Flutter）——
   `test/architecture/domain_purity_test.dart` 守着它。
3. **新代码进新文件**（feature first）。共享文件（设置页、arb、页面注册表）的改动
   保持单点、增量、一眼能分辨，这样并行分支才不会在同一个 hunk 上打架。
4. **不要裸跑 `dart format`**：Dart 3.13 是新风格、仓库是旧风格，跑一次是几百行纯噪音。
   手写按周围风格，验证只靠 `flutter analyze`。
5. **改了 `.arb` 就必须 `flutter gen-l10n`**：生成物 `lib/l10n/generated/` 是**签入**仓库的，
   CI 会 `git diff --exit-code` 抓这件事。
6. **图标改 SVG，不手改 PNG**：`assets/icon/*.svg` → `sh tool/render_app_icon.sh`。
7. **不碰 `../whip/`（AGPL，只移植语义不移植表达）与 `../herdrup/`（Apache-2.0，可复用需署名）**。
8. **README 两个语言版本同步改**：`README.md` / `README.zh-CN.md`；
   `CHANGELOG.md` 是单文件双语，**发版前先写条目再打 tag**（没条目发布任务会失败）。

## 三条命令

```sh
flutter analyze && flutter test     # 约 1000 个测试，约 45 秒
sh tool/ci_tests.sh                 # 同一套，外加「有测试被跳过就失败」那道门
patrol test -d <device>             # 上机冒烟，手动跑，不进 CI
```

改传输、终端、协议相关的代码时**跑第二条**：`flutter test` 在笔记本上会安静地跳过
`test/integration/`，绿色勾什么都不代表。会创建东西的测试要 `HP_LIVE_WRITES=1`。

## 容易搞错的三件事

- **`test/ui/` 里的断言引用 token，不钉死魔法数字** —— 钉死的那个会在设计微调时
  伪装成回归。
- **别用猜的尺寸开终端会话**，也别让本地终端模型停在 80×24：frame 声明的尺寸才是真的。
- **文案短，别自曝设计**：设置页的说明一行就够；README 不要写「不用 Material、
  自研 Apple 风格设计系统、可选 Liquid Glass」这类实现/定位说明 —— 用户 2026-09-17
  的原话是「直接写高颜值客户端」。功能条目只写「是什么」，不写「为什么我们这么设计」，
  那些留给 `docs/TECHNICAL.md`。

细节、来历和已验证的结论都在 [`docs/TECHNICAL.md`](docs/TECHNICAL.md) 与
[`../AGENTS.md`](../AGENTS.md)，这里不重复。
