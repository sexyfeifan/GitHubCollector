import Foundation

struct AppSettings {
    // Tokens are persisted in Keychain; these fields carry in-memory values
    var githubToken: String = ""
    var openAIKey: String = ""
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var openAIModel: String = "gpt-4.1-mini"
    var retryCount: Int = 2
    var downloadRootPath: String = ""
    var includeNoPackageProjects: Bool = true
    var categoryModeRaw: String = "typeBased"
    var onlyMacOSAssets: Bool = false
}

struct SettingsStore {
    private struct DiskSettings: Codable {
        var githubToken: String
        var openAIKey: String
        var openAIBaseURL: String
        var openAIModel: String
        var retryCount: Int
        var includeNoPackageProjects: Bool
        var categoryModeRaw: String?
        var openAITotalPromptTokens: Int?
        var openAITotalCompletionTokens: Int?
        var onlyMacOSAssets: Bool?
    }

    private enum Keys {
        static let githubToken = "settings.github.token"
        static let openAIKey = "settings.openai.key"
        static let openAIBaseURL = "settings.openai.base_url"
        static let openAIModel = "settings.openai.model"
        static let retryCount = "settings.retry_count"
        static let downloadRootPath = "settings.download.root_path"
        static let includeNoPackageProjects = "settings.include_no_package_projects"
        static let categoryModeRaw = "settings.category_mode_raw"
        static let totalTrafficBytes = "metrics.total_traffic_bytes"
        static let openAITotalPromptTokens = "metrics.openai.prompt_tokens"
        static let openAITotalCompletionTokens = "metrics.openai.completion_tokens"
        static let onlyMacOSAssets = "settings.only_macos_assets"
    }

    private let ud = UserDefaults.standard
    private let fm = FileManager.default

    func load() -> AppSettings {
        var s = AppSettings()
        // Migrate tokens from UserDefaults to Keychain (one-time)
        if let oldGH = ud.string(forKey: Keys.githubToken), !oldGH.isEmpty {
            KeychainStore.set(oldGH, for: Keys.githubToken)
            ud.removeObject(forKey: Keys.githubToken)
        }
        if let oldAI = ud.string(forKey: Keys.openAIKey), !oldAI.isEmpty {
            KeychainStore.set(oldAI, for: Keys.openAIKey)
            ud.removeObject(forKey: Keys.openAIKey)
        }
        s.githubToken = KeychainStore.get(Keys.githubToken)
        s.openAIKey = KeychainStore.get(Keys.openAIKey)
        s.openAIBaseURL = ud.string(forKey: Keys.openAIBaseURL) ?? s.openAIBaseURL
        s.openAIModel = ud.string(forKey: Keys.openAIModel) ?? s.openAIModel
        let retry = ud.integer(forKey: Keys.retryCount)
        s.retryCount = retry == 0 ? 2 : max(1, min(retry, 5))
        s.downloadRootPath = ud.string(forKey: Keys.downloadRootPath) ?? ""
        if ud.object(forKey: Keys.includeNoPackageProjects) == nil {
            s.includeNoPackageProjects = true
        } else {
            s.includeNoPackageProjects = ud.bool(forKey: Keys.includeNoPackageProjects)
        }
        s.categoryModeRaw = ud.string(forKey: Keys.categoryModeRaw) ?? "typeBased"
        s.onlyMacOSAssets = ud.bool(forKey: Keys.onlyMacOSAssets)
        return s
    }

    func save(_ settings: AppSettings) {
        // Save tokens into Keychain only
        KeychainStore.set(settings.githubToken, for: Keys.githubToken)
        KeychainStore.set(settings.openAIKey, for: Keys.openAIKey)
        ud.set(settings.openAIBaseURL, forKey: Keys.openAIBaseURL)
        ud.set(settings.openAIModel, forKey: Keys.openAIModel)
        ud.set(max(1, min(settings.retryCount, 5)), forKey: Keys.retryCount)
        ud.set(settings.downloadRootPath, forKey: Keys.downloadRootPath)
        ud.set(settings.includeNoPackageProjects, forKey: Keys.includeNoPackageProjects)
        ud.set(settings.categoryModeRaw, forKey: Keys.categoryModeRaw)
        ud.set(settings.onlyMacOSAssets, forKey: Keys.onlyMacOSAssets)
    }

    func saveToDirectory(_ settings: AppSettings, baseDir: URL) throws {
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let payload = DiskSettings(
            githubToken: settings.githubToken,
            openAIKey: settings.openAIKey,
            openAIBaseURL: settings.openAIBaseURL,
            openAIModel: settings.openAIModel,
            retryCount: max(1, min(settings.retryCount, 5)),
            includeNoPackageProjects: settings.includeNoPackageProjects,
            categoryModeRaw: settings.categoryModeRaw,
            openAITotalPromptTokens: loadOpenAITotalPromptTokens(),
            openAITotalCompletionTokens: loadOpenAITotalCompletionTokens(),
            onlyMacOSAssets: settings.onlyMacOSAssets
        )
        let data = try makePrettyEncoder().encode(payload)
        try data.write(to: settingsFileURL(baseDir: baseDir), options: .atomic)
    }

    func loadFromDirectory(baseDir: URL) -> AppSettings? {
        let file = settingsFileURL(baseDir: baseDir)
        guard fm.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            let payload = try JSONDecoder().decode(DiskSettings.self, from: data)
            saveOpenAITokens(
                prompt: payload.openAITotalPromptTokens ?? 0,
                completion: payload.openAITotalCompletionTokens ?? 0
            )
            // Also hydrate tokens into Keychain for this directory profile
            if !payload.githubToken.isEmpty { KeychainStore.set(payload.githubToken, for: Keys.githubToken) }
            if !payload.openAIKey.isEmpty { KeychainStore.set(payload.openAIKey, for: Keys.openAIKey) }
            return AppSettings(
                githubToken: payload.githubToken,
                openAIKey: payload.openAIKey,
                openAIBaseURL: payload.openAIBaseURL,
                openAIModel: payload.openAIModel,
                retryCount: max(1, min(payload.retryCount, 5)),
                downloadRootPath: baseDir.path,
                includeNoPackageProjects: payload.includeNoPackageProjects,
                categoryModeRaw: payload.categoryModeRaw ?? "typeBased",
                onlyMacOSAssets: payload.onlyMacOSAssets ?? false
            )
        } catch {
            return nil
        }
    }

    func settingsFileURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("collector_settings.json")
    }

    private func makePrettyEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func loadTotalTrafficBytes() -> Int64 {
        Int64(ud.object(forKey: Keys.totalTrafficBytes) as? Int ?? 0)
    }

    func saveTotalTrafficBytes(_ bytes: Int64) {
        ud.set(Int(bytes), forKey: Keys.totalTrafficBytes)
    }

    func loadOpenAITotalPromptTokens() -> Int {
        ud.integer(forKey: Keys.openAITotalPromptTokens)
    }

    func loadOpenAITotalCompletionTokens() -> Int {
        ud.integer(forKey: Keys.openAITotalCompletionTokens)
    }

    func saveOpenAITokens(prompt: Int, completion: Int) {
        ud.set(max(0, prompt), forKey: Keys.openAITotalPromptTokens)
        ud.set(max(0, completion), forKey: Keys.openAITotalCompletionTokens)
    }
}
