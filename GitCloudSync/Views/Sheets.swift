import SwiftUI

struct ErrorDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let repoID: UUID

    var body: some View {
        let repo = model.repository(repoID)
        let failure = repo?.lastFailure
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: failure?.mappedStatus.symbol ?? "xmark.octagon")
                    .foregroundStyle(failure?.mappedStatus.color ?? .red)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(repo?.displayName ?? String(localized: "仓库")).font(.title3.bold())
                    Text(failure?.message ?? String(localized: "没有错误信息")).foregroundStyle(.secondary)
                }
            }
            if let failure {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("操作阶段").foregroundStyle(.secondary); Text(failure.stage.displayName) }
                    GridRow { Text("命令").foregroundStyle(.secondary); Text(failure.command.isEmpty ? "—" : failure.command).font(.callout.monospaced()).textSelection(.enabled) }
                    GridRow { Text("退出码").foregroundStyle(.secondary); Text(failure.exitCode.map(String.init) ?? "—") }
                    GridRow { Text("时间").foregroundStyle(.secondary); Text(failure.date.formatted(date: .abbreviated, time: .standard)) }
                }
                Text("Git 输出（stderr）").font(.headline)
                ScrollView {
                    Text(failure.stderr.isEmpty ? String(localized: "（无输出）") : failure.stderr)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("处理建议").font(.headline)
                    Text(failure.suggestion).textSelection(.enabled)
                }

                if let steps = model.runtime[repoID]?.lastSteps, !steps.isEmpty {
                    DisclosureGroup("本次同步执行记录（\(steps.count) 步）") {
                        ScrollView {
                            Text(steps.map(\.line).joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
            HStack {
                if let failure {
                    Button("复制错误信息") { Clipboard.copy(failure.fullReport) }
                    if failure.mappedStatus == .needsAuth {
                        Button("重新登录 GitHub") { dismiss(); openSettings() }
                    }
                }
                Button("打开文件夹") { model.revealInFinder(repoID) }
                Spacer()
                Button("重试同步") {
                    dismiss()
                    model.sync(repoID, trigger: .manualSingle)
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

struct ConflictResolutionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID
    @State private var choices: [String: ConflictChoice] = [:]
    @State private var confirm = false

    var body: some View {
        let repo = model.repository(repoID)
        let files = repo?.conflictFiles ?? []
        let syncing = model.runtime[repoID]?.isSyncing == true

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading) {
                    Text("解决同步冲突 — \(repo?.displayName ?? "")").font(.title3.bold())
                    Text("以下文件在本 Mac 和 GitHub 上都被修改。Word、Excel、PDF、图片等文件无法自动合并，请为每个文件选择保留方式。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            List {
                ForEach(files) { file in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text(file.description).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.revealInFinder(repoID, relativePath: file.path)
                        } label: { Image(systemName: "folder") }
                            .help("在 Finder 中显示本地版本")
                        if file.remoteExists {
                            Button {
                                Task { await model.exportRemoteVersion(repoID, path: file.path) }
                            } label: { Image(systemName: "icloud.and.arrow.down") }
                                .help("导出远程版本到临时文件夹以便比较（不修改仓库）")
                        }
                        Picker("", selection: binding(for: file.path)) {
                            ForEach(ConflictChoice.allCases, id: \.self) { choice in
                                Text(choice.displayName).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 180)

            VStack(alignment: .leading, spacing: 4) {
                Label("「保留两者」：本地版本保持原名，远程版本另存为「文件名 (远程版本 日期).扩展名」——推荐，不会丢失任何内容。", systemImage: "doc.on.doc")
                Label("「保留本地」/「使用远程」：另一方的版本仍保存在 Git 历史中，并会创建备份引用，可以恢复。", systemImage: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("全部保留两者") { setAll(.keepBoth, files) }
                Button("全部保留本地") { setAll(.keepLocal, files) }
                Button("全部使用远程") { setAll(.keepRemote, files) }
                Spacer()
                Button("重新检查并恢复同步") {
                    dismiss()
                    model.recheckAndResume(repoID)
                }
                .help("如果你已在其他工具中处理了冲突，可重新同步检测")
                Button("取消") { dismiss() }
                Button("应用并同步") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || syncing)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .onAppear {
            for file in files where choices[file.path] == nil {
                choices[file.path] = .keepBoth
            }
        }
        .confirmationDialog("确认按所选方式解决 \(files.count) 个冲突？", isPresented: $confirm) {
            Button("应用并同步") {
                let selected = Dictionary(uniqueKeysWithValues: files.map { ($0.path, choices[$0.path] ?? .keepBoth) })
                model.resolveConflicts(repoID, choices: selected)
                dismiss()
            }
        } message: {
            Text(summaryText(files))
        }
    }

    private func binding(for path: String) -> Binding<ConflictChoice> {
        Binding(get: { choices[path] ?? .keepBoth }, set: { choices[path] = $0 })
    }

    private func setAll(_ choice: ConflictChoice, _ files: [ConflictFile]) {
        for file in files { choices[file.path] = choice }
    }

    private func summaryText(_ files: [ConflictFile]) -> String {
        let counts = Dictionary(grouping: files) { choices[$0.path] ?? .keepBoth }.mapValues(\.count)
        let parts = ConflictChoice.allCases.compactMap { c in counts[c].map { String(localized: "\(c.displayName) \($0) 个") } }
        return parts.joined(separator: String(localized: "，")) + String(localized: "。解决前会创建备份引用，然后合并并上传到 GitHub。")
    }
}

struct DeviceFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let flow = model.auth.deviceFlow
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill").font(.system(size: 36)).foregroundStyle(.tint)
            Text("使用 GitHub 账户授权").font(.title3.bold())
            if let flow {
                if !flow.userCode.isEmpty {
                    Text(flow.userCode)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Button("复制验证码") { Clipboard.copy(flow.userCode) }
                        Button("打开 GitHub 授权页") { NSWorkspace.shared.open(flow.verificationURL) }
                    }
                }
                HStack(spacing: 8) {
                    if !flow.failed { ProgressView().controlSize(.small) }
                    Text(flow.statusMessage)
                        .foregroundStyle(flow.failed ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
                if !flow.failed {
                    Text("验证码将于 \(flow.expiresAt.formatted(date: .omitted, time: .shortened)) 过期")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if case .signedIn(let login, _) = model.auth.state {
                Label("已登录 \(login)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                if flow?.failed == true {
                    Button("重试") { model.auth.startDeviceFlow(clientID: model.settings.oauthClientID) }
                }
                Spacer()
                Button(flow == nil ? String(localized: "完成") : String(localized: "取消")) {
                    model.auth.cancelDeviceFlow()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: model.auth.state) { _, state in
            if case .signedIn = state, model.auth.deviceFlow == nil {
                dismiss()
            }
        }
    }
}
