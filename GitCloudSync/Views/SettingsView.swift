import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AccountSettingsView()
                .tabItem { Label("GitHub 账户", systemImage: "person.crop.circle") }
            IgnoreSettingsView()
                .tabItem { Label("忽略规则", systemImage: "eye.slash") }
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .frame(width: 620, height: 500)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("自动同步") {
                Toggle("启用自动同步", isOn: $model.settings.autoSyncEnabled)
                Picker("同步间隔", selection: $model.settings.intervalMinutes) {
                    ForEach(intervalOptions, id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                Stepper("自定义间隔：\(model.settings.intervalMinutes) 分钟",
                        value: $model.settings.intervalMinutes, in: 1...1440)
                Stepper("最多同时同步 \(model.settings.maxConcurrentSyncs) 个仓库",
                        value: $model.settings.maxConcurrentSyncs, in: 1...6)
                Toggle("Mac 唤醒后立即同步", isOn: $model.settings.syncOnWake)
            }
            Section("后台运行") {
                Toggle("登录 macOS 时自动启动", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { enabled in
                        do { try model.loginItem.setEnabled(enabled); loginError = nil }
                        catch { loginError = error.localizedDescription }
                    }
                ))
                Text(loginError ?? model.loginItem.statusText)
                    .font(.caption)
                    .foregroundStyle(loginError == nil ? Color.secondary : Color.red)
                Toggle("在 Dock 中显示图标", isOn: $model.settings.showDockIcon)
                Text("关闭主窗口后，GitSync 会继续在菜单栏中运行并同步。选择菜单栏中的「退出」才会停止。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通知") {
                Toggle("同步失败时通知", isOn: $model.settings.notifyOnFailure)
                Toggle("发生冲突时通知", isOn: $model.settings.notifyOnConflict)
                Toggle("认证失效时通知", isOn: $model.settings.notifyOnAuthProblem)
                Toggle("有文件上传或下载时通知", isOn: $model.settings.notifyOnChanges)
                Text("无变化的同步不会发送通知；同一问题只在首次出现时通知一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loginItem.refresh() }
    }

    private var intervalOptions: [Int] {
        var options = AppSettings.presetIntervals
        if !options.contains(model.settings.intervalMinutes) {
            options.append(model.settings.intervalMinutes)
            options.sort()
        }
        return options
    }
}

struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var tokenError: String?
    @State private var cliError: String?
    @State private var showDeviceFlow = false
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        let auth = model.auth
        Form {
            Section("当前状态") {
                HStack {
                    Text(auth.state.summary)
                    Spacer()
                    Button("重新检测") {
                        Task { busy = true; await auth.refresh(); busy = false }
                    }
                    .disabled(busy || auth.state == .checking)
                }
                if case .unverified(_, let detail) = auth.state {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let checked = auth.lastChecked {
                    Text("上次检测：\(checked.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if auth.hasAppToken {
                    Button("退出登录（删除 GitSync 保存的令牌）", role: .destructive) { auth.signOut() }
                }
            }

            Section("方式一：GitHub CLI（推荐，兼容现有登录）") {
                Text(auth.ghPath.map { "已找到 gh：\($0)" + (auth.ghLoggedIn ? "，已登录" : "，未登录") }
                     ?? "未安装 GitHub CLI。可通过 brew install gh 安装。")
                    .font(.callout)
                HStack {
                    Button("在终端中登录 GitHub CLI…") {
                        do { try auth.openGitHubCLILogin(); cliError = nil }
                        catch { cliError = error.localizedDescription }
                    }
                    Text("完成浏览器授权后点击「重新检测」").font(.caption).foregroundStyle(.secondary)
                }
                if let cliError { Text(cliError).font(.caption).foregroundStyle(.red) }
            }

            Section("方式二：GitHub OAuth 授权（Device Flow）") {
                TextField("OAuth App Client ID", text: $model.settings.oauthClientID)
                    .textFieldStyle(.roundedBorder)
                Text("在 GitHub › Settings › Developer settings › OAuth Apps 新建应用，勾选「Enable Device Flow」，把 Client ID 填在这里（无需 Client Secret）。令牌保存在 macOS 钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("使用浏览器登录 GitHub…") {
                    auth.startDeviceFlow(clientID: model.settings.oauthClientID)
                    showDeviceFlow = true
                }
                .disabled(model.settings.oauthClientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("方式三：个人访问令牌（PAT）") {
                SecureField("ghp_… 或 github_pat_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text("经典令牌需要 repo 权限；细粒度令牌需要对目标仓库授予 Contents: Read and write。令牌只保存在钥匙串中。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("验证并保存") {
                        Task {
                            busy = true
                            tokenError = await auth.signIn(personalToken: token)
                            if tokenError == nil { token = "" }
                            busy = false
                        }
                    }
                    .disabled(token.isEmpty || busy)
                    Link("创建令牌", destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=GitCloud%20Sync")!)
                }
                if let tokenError { Text(tokenError).font(.caption).foregroundStyle(.red) }
            }

            Section("其他") {
                Text("如果以上都未配置，GitSync 会使用系统 Git 已保存的凭据（osxkeychain / Git Credential Manager）或 SSH 密钥。所有 Git 操作都禁止交互式提示，凭据缺失时会明确报错而不是卡住。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showDeviceFlow) {
            DeviceFlowView().environment(model)
        }
    }
}

struct IgnoreSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 200)
                HStack {
                    Button("恢复默认") { text = IgnoreRules.defaultPatterns.joined(separator: "\n") }
                    Spacer()
                    Button("保存") {
                        model.settings.ignorePatterns = text.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                    .keyboardShortcut("s")
                }
            } header: {
                Text("不上传的文件（每行一个，gitignore 语法）")
            } footer: {
                Text("规则写入每个仓库的 .git/info/exclude（仅本机生效，不修改 .gitignore），下次同步时应用。已被 Git 跟踪的文件不受影响。")
            }
            Section("大文件") {
                Stepper("跳过大于 \(model.settings.largeFileLimitMB) MB 的文件",
                        value: $model.settings.largeFileLimitMB, in: 1...100)
                Text("GitHub 拒绝超过 100 MB 的单个文件。超限文件保留在本地、不会被提交，并在仓库卡片上提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { text = model.settings.ignorePatterns.joined(separator: "\n") }
    }
}

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var customPath = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Git") {
                LabeledContent("Git 路径", value: model.gitEnvironment?.gitURL.path ?? "未找到")
                LabeledContent("版本", value: model.gitEnvironment?.version ?? "—")
                HStack {
                    TextField("自定义 git 路径（可选）", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                    Button("应用") {
                        model.settings.customGitPath = customPath.isEmpty ? nil : customPath
                    }
                    Button("重新检测") { Task { await model.detectGit() } }
                }
                if let problem = model.gitProblem {
                    Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("运行环境") {
                LabeledContent("PATH") {
                    Text(model.gitEnvironment?.environment["PATH"] ?? GitEnvironment.buildEnvironment()["PATH"] ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("网络", value: model.isOnline ? "已连接" : "不可用")
                LabeledContent("GitHub CLI", value: model.auth.ghPath ?? "未安装")
            }
            Section("数据") {
                HStack {
                    Button("打开配置文件夹") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.stateFileURL])
                    }
                    Text("配置与日志保存在 ~/Library/Application Support/GitCloudSync").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { customPath = model.settings.customGitPath ?? "" }
    }
}
