# GitSync

把 GitHub 私有仓库当作个人云盘：在 Mac 上管理多个本地 Git 仓库，自动提交、上传、下载，冲突时绝不覆盖任何一方文件。

* Swift 6 · SwiftUI · macOS 14+ · 无第三方依赖
* 架构与同步状态机说明见 [Docs/Architecture.md](Docs/Architecture.md)

## 功能概览

| 功能 | 说明 |
| --- | --- |
| 多仓库管理 | 文件夹选择器添加任意多个仓库（可多选），自动识别分支、origin、upstream、未提交修改、领先/落后提交数、未完成的 merge/rebase。移除只影响列表，不动文件和 GitHub |
| 自动双向同步 | 全局启动/暂停、立即同步全部、单仓库同步与开关；fetch → 提交本地修改 → 合并远程 → push，push 被抢先时自动重试 2 次 |
| 同步间隔 | 1/3/5/10/15/30/60 分钟或自定义（1–1440），默认 5 分钟，运行中修改立即生效 |
| 并发控制 | 同一仓库绝不并发；多个仓库默认最多 2 个同时同步（可设 1–6） |
| GitHub 认证 | GitHub CLI / OAuth Device Flow / 个人访问令牌 / 系统凭据助手 / SSH，自动检测，令牌存钥匙串 |
| 冲突处理 | 检测后立即中止合并，磁盘保留本地版本并暂停该仓库；可按文件选择「保留两者 / 保留本地 / 使用远程」，处理前创建备份引用；可导出远程版本比较 |
| 文件安全 | 不使用 `push --force`、`reset --hard`、`clean`；超过 100 MB 的文件跳过并提示；Office 临时文件、`.DS_Store` 等可配置忽略 |
| 后台运行 | 菜单栏常驻，关闭窗口继续同步；可隐藏 Dock 图标；登录时启动（SMAppService）；唤醒、网络恢复后自动补同步；退出时等待进行中的同步 |
| 日志与通知 | 日志窗口可搜索、按级别/仓库筛选、复制；失败/认证失效/冲突时发系统通知（同一问题只通知一次，无变化不通知） |

## 编译与安装

需要 Xcode 16 或更新版本（工程使用文件夹同步分组 objectVersion 77，本次用 Xcode 27.1 构建）。

**用 Xcode：** 打开 `GitCloudSync.xcodeproj`，选择 scheme `GitCloudSync`，⌘R 运行；⌘U 运行单元测试（scheme `GitCloudSyncTests`）。

**用命令行编译 Release 并安装到「应用程序」：**

```bash
xcodebuild -project GitCloudSync.xcodeproj -scheme GitCloudSync -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/GitCloudSync build
```

```bash
ditto ~/Library/Developer/Xcode/DerivedData/GitCloudSync/Build/Products/Release/GitSync.app /Applications/GitSync.app
```

```bash
open /Applications/GitSync.app
```

**运行测试：**

```bash
xcodebuild -project GitCloudSync.xcodeproj -scheme GitCloudSyncTests -derivedDataPath ~/Library/Developer/Xcode/DerivedData/GitCloudSync test
```

说明：

* 构建输出放在 `~/Library/Developer/Xcode/DerivedData`。如果项目在 iCloud 同步的「桌面」或「文稿」里，不要把构建输出放进项目目录：iCloud 会给产物加上 Finder 元数据，导致代码签名报错 `resource fork, Finder information, or similar detritus not allowed`。

* 应用使用本地 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`），无需开发者账号，可在本机运行。分发给其他 Mac 需要改为你的 Developer ID 并公证。
* **未启用 App Sandbox**：应用需要运行系统 `git`/`gh`，并读写你选择的任意文件夹，沙盒会阻止这些操作。因此无法上架 Mac App Store（这是此类工具的通常做法）。
* 「登录时自动启动」需要把应用放在 `/Applications` 后开启；首次开启时 macOS 可能要求在「系统设置 › 通用 › 登录项」中允许。
* 每次重新编译签名都会变，钥匙串可能询问是否允许访问已保存的令牌，选择「始终允许」即可。

## GitHub 登录（重点）

此前 `git fetch origin main` 认证失败的原因：从 Xcode/Finder 启动的应用 PATH 中没有 `/opt/homebrew/bin`，找不到 `gh` 或凭据助手；git 需要账号密码时又在等待一个不存在的终端，于是失败或挂起。

本版本的处理：

1. 所有 git 调用都设置 `GIT_TERMINAL_PROMPT=0`、`GCM_INTERACTIVE=never`、SSH `BatchMode=yes`、stdin 为 `/dev/null`，并有超时（网络操作 300 秒、本地 120 秒），**不可能**再因为等待输入而挂起；缺少凭据会立即显示「需要认证」和 git 原始报错。
2. PATH 自动补上 `/opt/homebrew/bin`、`/usr/local/bin` 等目录。
3. 获取到令牌后，每次调用临时注入一个只读环境变量的凭据助手（`-c credential.https://github.com.helper=...`），令牌不出现在命令行参数和磁盘上，也不会修改你的全局 git 配置。

在「设置 › GitHub 账户」中任选一种方式：

* **GitHub CLI（推荐）**：已经 `gh auth login` 过就会自动识别。没有的话点「在终端中登录 GitHub CLI…」。
* **OAuth Device Flow**：在 GitHub › Settings › Developer settings › OAuth Apps 新建一个 OAuth App，勾选 **Enable Device Flow**，把 Client ID 填进设置，点「使用浏览器登录」，输入显示的验证码即可。不需要 Client Secret；令牌存入钥匙串。应用不内置任何 Client ID。
* **个人访问令牌**：经典令牌需 `repo` 权限；细粒度令牌需对目标仓库授予 Contents 读写。
* 以上都没有时，使用系统 git 已保存的凭据（osxkeychain / Git Credential Manager）或 SSH 密钥。

凭据失效时，仓库显示「需要认证」，发送通知，并自动重新检测登录状态。

## 使用

1. 点「添加仓库」，选择已经用 GitHub Desktop 发布过的文件夹（例如 `~/Desktop/MacGit`）。
2. 点「启动自动同步」。之后每隔设定的时间自动同步所有开启了自动同步的仓库。
3. 关闭窗口后应用仍在菜单栏运行；完全停止请在菜单栏选择「退出」。

**同时在两台 Mac 上修改了同一个 Word 文件**：仓库进入「存在冲突」并暂停自动同步，磁盘上仍是本机版本，GitHub 上仍是另一台的版本。点「解决冲突…」，推荐选「保留两者」：本机版本保持原名，远程版本另存为 `合同 (远程版本 2026-11-03 1530).docx`，然后上传。

**仓库处于 merge/rebase 未完成状态**（比如在 GitHub Desktop 中处理了一半）：GitSync 只提示，不会自动清理。可以回到 GitHub Desktop 完成，或在「更多 › 中止未完成的 Git 操作…」中确认后中止。

## 数据位置

应用原名 GitCloud Sync。改名为 GitSync 后，Bundle ID、配置文件夹和下列内部名称保持不变，旧版的设置、日志和钥匙串登录可以直接沿用。

* 配置：`~/Library/Application Support/GitCloudSync/state.json`
* 日志：`~/Library/Application Support/GitCloudSync/logs.json`（最多保留 3000 条）
* 忽略规则写入各仓库的 `.git/info/exclude`（只在本机生效，不改 `.gitignore`）
* 冲突备份引用：`refs/gitcloud-sync/backup/<时间>`（可用 `git log refs/gitcloud-sync/backup/...` 查看）

## 项目结构

```
GitCloudSync.xcodeproj
GitCloudSync/          App：入口、认证、系统服务、AppModel、SwiftUI 视图、Assets
GitCloudSyncCore/      与 UI 无关的核心：ProcessRunner、GitEnvironment、GitClient、
                       RepositoryInspector、SyncEngine、SyncCoordinator、错误分类、持久化
GitCloudSyncTests/     单元测试（编译 Core 源码，用临时本地仓库和裸仓库）
Docs/Architecture.md   架构与状态机
tools/                 图标源图 icon-source.png；make_icon.swift 生成旧版图标（macOS 14/15），
                       make_icon_fullbleed.swift 生成 GitCloudSync/AppIcon.icon 用的满版图（macOS 26+，避免灰色底框）
```

## 测试与验证情况

**自动化测试：36 个，全部通过**（XCTest，用临时本地仓库 + 裸仓库模拟 GitHub 和两台 Mac）：

* 首次上传到空远程（自动创建分支并设置 upstream）、上传本地修改、下载远程更新、无变化
* 本地和远程修改不同文件 → 自动合并并上传
* 两边修改同一文件 → 检测冲突、自动中止合并、本地文件不变、本地修改保留为提交、远程不变；再次同步仍安全地报告冲突
* 解决冲突：保留两者（远程版本另存 + 备份引用 + 上传）、使用远程；选择不完整时重新返回冲突列表
* push 被另一台抢先 → 重新 fetch/合并后成功上传（这个测试发现并修复了 `cannot lock ref` 情况下不重试的问题）
* 用户留下的未完成 merge 不被触碰；`index.lock`、文件夹不存在、非 Git 仓库、无 origin
* `.DS_Store`、`~$xxx.docx` 不提交；超限大文件跳过、留在本地并告警
* 网络不可用（DNS 失败）→「网络不可用」，本地修改不丢；认证失败在 30 秒内返回「需要认证」，不挂起
* 进程超时终止、stdin 不阻塞、大量输出不死锁
* 令牌只经环境变量传递，注入的凭据助手确实能把令牌交给 git
* 同一仓库重复同步被拒绝、并发上限生效
* 配置保存后重新加载完整恢复；旧版/缺字段配置可读；中途退出时的临时状态不会被恢复成“同步中”
* stderr 分类（认证、404、网络、5xx、大文件、锁、无关历史、push 被拒绝等）

**手动验证：**

* Debug 与 Release 编译通过，无编译警告（Swift 6 严格并发检查）。
* 用已登录的 GitHub CLI 令牌，按应用的注入方式对一个私有仓库执行 `git ls-remote`：成功；不带凭据时立即失败并报 `terminal prompts disabled`，没有挂起。
* 启动 Release 版：识别到 `/usr/bin/git` 和 GitHub CLI 登录；添加一个真实的私有仓库后第一次同步成功（提交 3 个文件，上传 1 个提交）；主窗口、设置窗口显示正常。

**尚未验证：**

* OAuth Device Flow 实际授权（需要你自己的 OAuth App Client ID）；代码按 GitHub 官方流程实现，处理了 `authorization_pending`、`slow_down`、过期、拒绝。
* 个人访问令牌输入流程、钥匙串保存后重启读取（逻辑与 Device Flow 共用，单独没有手动点过）。
* 真实 GitHub 上的冲突与解决、超过 100 MB 文件被 GitHub 拒绝的完整流程（测试中用本地裸仓库和更小的限制模拟）。
* 登录时启动（需先放进 /Applications）、Mac 休眠唤醒、Wi‑Fi 断开恢复、系统通知外观、退出时等待同步——代码已实现，未做实机长时间测试。
* 菜单栏面板没有截图检查。

## 已知限制

* 已经被 Git 跟踪的文件不受忽略规则影响（Git 本身的规则），需要先在 GitHub Desktop 中从仓库移除。
* 完全退出应用后不会继续同步；需要持续同步请保持菜单栏运行或开启「登录时自动启动」。没有另外做独立的后台辅助进程。
* 不检测「文件正在被 Word 写入」；Word 通常原子保存，若担心可适当增大同步间隔。
* 合并方式为 merge（不是 rebase），历史中会出现「GitSync：合并来自 GitHub 的更新」提交，这是为了在任何失败点都能安全中止。
