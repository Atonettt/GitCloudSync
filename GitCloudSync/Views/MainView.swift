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
            case .downloadFromGitHub: DownloadFromGitHubView()
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }
}

/// The account at the bottom of the sidebar, like a small name card: the app icon stands in for
/// an account picture, with a dot showing the sign-in state.
struct AuthStatusLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let state = model.auth.state
        let (title, subtitle) = Self.lines(for: state)
        HStack(spacing: 8) {
            AppIconView(size: 28)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(color(for: state))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if !state.isUsable, state != .checking {
                Button("登录") { openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .help(state.summary)
    }

    private static func lines(for state: AuthState) -> (String, String) {
        switch state {
        case .signedIn(let login, let source):
            let via = source == .githubCLI ? "GitHub CLI" : source.displayName
            return (login, String(localized: "已通过 \(via) 登录"))
        case .unverified:
            return ("GitHub", String(localized: "已找到凭据，暂时无法验证"))
        case .signedOut:
            return (String(localized: "未登录 GitHub"), String(localized: "登录后才能同步"))
        case .invalid(_, let message):
            return (String(localized: "GitHub 登录已失效"), message)
        case .checking:
            return ("GitHub", String(localized: "正在检测登录状态…"))
        case .unknown:
            return ("GitHub", String(localized: "尚未检测"))
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

