import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum CategoryMode: String, CaseIterable {
        case packageOnly
        case typeBased

        var title: String {
            switch self {
            case .packageOnly: return "按安装包"
            case .typeBased: return "按项目类型"
            }
        }
    }

    enum CrawlState {
        case idle
        case running
        case paused
    }

    struct QueueItem: Identifiable {
        enum Status: String {
            case pending = "待处理"
            case running = "处理中"
            case success = "成功"
            case failed = "失败"
        }

        let id = UUID()
        let url: String
        var status: Status
        var detail: String
    }

    struct FailedProject: Identifiable {
        let id = UUID()
        let name: String
        let url: String
        let reason: String
        let type: FailedReasonType
    }

    enum ImportError: Error, LocalizedError {
        case noDownloadAssetSkipped

        var errorDescription: String? {
            switch self {
            case .noDownloadAssetSkipped:
                return "该项目没有可下载安装包，且当前设置未开启“纳入无安装包项目”。"
            }
        }
    }

    enum ImportSkipError: Error, LocalizedError {
        case alreadyExists(String)
        case staleProject(lastUpdated: String)
        case closedProject

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let name):
                return "本地已存在项目，已跳过：\(name)"
            case .staleProject(let lastUpdated):
                return "项目最近 3 年无更新（最后更新：\(lastUpdated)），已跳过。"
            case .closedProject:
                return "项目已归档或禁用，已跳过。"
            }
        }
    }

    @Published var inputURL: String = ""
    @Published var isLoading = false
    @Published var statusMessage: String = ""
    @Published var errorMessage: String = ""
    @Published var records: [RepoRecord] = []
    @Published var selectedCategory: String = "全部"
    @Published var searchQuery: String = ""
    @Published var currentPage: Int = 1

    @Published var githubToken: String = ""
    @Published var openAIKey: String = ""
    @Published var openAIBaseURL: String = "https://api.openai.com/v1"
    @Published var openAIModel: String = "gpt-4.1-mini"
    @Published var retryCount: Int = 2
    @Published var downloadRootPath: String = ""
    @Published var includeNoPackageProjects: Bool = true
    @Published var categoryMode: CategoryMode = .typeBased
    @Published var onlyMacOSAssets: Bool = false
    @Published var sortOption: SortOption = .recent
    @Published var minStars: Int = 0
    @Published var languageFilter: String = ""
    @Published var excludeForks: Bool = false
    enum SortOption: String, CaseIterable { case recent, stars, name }
    var sortTitle: String { switch sortOption { case .recent: return "最近更新"; case .stars: return "Stars"; case .name: return "名称" } }

    @Published var queueItems: [QueueItem] = []
    @Published var failedURLs: [String] = []
    @Published var failedProjects: [FailedProject] = []
    @Published var fetchPrecision: Double = 0
    @Published var realtimeLogs: [String] = []

    // Reorg preview
    struct ReorgPreviewItem: Identifiable {
        let id: String
        var selected: Bool
        let name: String
        let currentCategory: String
        let targetCategory: String
    }
    @Published var showReorgPreview: Bool = false
    @Published var reorgPreviewItems: [ReorgPreviewItem] = []
    @Published var crawlState: CrawlState = .idle
    @Published var sessionTrafficBytes: Int64 = 0
    @Published var totalTrafficBytes: Int64 = 0
    @Published var openAIPromptTokens: Int = 0
    @Published var openAICompletionTokens: Int = 0
    private var downloadLogTick: [String: Date] = [:]
    private var queuedURLs: [String] = []
    private var currentQueueIndex: Int = 0
    private var pauseRequested = false
    private var stopRequested = false
    private var queueTask: Task<Void, Never>?
    private var knownRecordIDs: Set<String> = []
    private var currentProjectName: String = ""

    private let github = GitHubService()
    private let translator = TranslatorService()
    private let summarizer = SummarizerService()
    private let classifier = ClassifierService()
    private let setupGuideExtractor = SetupGuideExtractor()
    private let layoutFormatter = LayoutFormatterService()
    private let downloader = DownloadService()
    private let storage = StorageService()
    private let settings = SettingsStore()

    init() {
        let s = settings.load()
        githubToken = s.githubToken
        openAIKey = s.openAIKey
        openAIBaseURL = s.openAIBaseURL
        openAIModel = s.openAIModel
        retryCount = s.retryCount
        downloadRootPath = s.downloadRootPath
        includeNoPackageProjects = s.includeNoPackageProjects
        categoryMode = CategoryMode(rawValue: s.categoryModeRaw) ?? .typeBased
        onlyMacOSAssets = s.onlyMacOSAssets
        loadSettingsFromSelectedDirectoryIfAvailable()
        totalTrafficBytes = settings.loadTotalTrafficBytes()
        openAIPromptTokens = settings.loadOpenAITotalPromptTokens()
        openAICompletionTokens = settings.loadOpenAITotalCompletionTokens()
        reloadRecords()
    }

    var appVersionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(v) (\(b))"
    }

    var failed404Projects: [FailedProject] {
        failedProjects.filter { $0.type == .notFound404 }
    }

    var failedTimeoutProjects: [FailedProject] {
        failedProjects.filter { $0.type == .timeout }
    }

    var failedOtherProjects: [FailedProject] {
        failedProjects.filter { $0.type == .fetchFailed }
    }

    var openAITotalTokens: Int { openAIPromptTokens + openAICompletionTokens }


    var categories: [String] {
        // 以下载目录的一级文件夹为准，保证与磁盘结构对齐
        let base = activeBaseDir
        var set = Set<String>()
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for u in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    set.insert(u.lastPathComponent)
                }
            }
        }
        if set.isEmpty {
            set = Set(records.map { r in categoryLabel(for: r) })
        }
        var arr = Array(set).sorted()
        if let idx = arr.firstIndex(of: "未分类") {
            arr.remove(at: idx)
            arr.append("未分类")
        }
        return ["全部"] + arr
    }
    var filteredRecords: [RepoRecord] {
        var categoryFiltered: [RepoRecord]
        if selectedCategory == "全部" {
            categoryFiltered = records
        } else {
            categoryFiltered = records.filter { categoryLabel(for: $0) == selectedCategory }
        }

        let key = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty {
            categoryFiltered = categoryFiltered.filter { r in
                r.projectName.lowercased().contains(key) ||
                r.fullName.lowercased().contains(key) ||
                categoryLabel(for: r).lowercased().contains(key) ||
                r.summaryZH.lowercased().contains(key)
            }
        }
        if minStars > 0 { categoryFiltered = categoryFiltered.filter { $0.stars >= minStars } }
        if !languageFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            let l = languageFilter.lowercased()
            categoryFiltered = categoryFiltered.filter { $0.language.lowercased().contains(l) }
        }
        if excludeForks { categoryFiltered = categoryFiltered.filter { !$0.isFork } }
        switch sortOption {
        case .recent: return categoryFiltered.sorted { $0.updatedAt > $1.updatedAt }
        case .stars: return categoryFiltered.sorted { $0.stars > $1.stars }
        case .name: return categoryFiltered.sorted { $0.projectName.lowercased() < $1.projectName.lowercased() }
        }
    }
    func categoryLabel(for record: RepoRecord) -> String {
        if let folder = folderCategory(for: record), !folder.isEmpty {
            return folder
        }
        return record.category
    }

    func ensureValidCategorySelection() {
        if !categories.contains(selectedCategory) {
            selectedCategory = "全部"
        }
    }

    func countForCategory(_ category: String) -> Int {
        if category == "全部" { return records.count }
        return records.filter { categoryLabel(for: $0) == category }.count
    }

    func folderCategory(for record: RepoRecord) -> String? {
        let basePath = (record.storageRootPath.isEmpty ? activeBaseDir.path : record.storageRootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !basePath.isEmpty else { return nil }

        let candidates = [record.localPath, record.infoFilePath]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let baseComponents = URL(fileURLWithPath: basePath).standardizedFileURL.pathComponents
        for path in candidates {
            let fileComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard fileComponents.count > baseComponents.count else { continue }
            if Array(fileComponents.prefix(baseComponents.count)) == baseComponents {
                let category = fileComponents[baseComponents.count]
                if !category.isEmpty {
                    return category
                }
            }
        }
        return nil
    }

    var pageSize: Int { 12 }

    var totalPages: Int {
        let count = filteredRecords.count
        if count == 0 { return 1 }
        return Int(ceil(Double(count) / Double(pageSize)))
    }

    var pagedRecords: [RepoRecord] {
        let items = filteredRecords
        let safePage = min(max(currentPage, 1), totalPages)
        let start = (safePage - 1) * pageSize
        guard start < items.count else { return [] }
        let end = min(start + pageSize, items.count)
        return Array(items[start..<end])
    }

    var activeBaseDirPath: String {
        storage.resolvedBaseDir(customPath: downloadRootPath).path
    }

    var canStartCrawl: Bool {
        if crawlState == .running { return false }
        if crawlState == .paused { return !queuedURLs.isEmpty }
        return !inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPauseCrawl: Bool { crawlState == .running }
    var canStopCrawl: Bool { crawlState != .idle }

    func nextPage() {
        currentPage = min(currentPage + 1, totalPages)
    }

    func prevPage() {
        currentPage = max(currentPage - 1, 1)
    }

    func resetPageToFirst() {
        currentPage = 1
    }

    func ensureValidPage() {
        currentPage = min(max(currentPage, 1), totalPages)
    }

    func saveSettings() {
        let current = currentSettings()
        settings.save(current)
        saveSettingsToCurrentDirectory(current)
        reloadRecords()
        statusMessage = "设置已保存。"
    }

    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        let value = pb.string(forType: .string)
            ?? pb.string(forType: .URL)
            ?? pb.string(forType: .fileURL)

        if let text = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputURL = text
            statusMessage = "已从剪贴板粘贴内容。"
        } else {
            errorMessage = "剪贴板没有可用文本。"
        }
    }

    func pasteAPIKeyFromClipboard() {
        let pb = NSPasteboard.general
        let value = pb.string(forType: .string)
            ?? pb.string(forType: .URL)
            ?? pb.string(forType: .fileURL)

        if let text = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openAIKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "已粘贴 API Key。"
        } else {
            errorMessage = "剪贴板没有可用文本。"
        }
    }

    func pasteGitHubTokenFromClipboard() {
        let pb = NSPasteboard.general
        let value = pb.string(forType: .string)
            ?? pb.string(forType: .URL)
            ?? pb.string(forType: .fileURL)

        if let text = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            githubToken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "已粘贴 GitHub Token。"
        } else {
            errorMessage = "剪贴板没有可用文本。"
        }
    }

    func clearInputURLs() {
        inputURL = ""
        statusMessage = "已清空输入内容。"
    }

    func promptInputLinks() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "输入 GitHub 链接"
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.center()

        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = root

        let hint = NSTextField(labelWithString: "支持单个或多个链接（空格或换行分隔），也支持 stars 页面链接。")
        hint.frame = NSRect(x: 20, y: 300, width: 640, height: 20)
        hint.textColor = .secondaryLabelColor
        root.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: 640, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = inputURL
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        root.addSubview(scroll)

        final class ModalAction: NSObject {
            var response: NSApplication.ModalResponse = .abort
            weak var panel: NSPanel?
            init(panel: NSPanel) { self.panel = panel }
            @MainActor
            @objc func okAction() {
                response = .OK
                NSApp.stopModal(withCode: .OK)
                panel?.orderOut(nil)
            }
            @MainActor
            @objc func cancelAction() {
                response = .cancel
                NSApp.stopModal(withCode: .cancel)
                panel?.orderOut(nil)
            }
        }

        let action = ModalAction(panel: panel)

        let ok = NSButton(title: "确定", target: action, action: #selector(ModalAction.okAction))
        ok.frame = NSRect(x: 500, y: 20, width: 80, height: 30)
        ok.bezelStyle = .rounded
        root.addSubview(ok)

        let cancel = NSButton(title: "取消", target: action, action: #selector(ModalAction.cancelAction))
        cancel.frame = NSRect(x: 590, y: 20, width: 70, height: 30)
        cancel.bezelStyle = .rounded
        root.addSubview(cancel)

        panel.initialFirstResponder = textView
        panel.makeFirstResponder(textView)
        panel.makeKeyAndOrderFront(nil)

        let response = NSApp.runModal(for: panel)
        if response == .OK || action.response == .OK {
            inputURL = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inputURL.isEmpty {
                statusMessage = "已从输入弹窗写入链接。"
            }
        }
    }

    func chooseStorageDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择软件下载和索引存储目录"
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            downloadRootPath = url.path
            loadSettingsFromSelectedDirectoryIfAvailable()
            saveSettings()
        }
    }

    func startCrawl() {
        if crawlState == .running { return }
        if crawlState == .paused, !queuedURLs.isEmpty {
            resumeCrawl()
            return
        }

        let urls = parseInputURLs(inputURL)
        guard !urls.isEmpty else {
            errorMessage = "未识别到有效的 GitHub 链接。"
            return
        }

        queueTask?.cancel()
        queueTask = Task {
            let expanded = await expandInputURLs(urls)
            guard !expanded.isEmpty else {
                errorMessage = "没有可抓取的仓库链接。"
                return
            }
            prepareQueue(with: expanded)
            await runPreparedQueue()
        }
    }

    func pauseCrawl() {
        guard crawlState == .running else { return }
        pauseRequested = true
        appendLog("已请求暂停，当前任务完成后暂停。")
    }

    func stopCrawl() {
        guard crawlState != .idle else { return }
        stopRequested = true
        pauseRequested = false
        queueTask?.cancel()
        queueTask = nil
        crawlState = .idle
        isLoading = false
        statusMessage = "已停止抓取。"
        if !currentProjectName.isEmpty {
            appendLog("抓取已停止，当前项目将丢弃：\(currentProjectName)")
        } else {
            appendLog("抓取已停止。")
        }
    }

    func retryFailedImports() {
        let retries = failedURLs
        guard !retries.isEmpty else { return }
        queueTask?.cancel()
        queueTask = Task {
            prepareQueue(with: retries)
            await runPreparedQueue()
        }
    }

    func openGitHubURL(_ rawURL: String) {
        guard let url = URL(string: rawURL), !rawURL.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    func openInFinder(_ record: RepoRecord) {
        if !record.localPath.isEmpty {
            NSWorkspace.shared.selectFile(record.localPath, inFileViewerRootedAtPath: "")
            return
        }
        if !record.infoFilePath.isEmpty {
            NSWorkspace.shared.selectFile(record.infoFilePath, inFileViewerRootedAtPath: "")
        }
    }

    func openInstaller(_ record: RepoRecord) {
        if !record.localPath.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: record.localPath))
        } else if !record.infoFilePath.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: record.infoFilePath))
        }
    }

    func openSourcePage(_ record: RepoRecord) {
        guard !record.sourceURL.isEmpty, let url = URL(string: record.sourceURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func retranslateRecord(_ record: RepoRecord) {
        Task {
            await runRetranslation(record)
        }
    }

    func formatRecordOffline(_ record: RepoRecord) {
        Task {
            await runOfflineFormat(record)
        }
    }

    func deleteRecord(_ record: RepoRecord, deleteFiles: Bool) {
        do {
            try storage.deleteRecord(record, baseDir: activeBaseDir, removeFiles: deleteFiles)
            reloadRecords()
            statusMessage = deleteFiles ? "已删除项目和本地文件：\(record.projectName)" : "已删除项目记录：\(record.projectName)"
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func reloadRecords() {
        do {
            let records = try storage.loadRecords(baseDir: activeBaseDir, macOnly: onlyMacOSAssets)
            self.records = records
            self.knownRecordIDs = Set(records.map { $0.id })
            ensureValidCategorySelection()
            ensureValidPage()
        } catch {
            errorMessage = "读取本地记录失败: \(error.localizedDescription)"
        }
    }

    func refreshListFromDisk() {
        reloadRecords()
        statusMessage = "已对比目录并刷新：\(records.count) 项"
        appendLog(statusMessage)
    }

    func syncLibrary() {
        Task {
            await runSyncLibrary()
        }
    }

    private var activeBaseDir: URL {
        storage.resolvedBaseDir(customPath: downloadRootPath)
    }

    private func currentSettings() -> AppSettings {
        AppSettings(
            githubToken: githubToken,
            openAIKey: openAIKey,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            retryCount: retryCount,
            downloadRootPath: downloadRootPath,
            includeNoPackageProjects: includeNoPackageProjects,
            categoryModeRaw: categoryMode.rawValue,
            onlyMacOSAssets: onlyMacOSAssets
        )
    }

    private func saveSettingsToCurrentDirectory(_ settingsValue: AppSettings) {
        do {
            try settings.saveToDirectory(settingsValue, baseDir: activeBaseDir)
        } catch {
            appendLog("目录设置保存失败：\(error.localizedDescription)")
        }
    }

    private func loadSettingsFromSelectedDirectoryIfAvailable() {
        if let disk = settings.loadFromDirectory(baseDir: activeBaseDir) {
            githubToken = disk.githubToken
            openAIKey = disk.openAIKey
            openAIBaseURL = disk.openAIBaseURL
            openAIModel = disk.openAIModel
            retryCount = disk.retryCount
            includeNoPackageProjects = disk.includeNoPackageProjects
            categoryMode = CategoryMode(rawValue: disk.categoryModeRaw) ?? .typeBased
            onlyMacOSAssets = disk.onlyMacOSAssets
            appendLog("已从下载目录加载设置。")
        }
    }

    private func prepareQueue(with urls: [String]) {
        errorMessage = ""
        statusMessage = "准备处理 \(urls.count) 个链接..."
        fetchPrecision = 0
        sessionTrafficBytes = 0
        downloadLogTick.removeAll()
        failedURLs = []
        failedProjects = []
        queuedURLs = urls
        currentQueueIndex = 0
        queueItems = urls.map { QueueItem(url: $0, status: .pending, detail: "等待开始") }
        currentProjectName = ""
        reloadRecords()
    }

    private func resumeCrawl() {
        guard crawlState == .paused, !queuedURLs.isEmpty else { return }
        queueTask?.cancel()
        queueTask = Task {
            await runPreparedQueue()
        }
    }

    private func runPreparedQueue() async {
        guard !queuedURLs.isEmpty else { return }
        pauseRequested = false
        stopRequested = false
        crawlState = .running
        isLoading = true
        let urls = queuedURLs
        appendLog("开始抓取队列，共 \(urls.count) 条。")

        defer {
            queueTask = nil
        }

        var i = currentQueueIndex
        while i < urls.count {
            if Task.isCancelled || stopRequested {
                crawlState = .idle
                isLoading = false
                statusMessage = "已停止抓取。"
                appendLog("抓取队列停止。")
                return
            }

            if pauseRequested {
                crawlState = .paused
                isLoading = false
                statusMessage = "已暂停，可点击开始继续。"
                appendLog("抓取队列已暂停。")
                currentQueueIndex = i
                return
            }

            queueItems[i].status = .running
            queueItems[i].detail = "开始抓取"
            statusMessage = "(\(i + 1)/\(urls.count)) 处理中：\(urls[i])"
            appendLog("开始抓取：\(urls[i])")
            currentProjectName = projectNameFromURL(urls[i])

            do {
                let record = try await importOne(url: urls[i], retries: retryCount)
                if stopRequested || Task.isCancelled {
                    try? storage.deleteRecord(record, baseDir: activeBaseDir, removeFiles: true)
                    storage.removeProjectDirectories(baseDir: activeBaseDir, project: record.projectName)
                    queueItems[i].status = .failed
                    queueItems[i].detail = "已停止，当前项目未保存"
                    appendLog("停止后已丢弃当前项目：\(record.fullName)")
                    crawlState = .idle
                    isLoading = false
                    statusMessage = "已停止抓取。"
                    currentProjectName = ""
                    reloadRecords()
                    return
                }
                queueItems[i].status = .success
                queueItems[i].detail = "已完成：\(record.projectName)"
                appendLog("抓取成功：\(record.fullName) - 版本 \(record.releaseTag)")
                knownRecordIDs.insert(record.id)
                // 抓取进行中实时入库刷新
                reloadRecords()
            } catch is CancellationError {
                if stopRequested || Task.isCancelled {
                    if let parsed = try? URLParser.parseGitHubRepo(from: urls[i]) {
                        storage.removeProjectDirectories(baseDir: activeBaseDir, project: parsed.name)
                    }
                    queueItems[i].status = .failed
                    queueItems[i].detail = "已停止，当前项目未保存"
                    appendLog("停止后已清理当前项目临时数据：\(urls[i])")
                    crawlState = .idle
                    isLoading = false
                    statusMessage = "已停止抓取。"
                    currentProjectName = ""
                    reloadRecords()
                    return
                }
            } catch let skip as ImportSkipError {
                queueItems[i].status = .success
                queueItems[i].detail = skip.errorDescription ?? "已跳过"
                appendLog(skip.errorDescription ?? "已跳过当前项目。")
                if case .closedProject = skip {
                    failedProjects.append(
                        FailedProject(
                            name: projectNameFromURL(urls[i]),
                            url: urls[i],
                            reason: skip.errorDescription ?? "项目不可用",
                            type: .notFound404
                        )
                    )
                }
            } catch let skip as ImportError {
                queueItems[i].status = .success
                queueItems[i].detail = skip.errorDescription ?? "已跳过"
                appendLog(skip.errorDescription ?? "已跳过当前项目。")
            } catch {
                queueItems[i].status = .failed
                queueItems[i].detail = error.localizedDescription
                failedURLs.append(urls[i])
                failedProjects.append(
                    FailedProject(
                        name: projectNameFromURL(urls[i]),
                        url: urls[i],
                        reason: error.localizedDescription,
                        type: classifyFailureType(error.localizedDescription)
                    )
                )
                appendLog("抓取失败：\(urls[i])，原因：\(error.localizedDescription)")
            }
            fetchPrecision = Double(queueItems.filter { $0.status == .success }.count) / Double(max(queueItems.count, 1))
            currentProjectName = ""

            if pauseRequested {
                queueItems[i].status = .pending
                queueItems[i].detail = "已暂停，将从该项继续"
                crawlState = .paused
                isLoading = false
                statusMessage = "已暂停，可点击开始继续。"
                appendLog("抓取队列已暂停，将从当前项继续。")
                currentQueueIndex = i
                return
            }

            i += 1
            currentQueueIndex = i
        }

        crawlState = .idle
        isLoading = false
        currentQueueIndex = 0
        queuedURLs = []
        reloadRecords()
        if failedURLs.isEmpty {
            statusMessage = "全部完成：\(urls.count) 个链接处理成功。"
            appendLog("抓取队列完成，全部成功。")
        } else {
            statusMessage = "完成：成功 \(urls.count - failedURLs.count)，失败 \(failedURLs.count)。"
            errorMessage = "可点击“重试失败项”再次处理失败链接。"
            appendLog("抓取队列完成：成功 \(urls.count - failedURLs.count)，失败 \(failedURLs.count)。")
        }
    }

    private func importOne(url: String, retries: Int) async throws -> RepoRecord {
        var lastError: Error?
        let maxAttempt = max(1, min(retries, 5))

        for attempt in 1...maxAttempt {
            do {
                return try await importOneAttempt(url: url)
            } catch {
                lastError = error
                if attempt < maxAttempt {
                    statusMessage = "重试中 (\(attempt + 1)/\(maxAttempt))：\(url)"
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        throw lastError ?? URLError(.cannotParseResponse)
    }

    private func importOneAttempt(url: String) async throws -> RepoRecord {
        let identity = try URLParser.parseGitHubRepo(from: url)
        let id = identity.fullName.lowercased()

        if knownRecordIDs.contains(id) {
            throw ImportSkipError.alreadyExists(identity.fullName)
        }
        if storage.hasProjectDirectory(baseDir: activeBaseDir, project: identity.name) {
            throw ImportSkipError.alreadyExists(identity.fullName)
        }

        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        async let repo = github.fetchRepo(identity, token: token)
        async let readme = github.fetchReadmeText(identity, token: token)
        async let release = github.fetchLatestRelease(identity, token: token)

        let fetchedRepo: GitHubRepo
        do {
            fetchedRepo = try await repo
        } catch let serviceError as GitHubServiceError {
            if case .repoUnavailable = serviceError {
                throw ImportSkipError.closedProject
            }
            throw serviceError
        }
        if fetchedRepo.archived == true || fetchedRepo.disabled == true {
            throw ImportSkipError.closedProject
        }
        if let updatedAt = parsedGitHubDate(fetchedRepo.updatedAt),
           updatedAt < threeYearsAgoDate() {
            throw ImportSkipError.staleProject(lastUpdated: formattedDate(updatedAt))
        }
        if storage.hasProjectDirectory(baseDir: activeBaseDir, project: fetchedRepo.name) {
            throw ImportSkipError.alreadyExists(fetchedRepo.fullName)
        }

        let fetchedReadme = await readme
        let fetchedRelease = try await release
        appendLog("已读取仓库数据：\(fetchedRepo.fullName)")

        let cleanReadme = cleanReadmeContent(fetchedReadme)
        let englishDescription = mergedDescription(repo: fetchedRepo, readme: cleanReadme)
        let releaseNotesEN = cleanReadmeContent(fetchedRelease?.body ?? "")
        let setupGuideEN = setupGuideExtractor.extract(from: fetchedReadme)

        let config = TranslationConfig(apiKey: openAIKey, baseURL: openAIBaseURL, model: openAIModel)
        let descResult = await translator.translateToChineseDetailed(englishDescription, config: config)
        let noteResult = await translator.translateToChineseDetailed(releaseNotesEN, config: config)
        let chineseDescription = descResult.text
        let chineseReleaseNotes = noteResult.text
        addOpenAIUsage(descResult.usage)
        addOpenAIUsage(noteResult.usage)

        let summary = summarizer.summarize(
            chineseDescription.isEmpty ? englishDescription : chineseDescription,
            fallbackTitle: fetchedRepo.name
        )

        let selectedAsset = fetchedRelease.flatMap { github.selectBestAsset(from: $0.assets, onlyMacOS: onlyMacOSAssets) }

        let category: String
        let hasDownloadAsset: Bool
        let localPath: String
        let releaseTag: String
        let releaseAssetName: String
        let releaseAssetURL: String
        let projectDir: URL
        let previewImagePath: String

        if let asset = selectedAsset {
            category = classifier.classify(repo: fetchedRepo, text: englishDescription)
            releaseTag = resolveVersion(from: asset.name, fallback: fetchedRelease?.tagName ?? "N/A")
            releaseAssetName = asset.name
            releaseAssetURL = asset.browserDownloadURL.absoluteString
            projectDir = storage.projectDir(baseDir: activeBaseDir, category: category, project: fetchedRepo.name)
            appendLog("下载链接：\(asset.browserDownloadURL.absoluteString)")
            let downloaded = try await downloader.download(asset: asset, to: projectDir) { [weak self] progress in
                Task { @MainActor in
                    self?.appendDownloadLog(assetName: asset.name, progress: progress)
                }
            }
            hasDownloadAsset = true
            localPath = downloaded.path
            appendLog("已下载：\(asset.name)")
            addTrafficFromFile(path: downloaded.path)
        } else {
            guard includeNoPackageProjects else {
                throw ImportError.noDownloadAssetSkipped
            }
            category = classifier.classify(repo: fetchedRepo, text: englishDescription)
            releaseTag = fetchedRelease?.tagName ?? "N/A"
            releaseAssetName = "无安装包"
            releaseAssetURL = ""
            hasDownloadAsset = false
            localPath = ""
            projectDir = storage.projectDir(baseDir: activeBaseDir, category: category, project: fetchedRepo.name)
        }

        if Task.isCancelled || stopRequested {
            storage.removeProjectDirectories(baseDir: activeBaseDir, project: fetchedRepo.name)
            throw CancellationError()
        }

        if let imageURL = extractFirstImageURL(from: fetchedReadme, repo: identity) {
            previewImagePath = await downloader.downloadImage(from: imageURL, to: projectDir)
            if !previewImagePath.isEmpty {
                appendLog("已保存预览图：\(previewImagePath)")
                addTrafficFromFile(path: previewImagePath)
            }
        } else {
            previewImagePath = ""
        }

        let draft = RepoDraft(
            identity: identity,
            projectName: fetchedRepo.name,
            sourceURL: fetchedRepo.htmlURL,
            descriptionEN: englishDescription,
            descriptionZH: chineseDescription,
            summaryZH: summary,
            releaseNotesEN: releaseNotesEN,
            releaseNotesZH: chineseReleaseNotes,
            setupGuideEN: setupGuideEN,
            formattedZH: "",
            category: category,
            language: fetchedRepo.language ?? "Unknown",
            stars: fetchedRepo.stargazersCount,
            isFork: fetchedRepo.fork ?? false,
            releaseTag: releaseTag,
            releaseAssetName: releaseAssetName,
            releaseAssetURL: releaseAssetURL,
            hasDownloadAsset: hasDownloadAsset,
            localPath: localPath,
            previewImagePath: previewImagePath
        )
        return try storage.saveOrUpdate(draft, baseDir: activeBaseDir)
    }

    private func runSyncLibrary() async {
        errorMessage = ""
        isLoading = true
        defer { isLoading = false }

        reloadRecords()
        let snapshot = records.filter { !$0.sourceURL.isEmpty && $0.sourceURL.contains("github.com") }
        guard !snapshot.isEmpty else {
            statusMessage = "已同步本地库（无可校验项目）。"
            appendLog("同步完成：无可校验项目。")
            return
        }

        appendLog("开始同步库，共 \(snapshot.count) 个 GitHub 项目。")
        var updatedCount = 0
        var checkedCount = 0

        for record in snapshot {
            checkedCount += 1
            statusMessage = "同步中 (\(checkedCount)/\(snapshot.count))：\(record.fullName)"
            appendLog("校验版本：\(record.fullName)")
            do {
                let updated = try await syncRecordIfNeeded(record)
                if updated { updatedCount += 1 }
            } catch {
                appendLog("同步失败：\(record.fullName)，原因：\(error.localizedDescription)")
            }
            fetchPrecision = Double(checkedCount) / Double(max(snapshot.count, 1))
        }

        reloadRecords()
        statusMessage = "同步完成：检查 \(snapshot.count) 项，更新 \(updatedCount) 项。"
        appendLog("同步完成：检查 \(snapshot.count) 项，更新 \(updatedCount) 项。")
    }

    private func syncRecordIfNeeded(_ record: RepoRecord) async throws -> Bool {
        let identity = try URLParser.parseGitHubRepo(from: record.sourceURL)
        let latestRelease = try await github.fetchLatestRelease(identity, token: githubToken)
        guard
            let release = latestRelease,
            let latestAsset = github.selectBestAsset(from: release.assets, onlyMacOS: onlyMacOSAssets)
        else {
            return false
        }

        let latestVersion = resolveVersion(from: latestAsset.name, fallback: release.tagName)
        if latestVersion == record.releaseTag {
            appendLog("无需更新：\(record.fullName) 当前 \(record.releaseTag)")
            return false
        }

        appendLog("检测到新版本：\(record.fullName) \(record.releaseTag) -> \(latestVersion)")
        try archiveOldVersionIfNeeded(record: record)
        _ = try await importOne(url: record.sourceURL, retries: 1)
        return true
    }

    private func archiveOldVersionIfNeeded(record: RepoRecord) throws {
        guard !record.localPath.isEmpty else { return }
        let oldFile = URL(fileURLWithPath: record.localPath)
        guard FileManager.default.fileExists(atPath: oldFile.path) else { return }
        let projectDir = oldFile.deletingLastPathComponent()
        let safeVersion = record.releaseTag.replacingOccurrences(of: "/", with: "_")
        let archiveDir = projectDir
            .appendingPathComponent("过期版本", isDirectory: true)
            .appendingPathComponent(safeVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let archived = archiveDir.appendingPathComponent(oldFile.lastPathComponent)
        if !FileManager.default.fileExists(atPath: archived.path) {
            try FileManager.default.moveItem(at: oldFile, to: archived)
            appendLog("已归档旧版本：\(archived.path)")
        }
    }

    private func runRetranslation(_ record: RepoRecord) async {
        isLoading = true
        defer { isLoading = false }

        let config = TranslationConfig(apiKey: openAIKey, baseURL: openAIBaseURL, model: openAIModel)
        if !config.isEnabled {
            errorMessage = "请先在设置中填写 OpenAI API Key。"
            return
        }

        statusMessage = "正在重新翻译：\(record.projectName)"
        var updated = record
        let descResult = await translator.translateToChineseDetailed(record.descriptionEN, config: config)
        let noteResult = await translator.translateToChineseDetailed(record.releaseNotesEN, config: config)
        updated.descriptionZH = descResult.text
        updated.releaseNotesZH = noteResult.text
        addOpenAIUsage(descResult.usage)
        addOpenAIUsage(noteResult.usage)
        updated.summaryZH = summarizer.summarize(updated.descriptionZH, fallbackTitle: record.projectName)
        updated.updatedAt = Date()

        do {
            try storage.saveRecord(updated, baseDir: activeBaseDir)
            reloadRecords()
            statusMessage = "已完成重新翻译：\(record.projectName)"
        } catch {
            errorMessage = "保存翻译结果失败：\(error.localizedDescription)"
        }
    }

    private func runOfflineFormat(_ record: RepoRecord) async {
        isLoading = true
        defer { isLoading = false }

        let config = TranslationConfig(apiKey: openAIKey, baseURL: openAIBaseURL, model: openAIModel)
        if !config.isEnabled {
            errorMessage = "请先在设置中填写 OpenAI API Key。"
            return
        }

        statusMessage = "正在离线排版：\(record.projectName)"
        var updated = record
        let formatted = await layoutFormatter.formatChineseContent(
            title: record.projectName,
            descriptionZH: record.descriptionZH,
            releaseNotesZH: record.releaseNotesZH,
            config: config
        )
        updated.formattedZH = formatted.text
        addOpenAIUsage(formatted.usage)
        updated.updatedAt = Date()

        do {
            try storage.saveRecord(updated, baseDir: activeBaseDir)
            reloadRecords()
            statusMessage = "离线排版完成：\(record.projectName)"
        } catch {
            errorMessage = "保存离线排版结果失败：\(error.localizedDescription)"
        }
    }

    private func parseInputURLs(_ raw: String) -> [String] {
        let lines = raw
            .components(separatedBy: CharacterSet.newlines.union(.whitespaces))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var unique: [String] = []
        for line in lines {
            if !seen.contains(line) {
                seen.insert(line)
                unique.append(line)
            }
        }
        return unique
    }

    private func mergedDescription(repo: GitHubRepo, readme: String) -> String {
        let repoDesc = repo.description ?? ""
        let readmeBrief = String(readme.prefix(1600)).replacingOccurrences(of: "#", with: "")
        return "\(repoDesc)\n\n\(readmeBrief)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanReadmeContent(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^\\)]+\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[[^\\]]+\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "`{1,3}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[\\*_>#\\|]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty &&
                !line.lowercased().contains("shield") &&
                !line.lowercased().contains("badge")
            }

        return lines.joined(separator: "\n")
    }

    private func extractFirstImageURL(from readme: String, repo: RepoIdentity) -> URL? {
        let pattern = "!\\[[^\\]]*\\]\\(([^\\)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = readme as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: readme, range: range), match.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") {
            return URL(string: "https://raw.githubusercontent.com/\(repo.owner)/\(repo.name)/HEAD\(raw)")
        }
        return URL(string: "https://raw.githubusercontent.com/\(repo.owner)/\(repo.name)/HEAD/\(raw)")
    }

    private func resolveVersion(from filename: String, fallback: String) -> String {
        let name = filename.replacingOccurrences(of: "_", with: " ")
        let pattern = "(?i)(v?\\d+(?:\\.\\d+){1,3}(?:[-_][a-z0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return fallback }
        let ns = name as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = regex.firstMatch(in: name, range: range) {
            return ns.substring(with: m.range(at: 1))
        }
        return fallback
    }

    private func parsedGitHubDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f1.date(from: raw) {
            return date
        }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    private func threeYearsAgoDate() -> Date {
        Calendar.current.date(byAdding: .year, value: -3, to: Date()) ?? Date.distantPast
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func classifyFailureType(_ reason: String) -> FailedReasonType {
        let lower = reason.lowercased()
        if lower.contains("404") || lower.contains("不存在") || lower.contains("repoUnavailable".lowercased()) {
            return .notFound404
        }
        if lower.contains("timed out") || lower.contains("超时") || lower.contains("cannot connect") || lower.contains("network connection") {
            return .timeout
        }
        return .fetchFailed
    }

    private func addOpenAIUsage(_ usage: OpenAIUsage?) {
        guard let usage else { return }
        openAIPromptTokens += usage.promptTokens
        openAICompletionTokens += usage.completionTokens
        settings.saveOpenAITokens(prompt: openAIPromptTokens, completion: openAICompletionTokens)
        saveSettingsToCurrentDirectory(currentSettings())
        appendLog("OpenAI Token: +\(usage.totalTokens)（累计 \(openAITotalTokens)）")
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        realtimeLogs.append(line)
        if realtimeLogs.count > 200 {
            realtimeLogs.removeFirst(realtimeLogs.count - 200)
        }
    }

    private func addTrafficFromFile(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? NSNumber else { return }
        let bytes = fileSize.int64Value
        sessionTrafficBytes += bytes
        totalTrafficBytes += bytes
        settings.saveTotalTrafficBytes(totalTrafficBytes)
        appendLog("流量统计：本次 \(formatBytes(Double(sessionTrafficBytes)))，累计 \(formatBytes(Double(totalTrafficBytes)))")
    }

    private func appendDownloadLog(assetName: String, progress: DownloadProgressInfo) {
        let now = Date()
        if let last = downloadLogTick[assetName], now.timeIntervalSince(last) < 0.8 {
            return
        }
        downloadLogTick[assetName] = now

        let percent = Int(progress.progress * 100)
        let speed = formatBytes(progress.speedBytesPerSec) + "/s"
        let done = formatBytes(Double(progress.downloadedBytes))
        let total = formatBytes(Double(max(progress.totalBytes, 0)))
        appendLog("下载中 \(assetName): \(percent)% (\(done)/\(total)) 速度 \(speed)")
    }

    private func formatBytes(_ bytes: Double) -> String {
        if bytes < 1024 { return String(format: "%.0fB", bytes) }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", bytes / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1fMB", bytes / (1024 * 1024)) }
        return String(format: "%.2fGB", bytes / (1024 * 1024 * 1024))
    }

    private func projectNameFromURL(_ raw: String) -> String {
        if let parsed = try? URLParser.parseGitHubRepo(from: raw) {
            return parsed.fullName
        }
        return raw
    }

    private func expandInputURLs(_ rawURLs: [String]) async -> [String] {
        var expanded: [String] = []
        for raw in rawURLs {
            if let username = URLParser.parseGitHubStarsUser(from: raw) {
                appendLog("检测到 stars 页面，开始抓取用户 \(username) 的星标仓库...")
                do {
                    let starred = try await github.fetchStarredRepoURLs(username: username, token: githubToken)
                    appendLog("用户 \(username) 星标仓库数量：\(starred.count)")
                    expanded.append(contentsOf: starred)
                } catch {
                    appendLog("抓取 \(username) 星标失败：\(error.localizedDescription)")
                }
            } else {
                expanded.append(raw)
            }
        }

        var seen = Set<String>()
        var unique: [String] = []
        for url in expanded {
            if !seen.contains(url) {
                seen.insert(url)
                unique.append(url)
            }
        }
        return unique
    }
}
