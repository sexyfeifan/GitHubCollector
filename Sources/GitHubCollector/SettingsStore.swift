import Foundation

struct AppSettings {
    var openAIKey: String = ""
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var openAIModel: String = "gpt-4.1-mini"
    var retryCount: Int = 2
    var downloadRootPath: String = ""
    var includeNoPackageProjects: Bool = true
}

struct SettingsStore {
    private enum Keys {
        static let openAIKey = "settings.openai.key"
        static let openAIBaseURL = "settings.openai.base_url"
        static let openAIModel = "settings.openai.model"
        static let retryCount = "settings.retry_count"
        static let downloadRootPath = "settings.download.root_path"
        static let includeNoPackageProjects = "settings.include_no_package_projects"
        static let totalTrafficBytes = "metrics.total_traffic_bytes"
    }

    private let ud = UserDefaults.standard

    func load() -> AppSettings {
        var s = AppSettings()
        s.openAIKey = ud.string(forKey: Keys.openAIKey) ?? ""
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
        return s
    }

    func save(_ settings: AppSettings) {
        ud.set(settings.openAIKey, forKey: Keys.openAIKey)
        ud.set(settings.openAIBaseURL, forKey: Keys.openAIBaseURL)
        ud.set(settings.openAIModel, forKey: Keys.openAIModel)
        ud.set(max(1, min(settings.retryCount, 5)), forKey: Keys.retryCount)
        ud.set(settings.downloadRootPath, forKey: Keys.downloadRootPath)
        ud.set(settings.includeNoPackageProjects, forKey: Keys.includeNoPackageProjects)
    }

    func loadTotalTrafficBytes() -> Int64 {
        Int64(ud.object(forKey: Keys.totalTrafficBytes) as? Int ?? 0)
    }

    func saveTotalTrafficBytes(_ bytes: Int64) {
        ud.set(Int(bytes), forKey: Keys.totalTrafficBytes)
    }
}
