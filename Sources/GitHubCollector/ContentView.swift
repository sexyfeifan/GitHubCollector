import SwiftUI
import AppKit
import WebKit

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var detailRecord: RepoRecord?
    @State private var showSettingsDrawer = false
    @State private var showLogSheet = false
    @State private var showFailureSheet = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 340), spacing: 12)]
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                inputPanel

                if vm.isLoading {
                    ProgressView().controlSize(.small)
                }

                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !vm.errorMessage.isEmpty {
                    Text(vm.errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if !vm.queueItems.isEmpty {
                    queuePanel
                }

                categoryPanel

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.pagedRecords) { record in
                            RepoCard(
                                record: record,
                                categoryText: vm.categoryLabel(for: record),
                                openFolder: { vm.openInFinder(record) },
                                openInstaller: { vm.openInstaller(record) },
                                openSource: { vm.openSourcePage(record) },
                                retranslate: { vm.retranslateRecord(record) },
                                openDetail: { detailRecord = record },
                                deleteRecord: { deleteFiles in
                                    vm.deleteRecord(record, deleteFiles: deleteFiles)
                                },
                                isSelected: detailRecord?.id == record.id
                            )
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }

                HStack {
                    Text("第 \(vm.currentPage) / \(vm.totalPages) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("上一页") { vm.prevPage() }
                        .buttonStyle(.bordered)
                        .disabled(vm.currentPage <= 1)
                    Button("下一页") { vm.nextPage() }
                        .buttonStyle(.bordered)
                        .disabled(vm.currentPage >= vm.totalPages)
                }
            }
            .padding(16)
            .frame(minWidth: 1180, minHeight: 780)

            if showSettingsDrawer {
                Divider()
                settingsDrawer
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(vm.appVersionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .sheet(item: $detailRecord) { record in
            RepoDetailView(record: record, categoryText: vm.categoryLabel(for: record)) {
                detailRecord = nil
            } formatOffline: {
                vm.formatRecordOffline(record)
            } retranslate: {
                vm.retranslateRecord(record)
            } refetch: {
                vm.refetchRecord(record)
            }
            .frame(minWidth: 1040, minHeight: 760)
        }
        .sheet(isPresented: $showLogSheet) {
            LogDetailView(logs: vm.realtimeLogs) {
                showLogSheet = false
            }
            .frame(minWidth: 1400, minHeight: 720)
        }
        .sheet(isPresented: $showFailureSheet) {
            FailureHubView(
                all: vm.failedProjects,
                notFound: vm.failed404Projects,
                failed: vm.failedNon404Projects,
                localDetected: vm.localDetectedProjects,
                canRetry: vm.crawlState != .running,
                openURL: vm.openGitHubURL,
                openAll: vm.openGitHubURLs,
                retryAll: vm.retryFailedProjectURLs,
                clearLocal: vm.clearLocalDetectedRecords
            ) {
                showFailureSheet = false
            }
            .frame(minWidth: 980, minHeight: 700)
        }
        .onChange(of: vm.searchQuery) { _ in
            vm.resetPageToFirst()
        }
        .onChange(of: vm.selectedCategory) { _ in
            vm.resetPageToFirst()
        }
        .onChange(of: vm.records.count) { _ in
            vm.ensureValidPage()
        }
        .onChange(of: vm.categoryMode) { _ in
            vm.ensureValidCategorySelection()
            vm.resetPageToFirst()
        }
        .sheet(isPresented: $vm.showReorgPreview) {
            ReorgPreviewView(items: $vm.reorgPreviewItems,
                              onSelectAll: { vm.setAllReorgPreviewItems(true) },
                              onSelectNone: { vm.setAllReorgPreviewItems(false) },
                              onConfirm: { vm.confirmReorganizeFromPreview() },
                              onCancel: { vm.showReorgPreview = false })
            .frame(minWidth: 820, minHeight: 560)
        }
        .animation(.easeInOut(duration: 0.2), value: showSettingsDrawer)
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("导入 GitHub 链接（单个或批量，每行一个）")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    vm.clearInputURLs()
                }
                .buttonStyle(.bordered)
                Button("输入链接") {
                    vm.promptInputLinks()
                }
                .buttonStyle(.borderedProminent)
                Button("设置") {
                    showSettingsDrawer.toggle()
                }
                .buttonStyle(.bordered)
            }

            NativeInputField(
                text: $vm.inputURL,
                placeholder: "粘贴一个或多个 GitHub 链接（可用空格分隔）"
            )
            .frame(height: 26)

            HStack(spacing: 10) {
                Button("粘贴") { vm.pasteFromClipboard() }
                    .buttonStyle(.borderedProminent)

                Button("开始") { vm.startCrawl() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canStartCrawl)

                Button("停止") { vm.stopCrawl() }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canStopCrawl)

                Button("重试失败项") { vm.retryFailedImports() }
                    .buttonStyle(.bordered)
                    .disabled(vm.failedURLs.isEmpty || vm.crawlState == .running)

                Button("同步库") { vm.syncLibrary() }
                    .buttonStyle(.bordered)
                    .disabled(vm.isLoading)
            }
            HStack(spacing: 8) {
                Text("搜索项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("按项目名、分类、简介关键词搜索", text: $vm.searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("抓取精度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(vm.fetchPrecision * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: vm.fetchPrecision, total: 1.0)

                Text("保存路径：\(vm.activeBaseDirPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("目录占用：\(formatBytes(vm.storageUsedBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("本次流量：\(formatBytes(vm.sessionTrafficBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GroupBox("实时日志") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        Button("展开日志") { showLogSheet = true }
                            .buttonStyle(.bordered)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(vm.realtimeLogs.suffix(80).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(logColor(line))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxWidth: .infinity)
                    .clipped()
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var settingsDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设置")
                    .font(.title3).bold()
                Spacer()
                Button("收起") {
                    showSettingsDrawer = false
                }
                .buttonStyle(.bordered)
            }

            Text("GitHub API")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub Token（用于提升 API 配额）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.githubToken)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                HStack {
                    Button("粘贴 GitHub Token") { vm.pasteGitHubTokenFromClipboard() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }

            Divider()

            Text("OpenAI API")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.openAIKey)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                HStack {
                    Button("粘贴 Key") { vm.pasteAPIKeyFromClipboard() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.openAIBaseURL)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.openAIModel)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenAI Token 统计")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Prompt: \(vm.openAIPromptTokens)  Completion: \(vm.openAICompletionTokens)  Total: \(vm.openAITotalTokens)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            Text("下载与导入")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("失败重试次数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $vm.retryCount, in: 1...5) {
                    Text("\(vm.retryCount) 次")
                }
            }


            VStack(alignment: .leading, spacing: 6) {
                Text("软件下载路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.downloadRootPath)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                Button("选择路径") { vm.chooseStorageDirectory() }
                    .buttonStyle(.bordered)
                Text("当前生效路径：\(vm.activeBaseDirPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }


            HStack {
                Spacer()
                Button("保存并扫描") { vm.saveSettings() }
                    .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(10)
    }
    private var queuePanel: some View {
        GroupBox("任务队列") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.queueItems) { item in
                        HStack {
                            Text(item.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(color(for: item.status))
                                .frame(width: 45, alignment: .leading)
                            Text(item.url)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(item.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(4)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped()
        }
    }

    private func color(for status: AppViewModel.QueueItem.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .orange
        case .success: return .green
        case .failed: return .red
        }
    }

    private var categoryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("当前分类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.categories, id: \.self) { c in
                            Button("\(c) (\(vm.countForCategory(c)))") {
                                vm.selectedCategory = c
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(vm.selectedCategory == c ? .accentColor : .gray)
                        }
                    }
                }
                Button("刷新列表") {
                    vm.refreshListFromDisk()
                }
                .buttonStyle(.bordered)
                Button("整理分类") { vm.startReorganizePreview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isLoading)
            }
            if !vm.failedProjects.isEmpty || !vm.localDetectedProjects.isEmpty {
                GroupBox("失败项目汇总（可跳转检查）") {
                    HStack {
                        Text("404项目: \(vm.failed404Projects.count)  失败项目: \(vm.failedNon404Projects.count)  本地待补抓: \(vm.localDetectedProjects.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开失败分拣页") {
                            showFailureSheet = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 4)
                    if vm.failedProjects.isEmpty {
                        Text("当前没有抓取失败项，存在 \(vm.localDetectedProjects.count) 个仅本地识别项目，可在分拣页进行清除或补抓。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(vm.failedProjects) { item in
                                    HStack {
                                        Text(item.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Button("打开 GitHub") {
                                            vm.openGitHubURL(item.url)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    Text(item.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(item.reason)
                                        .font(.caption2)
                                        .foregroundStyle(failureColor(item.type))
                                        .lineLimit(1)
                                    Divider()
                                }
                            }
                            .padding(4)
                        }
                        .frame(height: 120)
                    }
                }
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("404") || lower.contains("不存在") {
            return .orange
        }
        if lower.contains("超时") || lower.contains("timed out") {
            return .pink
        }
        if lower.contains("失败") || lower.contains("异常") || lower.contains("error") {
            return .red
        }
        if lower.contains("跳过") {
            return .yellow
        }
        if lower.contains("下载中") || lower.contains("下载链接") {
            return .blue
        }
        return .secondary
    }

    private func failureColor(_ type: FailedReasonType) -> Color {
        switch type {
        case .notFound404: return .orange
        case .timeout: return .pink
        case .fetchFailed: return .red
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let b = Double(bytes)
    if b < 1024 { return String(format: "%.0fB", b) }
    if b < 1024 * 1024 { return String(format: "%.1fKB", b / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.1fMB", b / (1024 * 1024)) }
    return String(format: "%.2fGB", b / (1024 * 1024 * 1024))
}

private struct RepoCard: View {
    let record: RepoRecord
    let categoryText: String
    let openFolder: () -> Void
    let openInstaller: () -> Void
    let openSource: () -> Void
    let retranslate: () -> Void
    let openDetail: () -> Void
    let deleteRecord: (Bool) -> Void
    let isSelected: Bool

    @State private var showDeletePanel = false
    @State private var isHovering = false
    private let titleFontSize: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.projectName)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(record.releaseTag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(record.fullName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(record.summaryZH)
                .font(.subheadline)
                .lineLimit(2)


            HStack(spacing: 12) {
                Label(categoryText, systemImage: "square.grid.2x2")
                Label("★ \(record.stars)", systemImage: "star")
                Label(record.language, systemImage: "curlybraces")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("文件：\(record.releaseAssetName)")
                .font(.caption)
                .lineLimit(1)

            HStack {
                Button("GitHub", action: openSource)
                    .disabled(record.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("打开目录", action: openFolder)
            }
            .buttonStyle(.bordered)

            DisclosureGroup("删除项目", isExpanded: $showDeletePanel) {
                HStack {
                    Button("仅删除记录") { deleteRecord(false) }
                        .buttonStyle(.bordered)
                    Button("删除记录+本地文件") { deleteRecord(true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!record.hasDownloadAsset)
                }
                .padding(.top, 4)
            }
            .font(.caption)

            if !record.localPath.isEmpty {
                Text(record.localPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: isHovering ? 6 : 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke((isHovering || isSelected) ? Color.accentColor.opacity(0.7) : Color.gray.opacity(0.25), lineWidth: (isHovering || isSelected) ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { openDetail() }
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering } }
        .clipped()
    }
}

private struct RepoDetailView: View {
    let record: RepoRecord
    let categoryText: String
    let onClose: () -> Void
    let formatOffline: () -> Void
    @State private var renderMarkdown = true
    @State private var showZHReleaseNotes = false
    @State private var showFormattedZH = false
    @State private var showSetupGuide = false
    let retranslate: () -> Void
    let refetch: () -> Void
    @State private var showENDescription = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.projectName)
                        .font(.title2).bold()
                    Text(record.fullName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("版本：\(record.releaseTag)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("关闭") {
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 14) {
                Label(categoryText, systemImage: "square.grid.2x2")
                Label("★ \(record.stars)", systemImage: "star")
                Label(record.language, systemImage: "curlybraces")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if record.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("该项目来自本地目录扫描，尚未抓取到 GitHub 仓库信息。可点击“重新抓取”补录仓库链接。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Picker("显示模式", selection: $renderMarkdown) {
                    Text("渲染").tag(true)
                    Text("原文").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
            }

            // 标题下方排列操作：GitHub / 打开目录 / 重新抓取 / 重新翻译 / 离线排版
            HStack(spacing: 10) {
                Button("GitHub") {
                    if let url = URL(string: record.sourceURL), !record.sourceURL.isEmpty {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(record.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("打开目录") {
                    if !record.localPath.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.localPath)])
                    } else if !record.infoFilePath.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.infoFilePath)])
                    }
                }
                .buttonStyle(.bordered)
                Button("重新抓取") { refetch() }
                .buttonStyle(.borderedProminent)
                Button("重新翻译") { retranslate() }
                .buttonStyle(.bordered)
                Button("离线排版") { formatOffline() }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !record.previewImagePath.isEmpty {
                        LocalPreviewImage(path: record.previewImagePath)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    section(
                        "简介（中文）",
                        renderMarkdown
                            ? (record.descriptionZH.isEmpty ? "暂无中文简介" : record.descriptionZH)
                            : (record.descriptionEN.isEmpty ? "暂无 README 原文" : record.descriptionEN),
                        renderMarkdown: renderMarkdown,
                        height: 360
                    )
                    DisclosureGroup("更新说明", isExpanded: $showZHReleaseNotes) {
                        section(
                            "更新说明",
                            record.releaseNotesZH.isEmpty ? "暂无中文更新说明" : record.releaseNotesZH,
                            renderMarkdown: renderMarkdown
                        )
                    }
                    if !record.formattedZH.isEmpty {
                        DisclosureGroup("离线排版（中文）", isExpanded: $showFormattedZH) {
                            section(
                                "离线排版（中文）",
                                record.formattedZH,
                                renderMarkdown: renderMarkdown
                            )
                        }
                    }
                    if !record.setupGuideEN.isEmpty {
                        DisclosureGroup("搭建教程（Docker/Compose）", isExpanded: $showSetupGuide) {
                            section(
                                "搭建教程（Docker/Compose）",
                                record.setupGuideEN,
                                renderMarkdown: true
                            )
                        }
                    }
                    DisclosureGroup("README.md", isExpanded: $showENDescription) {
                        section(
                            "README.md",
                            combinedReadmeMarkdown,
                            renderMarkdown: renderMarkdown
                        )
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
    }

    private var combinedReadmeMarkdown: String {
        let readme = record.descriptionEN.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = record.releaseNotesEN.trimmingCharacters(in: .whitespacesAndNewlines)

        var chunks: [String] = []
        if !readme.isEmpty {
            chunks.append(readme)
        }
        if !notes.isEmpty {
            chunks.append("\n\n---\n\n## Release Notes\n\n" + notes)
        }
        if chunks.isEmpty {
            return "暂无 README 原文与更新记录。"
        }
        return chunks.joined(separator: "")
    }

    private func section(_ title: String, _ text: String, renderMarkdown: Bool, height: CGFloat = 220) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if renderMarkdown {
                StyledMarkdownView(markdown: text)
                    .frame(height: height)
            } else {
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: height)
            }
            Divider()
        }
    }
}

private struct LocalPreviewImage: View {
    let path: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.controlBackgroundColor))
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            }
        }
    }
}

private struct LogDetailView: View {
    let logs: [String]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时日志详情")
                    .font(.title3).bold()
                Spacer()
                Button("关闭") { onClose() }
                    .buttonStyle(.borderedProminent)
            }

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(logColor(line))
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                }
                .frame(minWidth: 1500, alignment: .leading)
                .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }

    private func logColor(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("404") || lower.contains("不存在") {
            return .orange
        }
        if lower.contains("超时") || lower.contains("timed out") {
            return .pink
        }
        if lower.contains("失败") || lower.contains("异常") || lower.contains("error") {
            return .red
        }
        if lower.contains("下载中") || lower.contains("下载链接") {
            return .blue
        }
        return .secondary
    }
}

private struct FailureHubView: View {
    let all: [AppViewModel.FailedProject]
    let notFound: [AppViewModel.FailedProject]
    let failed: [AppViewModel.FailedProject]
    let localDetected: [RepoRecord]
    let canRetry: Bool
    let openURL: (String) -> Void
    let openAll: ([String]) -> Void
    let retryAll: ([String]) -> Void
    let clearLocal: ([String]) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("失败项目分拣")
                    .font(.title3).bold()
                Spacer()
                Button("关闭") { onClose() }
                    .buttonStyle(.borderedProminent)
            }

            Text("总计 \(all.count) 项；404项目 \(notFound.count) 项；失败项目 \(failed.count) 项；本地待补抓 \(localDetected.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("404项目") {
                failureList(notFound, accent: .orange)
            }
            GroupBox("失败项目") {
                failureList(failed, accent: .red)
            }
            GroupBox("本地待补抓项目") {
                localDetectedList(localDetected)
            }
        }
        .padding(16)
    }

    private func failureList(_ items: [AppViewModel.FailedProject], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("共 \(items.count) 项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("一键重试") {
                    retryAll(items.map(\.url))
                }
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty || !canRetry)
                Button("一键打开所有 GitHub") {
                    openAll(items.map(\.url))
                }
                .buttonStyle(.bordered)
                .disabled(items.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text("暂无")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .top) {
                            Text(item.name)
                                .font(.caption)
                            Spacer(minLength: 8)
                            Button("打开 GitHub") {
                                openURL(item.url)
                            }
                            .buttonStyle(.bordered)
                        }
                        Text(item.url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("失败原因：\(item.reason)")
                            .font(.caption2)
                            .foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }
                }
                .padding(4)
            }
            .frame(height: 160)
        }
    }

    private func localDetectedList(_ items: [RepoRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("共 \(items.count) 项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("一键清除") {
                    clearLocal(items.map(\.id))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(items.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text("暂无")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .top) {
                            Text(item.projectName)
                                .font(.caption)
                            Spacer(minLength: 8)
                            Button("清除") {
                                clearLocal([item.id])
                            }
                            .buttonStyle(.bordered)
                        }
                        Text(item.fullName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("原因：该项目仅由本地目录扫描识别，尚未抓取到 GitHub 仓库地址。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }
                }
                .padding(4)
            }
            .frame(height: 140)
        }
    }
}

private struct MarkdownRenderText: View {
    let text: String

    var body: some View {
        if let attr = try? AttributedString(markdown: text) {
            Text(attr)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

private struct StyledMarkdownView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(htmlTemplate(from: markdown), baseURL: nil)
    }

    private func htmlTemplate(from markdown: String) -> String {
        let htmlBody = markdownToHTML(markdown)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
          --ink: #0f172a;
          --muted: #64748b;
          --border: #e2e8f0;
          --code-bg: #f8fafc;
          --accent: #0369a1;
        }
        body {
          margin: 0;
          padding: 4px 2px 8px 2px;
          background: transparent;
          color: var(--ink);
          font-family: "SF Pro Text", "PingFang SC", -apple-system, sans-serif;
          line-height: 1.68;
          font-size: 14px;
        }
        h1,h2,h3,h4 {
          color: #0f172a;
          margin: 16px 0 8px;
          line-height: 1.3;
          letter-spacing: 0.2px;
        }
        h1 { font-size: 22px; }
        h2 { font-size: 18px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
        h3 { font-size: 16px; }
        p { margin: 8px 0; color: var(--ink); }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
          background: #f1f5f9;
          border: 1px solid var(--border);
          border-radius: 6px;
          padding: 1px 6px;
          color: #0f172a;
          font-family: "SF Mono", Menlo, monospace;
          font-size: 12px;
        }
        pre {
          margin: 12px 0;
          padding: 12px;
          background: var(--code-bg);
          border: 1px solid var(--border);
          border-radius: 6px;
          overflow: auto;
        }
        pre code {
          background: transparent;
          border: none;
          padding: 0;
          color: #1e293b;
          font-size: 12px;
          line-height: 1.6;
        }
        blockquote {
          margin: 12px 0;
          padding: 10px 12px;
          border-left: 4px solid var(--accent);
          background: #f8fafc;
          color: #334155;
          border-radius: 0 6px 6px 0;
        }
        ul, ol { margin: 8px 0 8px 18px; }
        li { margin: 4px 0; }
        table {
          width: 100%;
          border-collapse: collapse;
          margin: 12px 0;
          border: 1px solid var(--border);
          border-radius: 8px;
          overflow: hidden;
        }
        th, td {
          border: 1px solid var(--border);
          padding: 8px 10px;
          text-align: left;
          vertical-align: top;
        }
        th { background: #f8fafc; color: #0f172a; }
        hr { border: none; border-top: 1px solid var(--border); margin: 16px 0; }
        </style>
        </head>
        <body>\(htmlBody)</body>
        </html>
        """
    }

    private func markdownToHTML(_ source: String) -> String {
        var s = escapeHTML(source)

        s = s.replacingOccurrences(of: "\r\n", with: "\n")

        // fenced code blocks
        if let regex = try? NSRegularExpression(pattern: "```([\\s\\S]*?)```") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: "<pre><code>$1</code></pre>")
        }

        // headings
        let headingRules: [(String, String)] = [
            ("(?m)^######\\s+(.*)$", "<h4>$1</h4>"),
            ("(?m)^#####\\s+(.*)$", "<h4>$1</h4>"),
            ("(?m)^####\\s+(.*)$", "<h3>$1</h3>"),
            ("(?m)^###\\s+(.*)$", "<h3>$1</h3>"),
            ("(?m)^##\\s+(.*)$", "<h2>$1</h2>"),
            ("(?m)^#\\s+(.*)$", "<h1>$1</h1>")
        ]
        for (pat, tpl) in headingRules {
            if let regex = try? NSRegularExpression(pattern: pat) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: tpl)
            }
        }

        // blockquote
        if let regex = try? NSRegularExpression(pattern: "(?m)^>\\s?(.*)$") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: "<blockquote>$1</blockquote>")
        }

        // inline styles
        s = replaceRegex(s, "\\*\\*(.*?)\\*\\*", "<strong>$1</strong>")
        s = replaceRegex(s, "\\*(.*?)\\*", "<em>$1</em>")
        s = replaceRegex(s, "`([^`]+)`", "<code>$1</code>")
        s = replaceRegex(s, "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", "<a href=\"$2\">$1</a>")

        // unordered list
        s = replaceRegex(s, "(?m)^[-\\*]\\s+(.*)$", "<li>$1</li>")
        s = s.replacingOccurrences(of: "(?s)(<li>.*?</li>\\n?)+", with: { block in
            "<ul>\(block)</ul>"
        })

        // horizontal rule
        s = replaceRegex(s, "(?m)^---+$", "<hr/>")

        // paragraph wrapping (skip existing block tags)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            let lower = trimmed.lowercased()
            let startsWithBlock = ["<h", "<pre", "<ul", "<ol", "<li", "<blockquote", "<hr", "<table", "<tr", "<th", "<td", "</"]
                .contains(where: { lower.hasPrefix($0) })
            if startsWithBlock {
                out.append(trimmed)
            } else {
                out.append("<p>\(trimmed)</p>")
            }
        }
        return out.joined(separator: "\n")
    }

    private func replaceRegex(_ input: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return regex.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: input.utf16.count), withTemplate: template)
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension String {
    func replacingOccurrences(of pattern: String, with transformer: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return self }
        let ns = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return self }
        var result = self
        for m in matches.reversed() {
            let part = (result as NSString).substring(with: m.range)
            let replaced = transformer(part)
            result = (result as NSString).replacingCharacters(in: m.range, with: replaced)
        }
        return result
    }
}


private struct ReorgPreviewView: View {
    @Binding var items: [AppViewModel.ReorgPreviewItem]
    let onSelectAll: () -> Void
    let onSelectNone: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("预览整理（\(items.count) 项）").font(.title3).bold()
                Spacer()
                Button("全选") { onSelectAll() }
                Button("全不选") { onSelectNone() }
                Button("取消") { onCancel() }.buttonStyle(.bordered)
                Button("开始整理") { onConfirm() }.buttonStyle(.borderedProminent)
            }
            Table(items) {
                TableColumn("选择") { item in
                    Toggle("", isOn: binding(for: item).selected).labelsHidden()
                }.width(50)
                TableColumn("项目") { item in Text(item.name).lineLimit(1) }
                TableColumn("当前分类") { item in Text(item.currentCategory).foregroundStyle(.secondary) }
                TableColumn("目标分类") { item in Text(item.targetCategory).foregroundColor(.accentColor) }
            }
        }
        .padding(16)
    }

    private func binding(for item: AppViewModel.ReorgPreviewItem) -> Binding<AppViewModel.ReorgPreviewItem> {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return .constant(item) }
        return $items[idx]
    }
}
