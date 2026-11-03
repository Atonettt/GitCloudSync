# GitSync 架构与同步状态机

## 1. 模块划分

```
GitCloudSync/                 App 目标（SwiftUI / AppKit，仅 App 使用）
├── App/                      入口、AppDelegate（关闭窗口不退出、退出时安全停止）
├── Auth/                     GitHub 认证：Keychain、OAuth Device Flow、GitHub CLI、系统凭据助手
├── Services/                 网络监测、系统通知、登录项（SMAppService）、日志存储
├── ViewModels/AppModel       全局状态（MVVM 的 ViewModel）、调度器、仓库管理
└── Views/                    主窗口、仓库卡片、日志、设置、冲突处理、菜单栏

GitCloudSyncCore/             与 UI 无关的核心逻辑（App 与单元测试共同编译）
├── ProcessRunner             Process 封装：stdin=/dev/null、超时（SIGTERM→SIGKILL）、取消
├── GitEnvironment            查找 git、修正 PATH（/opt/homebrew/bin 等）、禁止交互提示
├── GitClient                 每次调用注入临时凭据助手（令牌只走环境变量，不进 argv/磁盘）
├── RepositoryInspector       本地只读检测：分支、origin、upstream、差异、未完成操作、锁
├── SyncEngine                同步状态机、冲突处理、远程版本导出、历史版本恢复
├── RepositoryCreator         普通文件夹 → 仓库：预览、git init、忽略规则、隐私邮箱、关联 origin；仓库名规则
├── RepositoryRemoval         删除前检查（未提交/未上传/仅在 GitHub 的提交）、GitHub 仓库删除后转为仅本地
├── HistoryBrowser            只读历史查询：文件版本、已删除文件、时间线、恢复预览、导出/另存副本
├── SyncCoordinator (actor)   同仓库互斥 + 多仓库受控并发
├── GitErrorClassifier        stderr → 失败类型 → 中文说明与处理建议
├── IgnoreRules               写入 .git/info/exclude 的托管区块（不改用户 .gitignore）
└── Models / JSONFileStore    配置、日志模型与原子化 JSON 持久化
```

## 2. 单次同步状态机

```
          ┌──────────┐
 trigger →│ pending  │ (同仓库已在运行 → 拒绝重复请求)
          └────┬─────┘
               ▼
          ┌──────────┐  文件夹丢失/非仓库/无 origin/分离 HEAD/index.lock/
          │ checking │──merge·rebase 未完成 ─────────────────────────► failed / conflict
          └────┬─────┘
               ▼  写入忽略规则
          ┌────────────┐ 认证失败 → needsAuth；DNS/连接失败 → networkUnavailable；
          │ downloading│ 5xx → failed(server)；超时 → failed(timeout)
          │ (fetch)    │─────────────────────────────────────────────► (终止，未做任何修改)
          └────┬───────┘
               ▼
          ┌────────────┐ git add -A（排除 >100MB 文件并告警）→ git commit
          │ committing │
          └────┬───────┘
               ▼ behind>0
          ┌────────────┐ ahead==0 → merge --ff-only
          │  merging   │ 否则 → merge --no-edit
          └────┬───────┘ 冲突 → 记录冲突文件 → merge --abort（回到合并前，本地提交完整保留）
               │                                 → conflict（暂停该仓库自动同步）
               ▼ ahead>0
          ┌────────────┐ push（绝不 --force）
          │ uploading  │ 被拒绝(non-fast-forward) → 回到 fetch，最多重试 2 次
          └────┬───────┘
               ▼
       success / noChanges（仅在所有步骤成功后）
```

关键安全原则：

* 本地修改**先提交**再整合远程，任何时刻本地内容都在提交历史中可恢复。
* 冲突时立即 `merge --abort`，工作区回到“本地版本”，不覆盖任何一方。若中止失败，不做任何进一步清理，提示用户。
* 从不执行 `push --force`、`reset --hard`、`clean`、`checkout .`、`stash drop`。
* 用户 / 其他工具留下的 merge、rebase、cherry-pick 未完成状态：只检测和提示，中止操作必须用户二次确认。
* 解决冲突前创建备份引用 `refs/gitcloud-sync/backup/<时间>`；“保留两者”把远程版本另存为 `文件名 (远程版本 时间).扩展名`。

## 3. 认证链

1. App 自己的令牌（OAuth Device Flow 或用户粘贴的 PAT）—— 存 Keychain。
2. GitHub CLI（`gh auth token`）。
3. 系统 Git 凭据助手（osxkeychain / Git Credential Manager）。

对 1、2，App 在每次 git 调用时追加：

```
-c credential.https://github.com.helper=           # 清空 github.com 的助手列表
-c credential.https://github.com.helper=!f() {...}  # 从环境变量读取令牌
```

同时设置 `GIT_TERMINAL_PROMPT=0`、`GCM_INTERACTIVE=never`、`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`、stdin=/dev/null 和超时，保证 git 永远不会因为等待输入而挂起——这就是此前 `git fetch origin main` 在 Xcode 启动环境下认证失败/挂起的根因（PATH 不同、找不到凭据助手、等待终端输入）。

## 4. 历史版本与恢复

* 时间线使用 `git log --first-parent`：每个条目是本机这个文件夹在某次同步后的状态，所以「回到这个时间点」恢复的就是当时的整个文件夹。合并提交按第一父提交显示差异，即「从 GitHub 下载了哪些文件」。
* 单个文件的版本用 `git log --follow`，包括另一台 Mac 的提交和改名前的版本。
* 恢复（`SyncEngine.restore`）在 `SyncCoordinator` 中运行，与同步互斥：

```
预检查（与同步相同，拒绝未完成的 merge 等）
  → fetch（失败且属于网络问题时标记离线，继续）
  → 提交未同步的本地修改
  → 落后时先合并远程（冲突则中止合并、报告冲突，不恢复）
  → 创建备份引用 refs/gitcloud-sync/backup/<时间>
  → 单个文件：git restore --source=<提交> -- <路径>（改过名时取旧名的内容写到新名）
    整个仓库：git restore --source=<提交> --staged --worktree -- :/ ，再撤掉现在属于忽略规则的文件
  → 有变化则提交「GitSync：<Mac> 恢复……」
  → 与同步相同的合并/推送重试；离线时停在本地，报告「网络不可用」
```

不使用 `reset`、`checkout` 整棵树或强制推送；恢复本身是新提交，可以再次恢复。

## 5. 新建 GitHub 仓库

拖入或选择的文件夹先分类（`RepositoryCreator.preview`）：已关联远程 → 直接加入；普通文件夹或无远程的仓库 → 「在 GitHub 上创建仓库」窗口；位于其他仓库内 → 不允许。确认后：

```
GitHub API POST /user/repos（默认私有，不自动初始化）
  └─ 422 同名 → git ls-remote 判断是否为空：空则可选择关联，否则要求改名
→ git init -b main（已是仓库则跳过；确认仓库根目录就是该文件夹）
→ 写入忽略规则；仓库没有本地 user.email 时设置为 GitHub 隐私邮箱
→ git remote add origin <clone_url>（已有不同 origin 时拒绝）
→ 加入列表并立即同步（首次推送 --set-upstream）
```

先调用 API、再改动本地文件夹：API 失败时文件夹保持原样。

## 6. 删除 GitHub 仓库 / 本地文件夹

两项独立，可同时选择（先 GitHub 后本地）。执行期间占用该仓库的同步标记，调度器不会同时同步它。

```
删除 GitHub 仓库：git fetch（只检查，不合并）→ 统计 GitHub 上本机没有的提交并提醒
  → 输入「账号/仓库名」确认 → DELETE /repos/{owner}/{repo}
     403 → 提示授予 delete_repo；404 → 视为已删除
  → 仅删 GitHub 时：git remote rename origin github-deleted-<时间>；git branch --unset-upstream
     暂停该仓库自动同步；之后可「在 GitHub 上创建仓库」重新发布
删除本地文件夹：统计未提交修改与未上传提交并提醒 → FileManager.trashItem（移到废纸篓）→ 从列表移除
```

## 7. 调度

* 全局开关 + 间隔（默认 5 分钟），修改间隔立即重建定时任务。
* 唤醒后 10 秒、网络恢复后 5 秒自动补一次同步。
* `SyncCoordinator` 保证同一仓库不会并发，多仓库默认最多 2 个同时运行。
* 退出时停止调度，等待正在运行的同步最多 30 秒（`applicationShouldTerminate → .terminateLater`）。
