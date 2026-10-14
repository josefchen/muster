<p align="center">
  <img src="docs/media/icon.png" width="112" height="112" alt="Muster">
</p>

<h1 align="center">Muster</h1>

<p align="center">
  <b>别让 Agent 等你。</b><br>
  一款免费、开源的 Mac 菜单栏应用，集中管理你的 Claude Code、Codex 和 Cursor 会话。
</p>

<p align="center">
  <a href="https://github.com/josefchen/muster/releases/latest/download/Muster.dmg"><b>下载 Mac 版</b></a> ·
  <code>brew install --cask josefchen/tap/muster</code> ·
  <a href="https://agentmuster.app">agentmuster.app</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/answer-dark.gif">
    <img src="docs/media/answer-light.gif" width="760" alt="Claude Code 和 Codex 先后请求运行命令。Muster 的提醒先显示最新的一个，底部列出可用按键；⌥↓ 展开 Codex 请求的原因，⌥↩ 依次批准。">
  </picture>
</p>

<p align="center"><sub>两个 Agent 发来请求。<kbd>⌥</kbd><kbd>↓</kbd> 看原因，按两次 <kbd>⌥</kbd><kbd>↩</kbd> 批准，全程不用离开手头的工作。录自应用本身。</sub></p>

同时跑几个编程 Agent 时，慢的往往不是 Agent，而是你没注意到其中一个已经等你确认了十分钟。Muster 常驻菜单栏，Agent 一需要你就提醒你，而且不用切换应用就能直接回复。

- **看到谁在等你。** Agent 一等你，屏幕顶部就会出现一个玻璃质感的提醒，直到你回复才消失。
- **在任何地方回复。** 用 <kbd>⌥</kbd><kbd>↩</kbd> 批准命令、选择答案，也可以直接在系统通知上操作。提醒上会标出可用的按键。
- **先看原因再回复。** <kbd>⌥</kbd><kbd>↓</kbd> 展开 Agent 请求的理由、完整命令，或者问题的每个选项及其说明。
- **不抢你的快捷键。** 只有屏幕上有待回复的内容时，Muster 才会占用这些按键；你在其他应用里打字时，它会自动让出。
- **<kbd>⌥</kbd><kbd>Tab</kbd> 切到任意 Agent。** 最紧急的排在最前，松开即跳到它的窗口或所在的终端。
- **查找任意会话。** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd> 搜索最近三小时的会话，并显示每个会话的 token 用量和按 API 价格估算的成本。

<p align="center"><sub>原生 AppKit 与 Liquid Glass · 安装包 2 MB · 十个 Agent 同时运行时约占 0.4% CPU、20 MB 内存 · 无需账号，无统计分析 · MIT</sub></p>

## 安装

**[下载 Muster.dmg](https://github.com/josefchen/muster/releases/latest/download/Muster.dmg)** 并拖到「应用程序」，或者：

```bash
brew install --cask josefchen/tap/muster
```

需要 macOS 14 或更高版本，支持 Apple 芯片和 Intel。Liquid Glass 效果需要 macOS 26。

## 在 Muster 里回复 Agent

在 **Settings → Answer prompts from Muster** 中按 Agent 分别开启。

| | 可以回复的内容 |
|---|---|
| **Claude Code** | 权限请求、多选问题、计划审批 |
| **Codex** | 审批请求（需在 Codex 中运行一次 `/hooks` 信任该 hook） |
| **Cursor** | 在 Cursor 中打开对应的提示 |

Muster 只在 Agent 自己的配置文件里添加一个 hook，关闭时也只移除这一项。修改前的文件会保存在旁边的 `.muster-original` 中。Claude 自带的确认框会同时保留，先回复的生效。Muster 没有运行时，Agent 会照常询问。hook 通过 `127.0.0.1` 和每次安装生成的 token 与 Muster 通信。

## 快捷键

| 按键 | |
|---|---|
| <kbd>⌥</kbd> <kbd>Tab</kbd> | 切换会话。轻点切换，松开打开，也可以直接点击 |
| <kbd>⌥</kbd> <kbd>↩</kbd> · <kbd>⌥</kbd> <kbd>⌫</kbd> · <kbd>⌥</kbd> <kbd>1</kbd>–<kbd>9</kbd> | 批准 · 拒绝 · 回答提醒或切换器中的问题 |
| <kbd>⌥</kbd> <kbd>↓</kbd> · <kbd>⌥</kbd> <kbd>↑</kbd> | 展开提醒详情 · 收起 |
| <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>Space</kbd> | 搜索所有会话 |

两个主快捷键都可以在设置中修改。也支持脚本调用：`muster://search`、`muster://next`、`muster://settings`。

## 隐私

Muster 只读取 Agent 已经写在你 Mac 上的会话文件，问题和回复都只经过 `127.0.0.1`。没有账号，没有统计分析，唯一的网络请求是每天一次的更新检查，会在欢迎引导里征得你同意，也可以在设置中关闭。

## 许可证

MIT。源码、问题反馈和更新记录都在本仓库：[CHANGELOG.md](CHANGELOG.md)。
