[English](../../../PRIVACY.md) · [Português](../pt-BR/PRIVACY.md) · [Español](../es/PRIVACY.md) · [Français](../fr/PRIVACY.md) · [Deutsch](../de/PRIVACY.md) · **简体中文** · [日本語](../ja/PRIVACY.md) · [한국어](../ko/PRIVACY.md)

# 隐私政策 — MacSpace

**最后更新：2026 年 10 月 19 日 · 适用于 MacSpace 1.0.0 及更高版本**

MacSpace 不会收集、存储或传输任何使用数据。没有分析，没有遥测，没有崩溃报告，也没有广告。MacSpace
没有账户系统，所以你永远不需要创建资料或登录。

本文档准确说明 MacSpace 读取什么、把它保存在哪里，以及它使用网络的唯一时机。

---

## 保存在你的 Mac 上的内容

MacSpace 会测量你的磁盘，读取少量系统设置，并在你自己的机器上写入几个小文件。这些内容都不会离开你的 Mac。

| 数据 | 存储位置 |
|---|---|
| 你的设置：主题、窗口选项、哪些模块已开启、模块选项、自动清理、通知选项、每个模块最近显示的磁贴、首次启动的步骤 | MacSpace 的 macOS 偏好设置（`UserDefaults`），即 `~/Library/Preferences/com.macspace.app.plist` |
| Sparkle 自己的设置：是否自动检查更新，以及上次检查的时间 | 同一个偏好设置文件 |
| 清理历史：时间、哪个模块、释放了多少、如何开始的、一行摘要 | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| MacSpace 已请求释放、但 macOS 仍保留的空间 | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Debloat 日志：MacSpace 更改的每项设置、更改前后的值、macOS 构建版本和时间 | `~/Library/Application Support/MacSpace/debloat-journal.json`，由辅助程序所做的更改则在 `/Library/Application Support/MacSpace/debloat-journal.json` |
| Debloat 监视：macOS 重新开启了哪些功能以及时间（最近 20 个事件） | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| 等待你批准的 Debloat 描述文件 | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| 你的 Siri 语言和语音，在 Apple 智能关闭期间保存，以便 MacSpace 恢复 | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Siri、空间照片和本地通话转录的原始设置（包括不存在的值） | `~/Library/Application Support/MacSpace/feature-settings/` |
| 为恢复而保存的模型所有者请求，包括语音和语言选择 | `~/Library/Application Support/MacSpace/asset-owners/` |
| 系统范围内通话转录的原始覆盖设置 | `/Library/Application Support/MacSpace/phone-features.json` |
| Apple 智能监视（仅当你开启时）：它看到的最近状态，以及更改日志 | `~/Library/Application Support/MacSpace/ai-watch-state.json` 和 `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| macOS 订阅数据库的备份，仅当你移除已删除账户遗留的 Apple 智能订阅时 | `/Library/Application Support/MacSpace/backups/` |
| 更新下载 | Sparkle 的缓存文件夹 `~/Library/Caches/com.macspace.app/` |

你可以随时删除这些全部内容。[README.md](README.md#卸载)列出了相关命令。删除这些文件会让
MacSpace 忘记它的历史和设置。如果你在 Debloat 开关处于关闭状态时删除了 Debloat 日志，MacSpace 将无法再恢复它
保存的原始值，而会改用 macOS 的默认值。请先按**全部启用**。

### MacSpace 读取什么

MacSpace 为完成工作而读取你 Mac 上的这些内容。它不会把其中任何内容发送到任何地方。

- **文件和文件夹的名称与大小**，在你授予完全磁盘访问权限后涵盖整个磁盘。它不会读取你的文稿、照片、邮件或
  信息的内容，只测量它们占用多少空间。
- **App 缓存中文件的日期**（`~/Library/Caches`，以及在有完全磁盘访问权限时，每个 App 容器中的缓存文件夹
  `~/Library/Containers/<app>/Data/Library/Caches`）：每个文件的创建、更改或首次读取时间，以及 Spotlight 所记录的
  **每个 App 上次打开的时间**，用来判断哪些缓存没有被使用。它不会打开这些文件。
- **Homebrew 自己的估算**（如果已安装 Homebrew）：MacSpace 运行 `brew cleanup -n`，它不会更改任何内容；
  Homebrew 的自动更新和分析均已关闭，并且仅在 Homebrew 已有软件包列表时运行，所以 Homebrew 不会联网。
- **少数系统文件：** Apple 智能资格文件、macOS 的资源订阅数据库、已安装配置描述文件的列表，以及 Apple 账户
  数据库（只读，用于了解 Siri 的 iCloud 同步是否开启）。
- **这台 Mac 上用户账户的名称**，用于说明哪个账户让 Apple 智能保持开启。
- **macOS 的状态：** 它的版本和构建版本、系统完整性保护是否开启、这台 Mac 是否已注册设备管理、正在运行的进程名称
  （用于检查某个 Debloat 开关是否生效），以及系统日志中记录 macOS 自身分析决定的几行（用于检查分析开关是否生效）。

---

## MacSpace 何时使用网络

MacSpace 使用网络只有一个目的：**更新**。它没有分析、没有登录，也没有任何其他连接。

### 何时检查更新

MacSpace 使用 [Sparkle](https://sparkle-project.org) 查找并安装更新。它会在以下情况联网：

- 你在 MacSpace 菜单中选取**检查更新…**，或在“设置”中点按**立即检查**；
- 如果开启了自动检查，则在 MacSpace 运行期间大约每天一次。

在你于“设置”中开启**自动检查更新**，或对 Sparkle 从第二次启动起询问一次的问题回答“是”之前，自动检查处于关闭
状态。在此之前，MacSpace 不会自行检查。你从源代码构建的版本没有更新密钥，完全不会检查更新。

一次检查会向 GitHub 请求一个文件：

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

与任何网络请求一样，GitHub 能看到你的 IP 地址。该请求还会在常规的 `User-Agent` 标头中携带 MacSpace 的名称和
版本以及 Sparkle 的版本。MacSpace 不会发送系统概况、硬件信息或任何形式的标识符。Sparkle 的可选系统概况功能
未开启。GitHub 对该请求的处理见
[GitHub 隐私声明](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement)。

如果你接受更新，Sparkle 会从 GitHub Releases 下载。每个更新都有签名。Sparkle 在安装任何内容之前，会用
MacSpace 内置的公钥检查签名。

### 不属于 MacSpace 的部分

如果你重新开启 Apple 智能，macOS（而不是 MacSpace）可能会下载它的模型。打开下载的 App 时，macOS 可能会向
Apple 检查它。这些都是 macOS 自己的连接。

---

## MacSpace 绝不会做的事

- 绝不会把你的文件列表、磁盘数字、设置、清理历史或账户名称发送到任何地方。
- 绝不会读取你的文稿、照片、邮件或信息的内容。
- 绝不会要求你创建账户或登录。
- 绝不会向开发者或任何其他人报告崩溃或使用情况。

### 关于权限和辅助程序

MacSpace 会请求少量批准，每一项都在 macOS 自己的对话框或“系统设置”中完成，所以它永远看不到你的密码：

- **完全磁盘访问**，用于测量磁盘上的所有内容，并读取 Apple 智能的状态。
- **特权辅助程序**，一个启动守护进程（`com.macspace.helper`），负责少数需要管理员权限的操作。它只接受与
  MacSpace 由同一开发团队签名的客户端，并且只运行内置的操作。
- **配置描述文件**，仅当你停用某项 Debloat 策略时。
- **通知**，用于在某件事完成时告诉你。

辅助程序和描述文件能做什么，列在 [SECURITY.md](SECURITY.md) 中。

---

## 儿童

MacSpace 是 macOS 的实用工具，不面向儿童。它不会从任何年龄的任何人那里收集个人信息。

## 本政策的变更

如果 MacSpace 的行为发生变化，本文档会随之更新，顶部的日期也会更新。此文件的历史在本仓库中公开，所以你可以确切
看到改了什么、何时改的。

## 联系方式

关于隐私，或关于本文档中的任何内容，如有疑问：

**dev@giomantovani.com.br**
