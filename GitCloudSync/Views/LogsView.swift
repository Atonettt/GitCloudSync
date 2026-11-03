import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var levelFilter: LogLevel?
    @State private var repoFilter: UUID?
    @State private var selection: SyncLogEntry.ID?
    @State private var confirmClear = false

    private var filtered: [SyncLogEntry] {
        model.logStore.entries.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            if let repoFilter, entry.repositoryID != repoFilter { return false }
            if search.isEmpty { return true }
            return entry.result.localizedCaseInsensitiveContains(search)
                || entry.repositoryName.localizedCaseInsensitiveContains(search)
                || entry.stage.localizedCaseInsensitiveContains(search)
                || (entry.detail?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        let entries = filtered
        VSplitView {
            Table(entries, selection: $selection) {
                TableColumn("时间") { entry in
                    Text(entry.date.formatted(date: .numeric, time: .standard)).monospacedDigit()
                }
                .width(min: 140, ideal: 150)
                TableColumn("仓库", value: \.repositoryName).width(min: 80, ideal: 120)
                TableColumn("阶段", value: \.stage).width(min: 70, ideal: 100)
                TableColumn("结果") { entry in
                    Label(entry.result, systemImage: entry.level.symbol)
                        .foregroundStyle(entry.level == .info ? .primary : entry.level.color)
                        .lineLimit(1)
                }
                .width(min: 200, ideal: 380)
                TableColumn("退出码") { entry in
                    Text(entry.exitCode.map(String.init) ?? "")
                }
                .width(50)
                TableColumn("耗时") { entry in
                    Text(entry.duration.map { String(format: "%.1f 秒", $0) } ?? "")
                }
                .width(60)
            }
            .contextMenu(forSelectionType: SyncLogEntry.ID.self) { ids in
                Button("复制") {
                    let text = entries.filter { ids.contains($0.id) }.map(\.copyText).joined(separator: "\n\n")
                    Clipboard.copy(text)
                }
            }
            .frame(minHeight: 240)

            detailPane(entries.first { $0.id == selection })
                .frame(minHeight: 150)
        }
        .searchable(text: $search, prompt: "搜索日志、错误信息")
        .toolbar {
            ToolbarItemGroup {
                Picker("级别", selection: $levelFilter) {
                    Text("全部级别").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(LogLevel?.some(level))
                    }
                }
                Picker("仓库", selection: $repoFilter) {
                    Text("全部仓库").tag(UUID?.none)
                    ForEach(model.repositories) { repo in
                        Text(repo.displayName).tag(UUID?.some(repo.id))
                    }
                }
                Button {
                    Clipboard.copy(entries.map(\.copyText).joined(separator: "\n\n"))
                } label: {
                    Label("复制全部", systemImage: "doc.on.doc")
                }
                .help("复制当前筛选结果")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.logStore.fileURL])
                } label: {
                    Label("日志文件", systemImage: "folder")
                }
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("清空所有同步日志？", isPresented: $confirmClear) {
            Button("清空日志", role: .destructive) { model.logStore.clear() }
        }
        .navigationTitle("同步日志（\(entries.count)）")
        .frame(minWidth: 760, minHeight: 460)
    }

    @ViewBuilder
    private func detailPane(_ entry: SyncLogEntry?) -> some View {
        if let entry {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(entry.result, systemImage: entry.level.symbol)
                        .foregroundStyle(entry.level.color)
                        .font(.headline)
                    Spacer()
                    Button("复制") { Clipboard.copy(entry.copyText) }
                }
                ScrollView {
                    Text(entry.copyText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        } else {
            Text("选择一条日志查看详细信息")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
