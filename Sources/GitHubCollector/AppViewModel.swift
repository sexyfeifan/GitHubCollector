import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum CrawlState {
        case idle
        case running
        case paused
    }

    enum CrawlControlError: Error, LocalizedError {
        case noDataTimeout(seconds: Int)
        case skippedByUser

        var errorDescription: String? {
            switch self {
            case .noDataTimeout(let seconds):
                return "\(seconds) 秒内无数据进入，已跳过。"
            case .skippedByUser:
                return "已手动跳过当前项目。"
            }
        }
    }

    private enum QueueProcessOutcome {
        case success
        case deferred
        case failed(String)
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
    }

    @Published var inputURL: String = ""
    let appVersion: String = AppVersionResolver.currentVersionDisplay()
    @Published var isLoading = false
    @Published var statusMessage: String = ""
    @Published var errorMessage: String = ""
    @Published var records: [RepoRecord] = []
    @Published var selectedCategory: String = "全部"
    @Published var searchQuery: String = ""
    @Published var currentPage: Int = 1

    @Published var openAIKey: String = ""
    @Published var openAIBaseURL: String = "https://api.openai.com/v1"
    @Published var openAIModel: String = "gpt-4.1-mini"
    @Published var githubToken: String = ""
    @Published var retryCount: Int = 2
    @Published var downloadRootPath: String = ""
    @Published var isTestingAIConnectivity = false
    @Published var isTestingGitHubToken = false
    @Published var aiConnectivityTestResult: String = "未测试"
    @Published var githubTokenTestResult: String = "未测试"

    @Published var queueItems: [QueueItem] = []
    @Published var failedURLs: [String] = []
    @Published var failedProjects: [FailedProject] = []
    @Published var fetchPrecision: Double = 0
    @Published var realtimeLogs: [String] = []
    @Published var downloadTrafficText: String = "空闲"
    @Published var storageUsageText: String = "-"
    @Published var currentSavePathText: String = "-"
    @Published var crawlState: CrawlState = .idle
    private var downloadLogTick: [String: Date] = [:]
    private var queuedURLs: [String] = []
    private var currentQueueIndex: Int = 0
    private var deferredRetryURLs: [String] = []
    private var retryQueueIndex: Int = 0
    private var inRetryPhase = false
    private var pauseRequested = false
    private var stopRequested = false
    private var manualSkipRequested = false
    private var lastDataActivityAt = Date()
    private var currentImportURL: String = ""
    private var currentImportTask: Task<RepoRecord, Error>?
    private var queueTask: Task<Void, Never>?
    private var lastSavedSettingsSnapshot = AppSettings()

    private let github = GitHubService()
    private let translator = TranslatorService()
    private let summarizer = SummarizerService()
    private let classifier = ClassifierService()
    private let downloader = DownloadService()
    private let storage = StorageService()
    private let settings = SettingsStore()

    init() {
        let s = settings.load()
        applySettings(s)
        loadSettingsFromStorageIfPresent(baseDir: activeBaseDir)
        lastSavedSettingsSnapshot = buildCurrentSettings(downloadPath: activeBaseDir.path)
        reloadRecords()
        refreshStorageMetrics()
    }

    var categories: [String] {
        let all = Set(records.map { $0.category })
        return ["全部"] + all.sorted()
    }

    var filteredRecords: [RepoRecord] {
        let categoryFiltered: [RepoRecord]
        if selectedCategory == "全部" {
            categoryFiltered = records
        } else {
            categoryFiltered = records.filter { $0.category == selectedCategory }
        }

        let key = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return categoryFiltered }
        return categoryFiltered.filter { r in
            r.projectName.lowercased().contains(key) ||
            r.fullName.lowercased().contains(key) ||
            r.category.lowercased().contains(key) ||
            r.summaryZH.lowercased().contains(key)
        }
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
    var canSkipCurrent: Bool { crawlState == .running && currentImportTask != nil }
    var crawlProgressSummary: String {
        let total = queueItems.count
        guard total > 0 else { return "0/0" }
        let finished = queueItems.filter { $0.status == .success || $0.status == .failed }.count
        return "\(finished)/\(total)"
    }

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
        let normalizedBaseDir = storage.resolvedBaseDir(customPath: downloadRootPath)
        downloadRootPath = normalizedBaseDir.path
        let payload = buildCurrentSettings(downloadPath: normalizedBaseDir.path)
        settings.save(payload)
        do {
            try settings.saveToFile(payload, baseDir: normalizedBaseDir)
        } catch {
            errorMessage = "设置文件写入失败：\(error.localizedDescription)"
        }
        reloadRecords()
        refreshStorageMetrics()
        lastSavedSettingsSnapshot = payload
        statusMessage = "设置已保存。"
    }

    func restoreSettings() {
        let baseDir = storage.resolvedBaseDir(customPath: downloadRootPath)
        if let fromFile = settings.loadFromFile(baseDir: baseDir) {
            applySettings(fromFile)
            downloadRootPath = baseDir.path
            lastSavedSettingsSnapshot = buildCurrentSettings(downloadPath: baseDir.path)
            refreshStorageMetrics()
            statusMessage = "已从目录设置文件还原。"
            return
        }

        applySettings(lastSavedSettingsSnapshot)
        refreshStorageMetrics()
        statusMessage = "已还原到最近保存设置。"
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
        if let text = clipboardText() {
            openAIKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "已粘贴 API Key。"
        } else {
            errorMessage = "剪贴板没有可用文本。"
        }
    }

    func pasteGitHubTokenFromClipboard() {
        if let text = clipboardText() {
            githubToken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "已粘贴 GitHub Token。"
        } else {
            errorMessage = "剪贴板没有可用文本。"
        }
    }

    func testAIConnectivity() {
        let config = TranslationConfig(apiKey: openAIKey, baseURL: openAIBaseURL, model: openAIModel)
        guard config.isEnabled else {
            errorMessage = "请先填写 OpenAI API Key 再测试连通性。"
            return
        }

        isTestingAIConnectivity = true
        statusMessage = "正在测试 AI 连通性..."
        errorMessage = ""
        aiConnectivityTestResult = "测试中..."

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await translator.probeConnectivity(config: config)
                await MainActor.run {
                    self.isTestingAIConnectivity = false
                    self.aiConnectivityTestResult = "成功：\(result)"
                    self.statusMessage = "AI 连通成功：\(result)"
                }
            } catch {
                await MainActor.run {
                    self.isTestingAIConnectivity = false
                    self.aiConnectivityTestResult = "失败：\(error.localizedDescription)"
                    self.errorMessage = "AI 连通失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func testGitHubTokenValidity() {
        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "请先填写 GitHub Token。"
            return
        }

        isTestingGitHubToken = true
        statusMessage = "正在验证 GitHub Token..."
        errorMessage = ""
        githubTokenTestResult = "验证中..."

        Task { [weak self] in
            guard let self else { return }
            do {
                let login = try await github.validateToken(token)
                await MainActor.run {
                    self.isTestingGitHubToken = false
                    self.githubTokenTestResult = "有效：\(login)"
                    self.statusMessage = "GitHub Token 有效：\(login)"
                }
            } catch {
                await MainActor.run {
                    self.isTestingGitHubToken = false
                    self.githubTokenTestResult = "无效：\(error.localizedDescription)"
                    self.errorMessage = "GitHub Token 无效：\(error.localizedDescription)"
                }
            }
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
            let didRestore = loadSettingsFromStorageIfPresent(baseDir: url)
            if didRestore {
                statusMessage = "已从该目录读取设置文件。"
            } else {
                statusMessage = "目录中未找到设置文件，已使用当前设置。"
            }
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
        manualSkipRequested = false
        currentImportTask?.cancel()
        queueTask?.cancel()
        queueTask = nil
        crawlState = .idle
        isLoading = false
        statusMessage = "已停止抓取。"
        downloadTrafficText = "空闲"
        appendLog("抓取已停止。")
    }

    func skipCurrentProject() {
        guard canSkipCurrent else { return }
        manualSkipRequested = true
        let current = currentImportURL.isEmpty ? "当前项目" : currentImportURL
        statusMessage = "已请求跳过：\(current)"
        appendLog("手动跳过请求：\(current)")
        currentImportTask?.cancel()
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
        if !record.sourceCodePath.isEmpty {
            NSWorkspace.shared.selectFile(record.sourceCodePath, inFileViewerRootedAtPath: "")
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

    func optimizeRecordText(_ record: RepoRecord) {
        Task {
            await runTextOptimization(record)
        }
    }

    func pullSourceCode(_ record: RepoRecord) {
        Task {
            await runSourcePull(record)
        }
    }

    func deleteRecord(_ record: RepoRecord, deleteFiles: Bool) {
        do {
            try storage.deleteRecord(record, baseDir: activeBaseDir, removeFiles: deleteFiles)
            reloadRecords()
            refreshStorageMetrics()
            statusMessage = deleteFiles ? "已删除项目和本地文件：\(record.projectName)" : "已删除项目记录：\(record.projectName)"
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func reloadRecords() {
        do {
            let records = try storage.loadRecords(baseDir: activeBaseDir)
            self.records = records
            ensureValidPage()
            refreshStorageMetrics()
        } catch {
            errorMessage = "读取本地记录失败: \(error.localizedDescription)"
        }
    }

    func syncLibrary() {
        Task {
            await runSyncLibrary()
        }
    }

    private var activeBaseDir: URL {
        storage.resolvedBaseDir(customPath: downloadRootPath)
    }

    private func prepareQueue(with urls: [String]) {
        errorMessage = ""
        statusMessage = "准备处理 \(urls.count) 个链接..."
        fetchPrecision = 0
        downloadTrafficText = "空闲"
        currentSavePathText = activeBaseDir.path
        downloadLogTick.removeAll()
        failedURLs = []
        failedProjects = []
        queuedURLs = urls
        currentQueueIndex = 0
        deferredRetryURLs = []
        retryQueueIndex = 0
        inRetryPhase = false
        manualSkipRequested = false
        currentImportURL = ""
        currentImportTask = nil
        lastDataActivityAt = Date()
        queueItems = urls.map { QueueItem(url: $0, status: .pending, detail: "等待开始") }
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
        if !inRetryPhase && currentQueueIndex == 0 {
            appendLog("开始抓取队列，共 \(urls.count) 条。")
        }

        defer {
            queueTask = nil
        }

        if !inRetryPhase {
            var i = currentQueueIndex
            while i < urls.count {
                if shouldStopOrPause(firstPhaseIndex: i, retryPhaseIndex: retryQueueIndex) {
                    return
                }

                let outcome = await processQueueURL(
                    urls[i],
                    totalCount: urls.count,
                    queuePosition: i + 1,
                    inactivityTimeout: 10,
                    allowDeferredRetry: true
                )

                switch outcome {
                case .success:
                    break
                case .deferred:
                    if !deferredRetryURLs.contains(urls[i]) {
                        deferredRetryURLs.append(urls[i])
                    }
                case .failed(let reason):
                    markQueueFailed(url: urls[i], reason: reason)
                }

                refreshQueueProgress()
                i += 1
                currentQueueIndex = i
            }
            inRetryPhase = true
            retryQueueIndex = max(retryQueueIndex, 0)
        }

        if !deferredRetryURLs.isEmpty {
            appendLog("进入延后重试阶段，共 \(deferredRetryURLs.count) 项（30 秒无数据将再次跳过）。")
        }

        var r = retryQueueIndex
        while r < deferredRetryURLs.count {
            if shouldStopOrPause(firstPhaseIndex: currentQueueIndex, retryPhaseIndex: r) {
                return
            }

            let url = deferredRetryURLs[r]
            let outcome = await processQueueURL(
                url,
                totalCount: deferredRetryURLs.count,
                queuePosition: r + 1,
                inactivityTimeout: 30,
                allowDeferredRetry: false
            )

            switch outcome {
            case .success:
                break
            case .deferred:
                markQueueFailed(url: url, reason: "重试阶段仍超时无数据（30 秒）。")
            case .failed(let reason):
                markQueueFailed(url: url, reason: reason)
            }

            refreshQueueProgress()
            r += 1
            retryQueueIndex = r
        }

        finishQueueRun(total: urls.count)
    }

    private func processQueueURL(
        _ url: String,
        totalCount: Int,
        queuePosition: Int,
        inactivityTimeout: TimeInterval,
        allowDeferredRetry: Bool
    ) async -> QueueProcessOutcome {
        guard let idx = queueItems.firstIndex(where: { $0.url == url }) else {
            return .failed("队列状态异常：未找到任务索引。")
        }

        queueItems[idx].status = .running
        queueItems[idx].detail = allowDeferredRetry ? "开始抓取（10 秒无数据会暂时跳过）" : "重试中（30 秒无数据将跳过）"
        statusMessage = "(\(queuePosition)/\(totalCount)) 处理中：\(url)"
        appendLog("开始抓取：\(url)")

        do {
            let record = try await importOne(url: url, retries: retryCount, inactivityTimeout: inactivityTimeout)
            queueItems[idx].status = .success
            queueItems[idx].detail = "已完成：\(record.projectName)"
            appendLog("抓取成功：\(record.fullName) - 版本 \(record.releaseTag)")
            reloadRecords()
            return .success
        } catch let error as CrawlControlError {
            switch error {
            case .noDataTimeout(let seconds):
                if allowDeferredRetry {
                    queueItems[idx].status = .pending
                    queueItems[idx].detail = "\(seconds) 秒无数据，已暂时跳过，稍后重试"
                    appendLog("暂时跳过：\(url)，原因：\(seconds) 秒无数据。")
                    return .deferred
                }
                queueItems[idx].status = .failed
                queueItems[idx].detail = "\(seconds) 秒无数据，重试后仍失败"
                appendLog("重试后跳过：\(url)，原因：\(seconds) 秒无数据。")
                return .failed("重试阶段 \(seconds) 秒无数据，已跳过。")
            case .skippedByUser:
                if allowDeferredRetry {
                    queueItems[idx].status = .pending
                    queueItems[idx].detail = "已手动跳过，稍后重试"
                    appendLog("已手动跳过：\(url)，将在重试阶段再次尝试。")
                    return .deferred
                }
                queueItems[idx].status = .failed
                queueItems[idx].detail = "重试阶段手动跳过"
                appendLog("重试阶段手动跳过：\(url)")
                return .failed("重试阶段手动跳过。")
            }
        } catch is CancellationError {
            if stopRequested || Task.isCancelled {
                return .failed("任务已停止。")
            }
            if allowDeferredRetry {
                queueItems[idx].status = .pending
                queueItems[idx].detail = "已取消，稍后重试"
                return .deferred
            }
            queueItems[idx].status = .failed
            queueItems[idx].detail = "重试阶段已取消"
            return .failed("重试阶段任务取消。")
        } catch {
            queueItems[idx].status = .failed
            queueItems[idx].detail = error.localizedDescription
            appendLog("抓取失败：\(url)，原因：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private func shouldStopOrPause(firstPhaseIndex: Int, retryPhaseIndex: Int) -> Bool {
        if Task.isCancelled || stopRequested {
            crawlState = .idle
            isLoading = false
            statusMessage = "已停止抓取。"
            appendLog("抓取队列停止。")
            return true
        }

        if pauseRequested {
            crawlState = .paused
            isLoading = false
            statusMessage = "已暂停，可点击开始继续。"
            appendLog("抓取队列已暂停。")
            currentQueueIndex = firstPhaseIndex
            retryQueueIndex = retryPhaseIndex
            return true
        }
        return false
    }

    private func finishQueueRun(total: Int) {
        crawlState = .idle
        isLoading = false
        currentQueueIndex = 0
        retryQueueIndex = 0
        inRetryPhase = false
        queuedURLs = []
        deferredRetryURLs = []
        manualSkipRequested = false
        currentImportTask = nil
        currentImportURL = ""
        downloadTrafficText = "空闲"
        reloadRecords()
        if failedURLs.isEmpty {
            statusMessage = "全部完成：\(total) 个链接处理成功。"
            appendLog("抓取队列完成，全部成功。")
        } else {
            statusMessage = "完成：成功 \(total - failedURLs.count)，失败 \(failedURLs.count)。"
            errorMessage = "可点击“重试失败项”再次处理失败链接。"
            appendLog("抓取队列完成：成功 \(total - failedURLs.count)，失败 \(failedURLs.count)。")
        }
    }

    private func markQueueFailed(url: String, reason: String) {
        if !failedURLs.contains(url) {
            failedURLs.append(url)
        }
        if !failedProjects.contains(where: { $0.url == url }) {
            failedProjects.append(
                FailedProject(
                    name: projectNameFromURL(url),
                    url: url,
                    reason: reason
                )
            )
        }
    }

    private func refreshQueueProgress() {
        let total = queueItems.count
        guard total > 0 else {
            fetchPrecision = 0
            return
        }
        let finished = queueItems.filter { $0.status == .success || $0.status == .failed }.count
        fetchPrecision = Double(finished) / Double(total)
    }

    private func importOne(url: String, retries: Int, inactivityTimeout: TimeInterval = 30) async throws -> RepoRecord {
        var lastError: Error?
        let maxAttempt = max(1, min(retries, 5))

        for attempt in 1...maxAttempt {
            do {
                return try await importOneMonitoredAttempt(url: url, inactivityTimeout: inactivityTimeout)
            } catch let control as CrawlControlError {
                throw control
            } catch is CancellationError {
                if manualSkipRequested {
                    throw CrawlControlError.skippedByUser
                }
                throw CancellationError()
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

    private func importOneMonitoredAttempt(url: String, inactivityTimeout: TimeInterval) async throws -> RepoRecord {
        manualSkipRequested = false
        lastDataActivityAt = Date()
        currentImportURL = url

        let importTask = Task<RepoRecord, Error> { [weak self] in
            guard let self else { throw URLError(.unknown) }
            return try await self.importOneAttempt(url: url)
        }
        currentImportTask = importTask

        defer {
            currentImportTask = nil
            currentImportURL = ""
            manualSkipRequested = false
        }

        do {
            return try await withThrowingTaskGroup(of: RepoRecord.self) { group in
                group.addTask {
                    try await importTask.value
                }
                group.addTask { [weak self] in
                    guard let self else { throw URLError(.unknown) }
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let snapshot = await MainActor.run {
                            (Date().timeIntervalSince(self.lastDataActivityAt), self.manualSkipRequested)
                        }
                        if snapshot.1 {
                            importTask.cancel()
                            throw CrawlControlError.skippedByUser
                        }
                        if snapshot.0 >= inactivityTimeout {
                            importTask.cancel()
                            throw CrawlControlError.noDataTimeout(seconds: Int(inactivityTimeout))
                        }
                    }
                    throw CancellationError()
                }
                guard let first = try await group.next() else {
                    throw URLError(.cannotParseResponse)
                }
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            if stopRequested || Task.isCancelled {
                throw CancellationError()
            }
            if manualSkipRequested {
                throw CrawlControlError.skippedByUser
            }
            throw CrawlControlError.noDataTimeout(seconds: Int(inactivityTimeout))
        }
    }

    private func markDataActivity() {
        lastDataActivityAt = Date()
    }

    private func importOneAttempt(url: String) async throws -> RepoRecord {
        markDataActivity()
        let identity = try URLParser.parseGitHubRepo(from: url)
        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)

        async let repo = github.fetchRepo(identity, token: token)
        async let readme = github.fetchReadmeText(identity, token: token)
        async let release = github.fetchLatestRelease(identity, token: token)

        let fetchedRepo = try await repo
        markDataActivity()
        let fetchedReadme = await readme
        markDataActivity()
        let fetchedRelease = try await release
        markDataActivity()
        appendLog("已读取仓库数据：\(fetchedRepo.fullName)")

        let readmeOriginal = fetchedReadme.trimmingCharacters(in: .whitespacesAndNewlines)
        let readmeForProcessing = readmeOriginal.isEmpty ? (fetchedRepo.description ?? "") : readmeOriginal
        let cleanReadme = cleanReadmeContent(readmeForProcessing)
        let readmeTextForDisplay = cleanReadme.isEmpty ? readmeForProcessing : cleanReadme
        let releaseNotesEN = fetchedRelease?.body ?? ""
        let classifyText = mergedDescription(repo: fetchedRepo, readme: readmeTextForDisplay)

        let config = TranslationConfig(apiKey: openAIKey, baseURL: openAIBaseURL, model: openAIModel)
        let chineseDescription = await buildChineseDescription(from: readmeTextForDisplay, config: config)
        let chineseReleaseNotes = await translator.translateToChinese(releaseNotesEN, config: config)
        let setupGuide = await translator.extractSetupGuide(readmeTextForDisplay, config: config)

        let summary = summarizer.summarize(
            chineseDescription.isEmpty ? readmeTextForDisplay : chineseDescription,
            fallbackTitle: fetchedRepo.name
        )

        let assets = fetchedRelease?.assets ?? []

        let category: String
        let hasDownloadAsset: Bool
        let localPath: String
        let sourceCodePath: String
        let releaseTag: String
        let releaseAssetName: String
        let releaseAssetURL: String
        let projectDir: URL
        let previewImagePath: String

        category = classifier.classify(repo: fetchedRepo, text: classifyText)
        releaseTag = fetchedRelease?.tagName ?? "N/A"
        projectDir = storage.projectDir(baseDir: activeBaseDir, category: category, project: fetchedRepo.name)
        currentSavePathText = projectDir.path

        sourceCodePath = records.first(where: { $0.id == identity.fullName.lowercased() })?.sourceCodePath ?? ""

        if assets.isEmpty {
            hasDownloadAsset = false
            localPath = ""
            releaseAssetName = "无安装包"
            releaseAssetURL = ""
        } else {
            var downloadedPaths: [String] = []
            var urls: [String] = []
            for asset in assets {
                appendLog("下载链接：\(asset.browserDownloadURL.absoluteString)")
                let downloaded = try await downloader.download(asset: asset, to: projectDir) { [weak self] progress in
                    Task { @MainActor in
                        self?.markDataActivity()
                        self?.appendDownloadLog(assetName: asset.name, progress: progress)
                    }
                }
                markDataActivity()
                downloadedPaths.append(downloaded.path)
                urls.append(asset.browserDownloadURL.absoluteString)
                appendLog("已下载：\(asset.name)")
            }
            hasDownloadAsset = true
            localPath = downloadedPaths.first ?? ""
            releaseAssetName = assets.count == 1
                ? assets[0].name
                : "\(assets.count) 个安装包（\(assets.prefix(3).map(\.name).joined(separator: "、"))\(assets.count > 3 ? "..." : "")）"
            releaseAssetURL = urls.joined(separator: "\n")
        }

        if let imageURL = extractFirstImageURL(from: fetchedReadme, repo: identity) {
            previewImagePath = await downloader.downloadImage(from: imageURL, to: projectDir)
            markDataActivity()
            if !previewImagePath.isEmpty {
                appendLog("已保存预览图：\(previewImagePath)")
            }
        } else {
            previewImagePath = ""
        }

        let draft = RepoDraft(
            identity: identity,
            projectName: fetchedRepo.name,
            sourceURL: fetchedRepo.htmlURL,
            descriptionEN: readmeTextForDisplay,
            descriptionZH: chineseDescription,
            summaryZH: summary,
            setupGuideZH: setupGuide,
            releaseNotesEN: releaseNotesEN,
            releaseNotesZH: chineseReleaseNotes,
            category: category,
            language: fetchedRepo.language ?? "Unknown",
            stars: fetchedRepo.stargazersCount,
            releaseTag: releaseTag,
            releaseAssetName: releaseAssetName,
            releaseAssetURL: releaseAssetURL,
            hasDownloadAsset: hasDownloadAsset,
            localPath: localPath,
            sourceCodePath: sourceCodePath,
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
        guard let release = latestRelease else {
            return false
        }

        let latestVersion: String
        if !release.tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestVersion = release.tagName
        } else if let latestAsset = github.selectBestAsset(from: release.assets) {
            latestVersion = resolveVersion(from: latestAsset.name, fallback: "N/A")
        } else {
            latestVersion = "N/A"
        }
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

    private func runTextOptimization(_ record: RepoRecord) async {
        isLoading = true
        defer { isLoading = false }

        let config = TranslationConfig(apiKey: openAIKey, baseURL: openAIBaseURL, model: openAIModel)
        statusMessage = "正在优化文本：\(record.projectName)"
        var updated = record
        let cleaned = cleanReadmeContent(record.descriptionEN)
        let textSource = cleaned.isEmpty ? record.descriptionEN : cleaned
        updated.descriptionEN = textSource
        updated.descriptionZH = await buildChineseDescription(from: textSource, config: config)
        updated.setupGuideZH = await translator.extractSetupGuide(textSource, config: config)
        updated.releaseNotesZH = await translator.translateToChinese(record.releaseNotesEN, config: config)
        updated.summaryZH = summarizer.summarize(updated.descriptionZH, fallbackTitle: record.projectName)
        updated.updatedAt = Date()

        do {
            try storage.saveRecord(updated, baseDir: activeBaseDir)
            reloadRecords()
            statusMessage = "已完成文本优化：\(record.projectName)"
        } catch {
            errorMessage = "保存文本优化结果失败：\(error.localizedDescription)"
        }
    }

    private func runSourcePull(_ record: RepoRecord) async {
        guard let repoURL = URL(string: record.sourceURL), !record.sourceURL.isEmpty else {
            errorMessage = "当前项目缺少有效的 GitHub 地址，无法拉取源码。"
            return
        }

        isLoading = true
        defer { isLoading = false }

        statusMessage = "正在拉取源码：\(record.fullName)"
        appendLog("手动拉取源码：\(record.fullName)")
        do {
            let projectDir = storage.projectDir(baseDir: activeBaseDir, category: record.category, project: record.projectName)
            let sourceDir = try await downloader.cloneRepository(repoURL: repoURL, to: projectDir)
            var updated = record
            updated.sourceCodePath = sourceDir.path
            updated.updatedAt = Date()
            try storage.saveRecord(updated, baseDir: activeBaseDir)
            reloadRecords()
            statusMessage = "源码拉取完成：\(record.fullName)"
            appendLog("源码拉取完成：\(sourceDir.path)")
        } catch {
            errorMessage = "源码拉取失败：\(error.localizedDescription)"
            appendLog("源码拉取失败：\(record.fullName)，原因：\(error.localizedDescription)")
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

    private func buildChineseDescription(from text: String, config: TranslationConfig) async -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "暂无简介内容。" }

        if containsChineseText(cleaned) {
            return cleaned
        }

        let translated = await translator.translateToChinese(cleaned, config: config)
        if containsChineseText(translated) {
            return translated
        }
        return cleaned
    }

    private func containsChineseText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                return true
            }
        }
        return false
    }

    private func cleanReadmeContent(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^\\)]+\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
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

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        realtimeLogs.append(line)
        if realtimeLogs.count > 200 {
            realtimeLogs.removeFirst(realtimeLogs.count - 200)
        }
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
        let total = progress.totalBytes > 0 ? formatBytes(Double(progress.totalBytes)) : "未知"
        let percentText = progress.totalBytes > 0 ? "\(percent)%" : "--"
        downloadTrafficText = "\(assetName) \(percentText) (\(done)/\(total)) · \(speed)"
        appendLog("下载中 \(assetName): \(percentText) (\(done)/\(total)) 速度 \(speed)")
    }

    private func refreshStorageMetrics() {
        currentSavePathText = activeBaseDir.path
        let size = directorySize(at: activeBaseDir)
        storageUsageText = formatBytes(Double(size))
    }

    private func directorySize(at root: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
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
        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        for raw in rawURLs {
            if let username = URLParser.parseGitHubStarsUser(from: raw) {
                appendLog("检测到 stars 页面，开始抓取用户 \(username) 的星标仓库...")
                do {
                    let starred = try await github.fetchStarredRepoURLs(username: username, token: token)
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

    private func applySettings(_ s: AppSettings) {
        openAIKey = s.openAIKey
        openAIBaseURL = s.openAIBaseURL
        openAIModel = s.openAIModel
        githubToken = s.githubToken
        retryCount = s.retryCount
        downloadRootPath = s.downloadRootPath
    }

    @discardableResult
    private func loadSettingsFromStorageIfPresent(baseDir: URL) -> Bool {
        guard let fromFile = settings.loadFromFile(baseDir: baseDir) else { return false }
        let currentPath = baseDir.path
        applySettings(fromFile)
        downloadRootPath = currentPath
        settings.save(buildCurrentSettings(downloadPath: currentPath))
        lastSavedSettingsSnapshot = buildCurrentSettings(downloadPath: currentPath)
        return true
    }

    private func buildCurrentSettings(downloadPath: String) -> AppSettings {
        AppSettings(
            openAIKey: openAIKey,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            githubToken: githubToken,
            retryCount: retryCount,
            downloadRootPath: downloadPath
        )
    }

    private func clipboardText() -> String? {
        let pb = NSPasteboard.general
        return pb.string(forType: .string)
            ?? pb.string(forType: .URL)
            ?? pb.string(forType: .fileURL)
    }
}

private enum AppVersionResolver {
    static func currentVersionDisplay() -> String {
        if let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let cleaned = short.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned.lowercased().hasPrefix("v") ? cleaned : "v\(cleaned)"
            }
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            let cleaned = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned.lowercased().hasPrefix("v") ? cleaned : "v\(cleaned)"
            }
        }

        let versionFile = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("VERSION")
        if let raw = try? String(contentsOf: versionFile, encoding: .utf8) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned.lowercased().hasPrefix("v") ? cleaned : "v\(cleaned)"
            }
        }

        return "开发版"
    }
}
