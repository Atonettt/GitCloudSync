# GitCloud Sync 架构与同步状态机

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
├── SyncEngine                同步状态机、冲突处理、远程版本导出
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

## 4. 调度

* 全局开关 + 间隔（默认 5 分钟），修改间隔立即重建定时任务。
* 唤醒后 10 秒、网络恢复后 5 秒自动补一次同步。
* `SyncCoordinator` 保证同一仓库不会并发，多仓库默认最多 2 个同时运行。
* 退出时停止调度，等待正在运行的同步最多 30 秒（`applicationShouldTerminate → .terminateLater`）。
