[English](../../../SECURITY.md) · [Português](../pt-BR/SECURITY.md) · [Español](../es/SECURITY.md) · [Français](../fr/SECURITY.md) · [Deutsch](../de/SECURITY.md) · **简体中文** · [日本語](../ja/SECURITY.md) · [한국어](../ko/SECURITY.md)

# 安全政策

MacSpace 是一款免费、开源（MIT）的 macOS App。它以你的普通用户账户运行。对于少数需要管理员权限的操作，它使用
一个你只需批准一次的特权辅助程序。它不会收集任何关于你的数据。本文档准确说明 MacSpace 会触碰你 Mac 上的哪些
内容，以及如何报告问题。

## 报告漏洞

请使用 GitHub 的私密漏洞报告：
[报告漏洞](https://github.com/1architect/macspace-releases/security/advisories/new)。
或发送电子邮件至 **dev@giomantovani.com.br**，附上详细信息和复现步骤。请不要为安全报告提交公开 issue。
你会在几天内收到确认。

哪些情况算数：任何能让其他程序使辅助程序执行你未请求的操作、能让 MacSpace 删除或更改不该动的内容，或能让更新在
没有发布签名的情况下被安装的问题。

## 受支持的版本

安全修复只会进入最新版本。请始终通过**检查更新…**，或 `brew upgrade --cask macspace`（如果 Homebrew 跳过了它，
请加上 `--greedy`，因为 MacSpace 会自行更新），从 [Releases](https://github.com/1architect/macspace-releases/releases/latest)
更新到最新版本。

## MacSpace 在你的 Mac 上做什么

### 网络

MacSpace 建立网络连接只有一个目的：更新。当你选取**检查更新…**（或“设置”中的**立即检查**）时，以及在你开启了
**自动检查更新**的情况下，在运行期间大约每天一次，它会读取与发行版一同托管在 GitHub 上的更新源（`appcast.xml`）。
如果你接受更新，它会从 GitHub Releases 下载新版本。不会发送任何关于你的信息，Sparkle 的可选系统概况功能也未开启。

没有分析，没有遥测，也没有崩溃报告。详情见[隐私政策](PRIVACY.md)。

### 你的数据存储在哪里

一切都保留在你的 Mac 上。MacSpace 的文件位于 `~/Library/Application Support/MacSpace/`、
`~/Library/Logs/MacSpace/`、偏好设置文件 `~/Library/Preferences/com.macspace.app.plist`，以及辅助程序所写入内容所在的
`/Library/Application Support/MacSpace/`。[隐私政策](PRIVACY.md)列出了每个文件。这些都不会被上传到任何地方。

### MacSpace 会删除什么

| 内容 | 位置 | 执行者 |
|---|---|---|
| 已关闭 App 的缓存 | 每个用户的系统缓存文件夹（`/var/folders/…/C`），Apple 自己的缓存除外。`~/Library/Application Support` 中 Chromium 或 Electron 配置文件内的文件夹 `Cache`、`Code Cache`、`GPUCache`、`DawnCache`、`DawnGraphiteCache`、`DawnWebGPUCache`、`GrShaderCache`、`ShaderCache` 和 `CachedData`。 | App，以你的身份 |
| 超过 7 天的诊断和崩溃报告 | `/Library/Logs/DiagnosticReports` 和 `~/Library/Logs/DiagnosticReports`。你无权删除的文件会被跳过。 | App，以你的身份 |
| 未使用的系统资源、已释放的 Apple 智能模型、App 标记为可清除的文件 | macOS 自己的清除服务（CacheDelete）。MacSpace 在一个短暂存在的子进程中请求它，所以那里的失败不会导致 App 崩溃。 | macOS |
| 云文件的本地副本 | 一次一个云端文件夹（`~/Library/CloudStorage/…` 或 iCloud 云盘）。仅限已上传且无冲突的文件。文件仍保留在云端。 | App，以你的身份 |
| 文稿版本历史 | `/System/Volumes/Data/.DocumentRevisions-V100` | 辅助程序 |
| macOS 更新的遗留文件 | `/System/Volumes/Data/macOS Install Data`，仅当比已安装的系统更旧时。`Locked Files` 文件夹会保留。 | 辅助程序 |
| 未完成的壁纸和屏幕保护程序下载 | 直接位于 `/private/var/folders/*/*/T/com.apple.idleassetsd` 中、3 天内没有变化的 `CFNetworkDownload_*.tmp` 文件。仅限普通文件：链接和子文件夹会被拒绝。 | 辅助程序 |
| macOS 检查 App 时生成的副本 | `/var/folders/…/X/<app>.code_sign_clone`，仅当它占有自己的空间（旧版本的）、该 App 已关闭且没有任何内容从中运行时。 | App，以你的身份 |
| 系统日志 | `/private/var/db/diagnostics` 和 `/private/var/db/uuidtext`，使用 Apple 自己的 `log erase --all` 和 `log erase --uuidtext`。 | 辅助程序 |
| 崩溃报告的符号 | `/System/Library/Caches/com.apple.coresymbolicationd` 中的所有内容（文件夹本身保留）；然后停止 `coresymbolicationd`，让它的空间回来。macOS 会重建缓存。 | 辅助程序 |
| 废纸篓 | `~/.Trash` 中的所有内容。已锁定的项目或属于其他账户的项目会保留。 | App，以你的身份 |
| Time Machine 的本地快照 | `tmutil deletelocalsnapshots <date>`，一次一个日期：保留最新的一个，以及最新备份所基于的那一个，其余都删除。备份运行期间绝不执行。 | App，以你的身份 |
| Time Machine 备份磁盘上的备份 | `tmutil delete`，你选择的那些，绝不包括最新的一个，且位于 Time Machine 使用的已连接磁盘上。备份运行期间绝不执行。 | 辅助程序 |

没有任何内容会进入废纸篓。缓存、系统资源和可清除文件会在需要时重建或重新下载，云端副本会在你打开文件时重新下载。
报告、版本历史、更新遗留文件、系统日志、废纸篓中的项目、快照和备份则无法恢复。除了单个 App 缓存的**释放**按钮之外，
所有这些操作都会先请求确认。

### MacSpace 会更改什么（Debloat）

每项更改都会先写入日志，所以可以用**全部启用**或重新开启相应功能来撤销。

| 开关 | 更改内容 | 执行者 |
|---|---|---|
| 个性化广告 | `com.apple.AdLib`，键 `allowApplePersonalizedAdvertising` | App，以你的身份 |
| 改进 Siri 与听写 | `com.apple.assistant.support`，键 `Siri Data Sharing Opt-In Status` | App，以你的身份 |
| 崩溃报告对话框 | 针对 `com.apple.DiagnosticsReporter` 和 `com.apple.ReportGPURestart` 的 launchd 覆盖设置 | App，以你的身份 |
| 与 Apple 共享分析（macOS 正式版） | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`，键 `AutoSubmit` 和 `ThirdPartyDataSubmit` | 辅助程序 |
| Siri AI、视觉智能 | `/Library/Preferences/FeatureFlags/Domain/` 中的功能标志覆盖设置 | 辅助程序 |
| 无响应跟踪（tailspin） | `tailspin disable`，撤销时使用 `tailspin enable` | 辅助程序 |
| 策略（五项；macOS 测试版为六项） | 一个配置描述文件，`com.macspace.policies`（见下文） | 你在“系统设置”中批准 |

如果你不重新开启这些功能就删除 App，这些更改会保留。

### Apple 智能

**Apple 智能**开关会更改 `com.apple.assistant.backedup` 中的键 `Session Language`，即 Siri 的语言。关闭后，
Siri 会使用与系统不同的语言，而你的 Siri 语音（`Output Voice`）保持不变。MacSpace 把两者保存在
`~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` 中，并在你开启 Apple 智能时，或者更改
没有生效时恢复它们。如果开关关闭后 macOS 仍保留这些模型，MacSpace 可能会把语言设为系统语言再改回来，大约需要
一分钟，以便让 macOS 释放它们。如果 Siri 的 iCloud 同步已开启，这些更改也会到达同一 Apple 账户下的其他设备。
MacSpace 无法关闭该同步，它会告诉你在哪里关闭。

### 通话转录

“Siri 与 Apple 智能”中的“通话转录”开关使用 `/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist` 中的
五个固定 TelephonyUtilities 覆盖设置：通话录音、来电筛选、FaceTime 字幕传送，以及 Mac 音频/视频翻译的开关。
经过身份验证的辅助程序会在写入更改前，把原始条目保存到 `/Library/Application Support/MacSpace/phone-features.json`。
更改在重新启动后生效；正在运行的开关会另行检查。重新启用时会恢复这些原始条目，并保留不相关的覆盖设置。
辅助程序会拒绝在 MacSpace 之外被更改的条目，而不是覆盖它。此控制不会安装配置描述文件，也不会更改 Siri 的
Session Language。它的辅助程序操作只接受开/关的意图，不接受任意路径、域或键。

### 功能模型

单独的 Siri 和空间照片开关会在停用功能之前保存你的原始设置。Siri 关闭期间，其保存的语音会被清除；它的
Session Language 会保留。通话转录还会停用本地的录音、来电筛选和字幕设置。原始设置保存在
`~/Library/Application Support/MacSpace/feature-settings/`。

模型请求通过它们所属的 Apple 框架释放，在一个以你的身份运行的、独立的 MacSpace 进程中进行，绝不会在 App 或
辅助程序中进行。该进程在调用每个方法之前，会将其与 MacSpace 审查过的方法进行核对，一旦有任何差异就会停止。
回滚对象会保存在 `~/Library/Application Support/MacSpace/asset-owners/` 下，只有你能读取。这些功能和语言模型的
清理绝不会直接编辑实时的订阅数据库或删除模型载荷。实际的清理使用现有的、有保护措施的 macOS 清理服务。当 Apple
智能的状态无法读取时，以及在 Apple 智能开启期间 macOS 正在下载任何系统资源时，它都会等待；当“听写”处于活动
状态时，它会保留其他账户的请求和共享的语音模型。未使用的语言数据只会在 Apple 智能关闭时释放。

MacSpace 打开期间，明确停用的功能每五分钟检查一次，如果 macOS 再次请求它们的模型，会再次清理其中未使用的部分。
重新启用某项功能或使用 MacSpace 的卸载程序，会恢复保存的设置和模型请求；macOS 可能会再次下载这些模型。被中断
或冲突的所有者操作，会在任何重复请求之前先行检查。这些控制适用于每个 macOS 27 版本；在每次请求之前，独立进程都会
检查它所调用的 Apple 方法。“系统数据”中未使用的语言资源采用一次性清理；该操作不会停用拼写检查或词典。

### 权限

每个提示都由 macOS 处理，所以 MacSpace 永远看不到你的密码。

| 权限 | 位置 | MacSpace 用它做什么 |
|---|---|---|
| 完全磁盘访问 | 系统设置 > 隐私与安全性 | 测量 macOS 保护的文件夹，并读取 Apple 智能的状态 |
| 特权辅助程序 | 系统设置 > 通用 > 登录项与扩展 | 下面列出的操作 |
| 配置描述文件 | 系统设置 > 通用 > 设备管理 | 仅当你停用某项 Debloat 策略时 |
| 通知 | macOS 询问 | 告诉你某件事已完成 |

### 特权辅助程序

辅助程序是一个启动守护进程，`com.macspace.helper`，从 App 内部向 macOS 注册。MacSpace 请求某项操作时，
launchd 会启动它。它以 root 身份运行，并且只接受满足以下代码签名要求的程序的连接，这一点由 macOS 检查：

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

没有这一要求它就拒绝启动。它只运行内置的、有名称的操作。调用方无法向它发送命令。当 App 因更新而被替换时，辅助
程序会察觉并退出，以便新的辅助程序启动。

| 操作 | 作用 | 限制 |
|---|---|---|
| `systemdata.measure` | 文件夹大小 | 只读。仅限 `/private/var`、`/private/tmp`、`/Library`、`/System/Library`、数据宗卷的根目录和 `/opt` 之下，绝不包括个人文件夹。只有大小，没有内容。 |
| `systemdata.versions.delete` | 删除文稿版本历史 | 先停止 `revisiond`，如果 macOS 拒绝则将其暂停。删除存储的内容而不是文件夹，然后重新启动 `revisiond`。如果无法停止它，就什么也不删除。 |
| `systemdata.staged-update.delete` | 删除更新遗留文件 | 仅当该文件夹比已安装的系统更旧时。保留 `Locked Files`。 |
| `systemdata.wallpaper-downloads.delete` | 删除未完成的壁纸和屏幕保护程序下载 | 不接受路径：自己找到 `/private/var/folders/*/*/T/com.apple.idleassetsd`，不跟随链接。只删除直接位于其中、名为 `CFNetworkDownload_*.tmp`、3 天内没有变化的普通文件。 |
| `systemdata.unified-log.erase` | 清除系统日志 | 不接受参数。仅运行 Apple 的 `/usr/bin/log erase --all`，然后运行 `log erase --uuidtext`。 |
| `systemdata.symbolication-cache.delete` | 删除崩溃报告的符号 | 不接受参数。仅限 `/System/Library/Caches/com.apple.coresymbolicationd`，打开时不跟随链接；删除其中的内容，绝不删除文件夹本身，然后停止 `coresymbolicationd`（`kill -TERM`，5 秒后 `-KILL`）。 |
| `timemachine.backups.delete` | 从 Time Machine 备份磁盘删除备份 | 仅限 Time Machine 列为已连接的磁盘，仅限它在那里自己找到的日期，绝不删除最新的备份，备份运行期间或状态未知时绝不执行。运行 `/usr/bin/tmutil delete`。 |
| `debloat.status`、`.apply`、`.revert` | 读取、关闭和开启 Debloat 项目 | 仅限内置目录中的控制标识符，不接受其他内容。 |
| `debloat.removeProfile` | 移除 MacSpace 描述文件 | 仅限标识符 `com.macspace.policies` 和 `com.macspace.policies.…`。其他任何描述文件都会被拒绝。 |
| `siri.orphan-subscriptions.plan`、`.execute` | 查找并移除已不存在的账户所遗留的 Apple 智能订阅 | 先把数据库备份到 `/Library/Application Support/MacSpace/backups/`，在一个事务中更改它，只触碰不匹配任何本地账户的行，并且在账户列表看起来不对时拒绝执行。App 目前没有对应的按钮。 |
| `helper.ping` | 应答，让 App 知道辅助程序在运行 | 无 |

App 包内的命令行工具 `MacSpaceCli` 也可以与辅助程序通信。它由同一团队签名。

### 配置描述文件

Debloat 的策略是只有配置描述文件才能强制执行的设置。MacSpace 构建一个描述文件 `com.macspace.policies`
（显示为 **MacSpace: policies**，组织为“MacSpace”），包含你已关闭的每项策略。它会打开该描述文件，由你在
“系统设置 > 通用 > 设备管理”中批准。批准后会替换之前的描述文件。它没有被标记为不可移除。把最后一项策略重新开启时，
会通过辅助程序将其移除，无需任何批准。你也可以自己在“系统设置”中移除它。

### 代码签名与更新

MacSpace 使用 Apple Developer ID 签名，启用了强化运行时，并已通过 Apple 公证。公证票据已装订到 App 上，所以离线时
也能打开。Sparkle 自己的组件使用同一身份签名。

更新还使用 EdDSA 密钥签名。其公钥位于 MacSpace 内部（`SUPublicEDKey`），Sparkle 在安装之前会用它检查每次下载。
该密钥的私钥部分和签名身份不在本仓库中。没有公钥而构建的 MacSpace 副本永远不会检查更新。

## 验证下载

把 `MacSpace-x.y.z.dmg` 和 `MacSpace-x.y.z.dmg.sha256` 放在同一个文件夹里：

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

然后，在把 MacSpace 拖到“应用程序”之后：

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

你应该会看到 `Authority=Developer ID Application`、`TeamIdentifier=J45ZXS2ZF6`、`runtime` 标志、
`Notarization Ticket=stapled`，并且 `spctl` 应显示 `accepted` 和 `source=Notarized Developer ID`。

## 完全卸载

MacSpace 有一个卸载程序：在菜单栏中选取 **MacSpace** > **关于 MacSpace**，然后点按**卸载…**。它会恢复各个模块的设置，
移除辅助程序，并把 MacSpace 移到废纸篓。如果要手动操作，完整步骤见 [README](README.md#卸载)。简而言之：

1. 在 **Debloat** 中按下**全部启用**。这会移除覆盖设置以及它创建的描述文件。
2. 如果描述文件 **MacSpace: policies** 仍在“系统设置 > 通用 > 设备管理”中，请将其移除。
3. 退出 MacSpace。在“系统设置 > 通用 > 登录项与扩展”中将其关闭，或运行
   `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`。
4. 移除 App：`brew uninstall --cask macspace`，或把 **MacSpace** 拖到废纸篓。
5. 移除它的数据和偏好设置：
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. 在“系统设置 > 隐私与安全性 > 完全磁盘访问权限”中移除 MacSpace。
