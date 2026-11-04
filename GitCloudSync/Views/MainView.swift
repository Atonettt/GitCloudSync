import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        RepositoryBrowser()
            .frame(minWidth: 860, minHeight: 560)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        Label("松开以添加文件夹", systemImage: "folder.badge.plus")
                            .font(.title2.bold())
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            guard !folders.isEmpty, model.gitEnvironment != nil else { return false }
            Task { await model.addRepositories(urls: folders) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $model.activeSheet, onDismiss: { model.showNextCreation() }) { sheet in
            switch sheet {
            case .errorDetail(let id): ErrorDetailView(repoID: id)
            case .conflicts(let id): ConflictResolutionView(repoID: id)
            case .createRepository(let url): CreateRepositoryView(folder: url)
            case .deleteRepository(let id, let github, let local): DeleteRepositoryView(repoID: id, deleteOnGitHub: github, deleteLocal: local)
            case .storage(let id): StorageView(repoID: id)
            case .deviceFlow: DeviceFlowView()
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }
}

struct AuthStatusLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let state = model.auth.state
        HStack(spacing: 6) {
            Circle()
                .fill(color(for: state))
                .frame(width: 7, height: 7)
            Text(state.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !state.isUsable, state != .checking {
                Button("登录 GitHub") { openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func color(for state: AuthState) -> Color {
        switch state {
        case .signedIn: .green
        case .unverified: .yellow
        case .checking, .unknown: .gray
        case .signedOut, .invalid: .orange
        }
    }
}

struct EmptyRepositoriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("还没有仓库").font(.title3.bold())
            Text("把文件夹拖到这个窗口，或点下面的按钮选择。\n普通文件夹会自动在 GitHub 上创建同名仓库；已发布的仓库直接加入。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("添加仓库…") { RepositoryPicker.present(model: model) }
                .buttonStyle(.borderedProminent)
                .disabled(model.gitEnvironment == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

struct ProblemBanner: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

