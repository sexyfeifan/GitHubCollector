import Foundation

enum GitHubServiceError: Error, LocalizedError {
    case invalidResponse
    case missingRelease
    case missingAsset
    case rateLimited(resetAt: Date?)
    case repoUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回异常，请稍后重试。"
        case .missingRelease:
            return "该项目暂无可用 Release。"
        case .missingAsset:
            return "最新 Release 没有可下载资产。"
        case .rateLimited(let resetAt):
            if let resetAt {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                f.timeZone = TimeZone.current
                return "GitHub API 已限流，请在 \(f.string(from: resetAt)) 后重试，或在设置中配置 GitHub Token。"
            }
            return "GitHub API 已限流，请稍后重试，或在设置中配置 GitHub Token。"
        case .repoUnavailable:
            return "仓库不存在、已关闭或无访问权限。"
        }
    }
}

struct GitHubService {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    func fetchRepo(_ identity: RepoIdentity, token: String) async throws -> GitHubRepo {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)")!
        let request = makeRequest(url: url, token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        if http.statusCode == 403, isRateLimited(http) {
            throw GitHubServiceError.rateLimited(resetAt: resetDate(http))
        }
        if http.statusCode == 404 || http.statusCode == 410 {
            throw GitHubServiceError.repoUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw GitHubServiceError.invalidResponse
        }

        return try decoder.decode(GitHubRepo.self, from: data)
    }

    func fetchReadmeText(_ identity: RepoIdentity, token: String) async -> String {
        do {
            let apiURL = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)/readme")!
            var apiRequest = makeRequest(url: apiURL, token: token)
            apiRequest.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")

            let (apiData, apiResponse) = try await session.data(for: apiRequest)
            if let http = apiResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let raw = String(data: apiData, encoding: .utf8) ?? ""
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return raw
                }
            }

            let fallback = URL(string: "https://raw.githubusercontent.com/\(identity.owner)/\(identity.name)/HEAD/README.md")!
            let fallbackRequest = makeRequest(url: fallback, token: token)
            let (fallbackData, fallbackResponse) = try await session.data(for: fallbackRequest)
            guard let http = fallbackResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return ""
            }
            return String(data: fallbackData, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    func fetchLatestRelease(_ identity: RepoIdentity, token: String) async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)/releases/latest")!
        let request = makeRequest(url: url, token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubServiceError.invalidResponse }

        if http.statusCode == 404 {
            return nil
        }
        if http.statusCode == 403, isRateLimited(http) {
            throw GitHubServiceError.rateLimited(resetAt: resetDate(http))
        }

        guard (200...299).contains(http.statusCode) else {
            throw GitHubServiceError.invalidResponse
        }

        return try decoder.decode(GitHubRelease.self, from: data)
    }

    func selectAssetsForDownload(from assets: [GitHubAsset], onlyMacOS: Bool = false) -> [GitHubAsset] {
        if onlyMacOS {
            return assets.filter { isInstallableAsset($0.name.lowercased(), onlyMacOS: true) }
        }
        return assets
    }

    func selectBestAsset(from assets: [GitHubAsset], onlyMacOS: Bool = false) -> GitHubAsset? {
        let scored = assets.map { asset -> (GitHubAsset, Int) in
            let name = asset.name.lowercased()
            guard isInstallableAsset(name, onlyMacOS: onlyMacOS) else { return (asset, -1000) }

            var score = 20
            if name.hasSuffix(".dmg") { score = 120 }
            else if name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") { score = 110 }
            else if name.hasSuffix(".app.zip") { score = 100 }
            else if name.hasSuffix(".app") { score = 96 }
            else if name.hasSuffix(".ipa") { score = 94 }
            else if name.hasSuffix(".apk") { score = 92 }
            else if name.hasSuffix(".xapk") || name.hasSuffix(".apks") || name.hasSuffix(".aab") { score = 88 }
            else if name.hasSuffix(".zip") { score = 82 }

            if name.contains("mac") || name.contains("darwin") || name.contains("osx") { score += 15 }
            if name.contains("ios") || name.contains("iphone") || name.contains("ipad") { score += 10 }
            if name.contains("android") { score += 10 }
            if name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon") { score += 6 }
            if name.contains("universal") { score += 5 }
            if name.contains("checksum") || name.contains("sha256") || name.contains(".sig") || name.contains(".asc") { score -= 80 }
            if name.contains("windows") || name.contains(".exe") || name.contains(".msi") { score -= 40 }
            if name.contains("linux") && !(name.contains("darwin") || name.contains("mac") || name.contains("osx")) { score -= 25 }
            return (asset, score)
        }
        return scored.max(by: { $0.1 < $1.1 }).flatMap { $0.1 >= 0 ? $0.0 : nil }
    }

    private func isInstallableAsset(_ name: String, onlyMacOS: Bool) -> Bool {
        let suffixes = [
            ".dmg", ".pkg", ".mpkg", ".app", ".app.zip",
            ".ipa", ".apk", ".xapk", ".apks", ".aab",
            ".zip"
        ]
        guard suffixes.contains(where: { name.hasSuffix($0) }) else { return false }
        if onlyMacOS {
            let macOK = name.hasSuffix(".dmg") || name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") || name.hasSuffix(".app") || name.hasSuffix(".app.zip") || (name.hasSuffix(".zip") && (name.contains("mac") || name.contains("darwin") || name.contains("osx") || name.contains("app")))
            return macOK
        }
        if name.hasSuffix(".zip") {
            return name.contains("app") || name.contains("mac") || name.contains("darwin") || name.contains("osx") ||
                name.contains("ios") || name.contains("iphone") || name.contains("ipad") || name.contains("android")
        }
        return true
    }

    func fetchStarredRepoURLs(username: String, token: String) async throws -> [String] {
        var page = 1
        var all: [String] = []
        while page <= 20 {
            let url = URL(string: "https://api.github.com/users/\(username)/starred?per_page=100&page=\(page)")!
            let request = makeRequest(url: url, token: token)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubServiceError.invalidResponse
            }
            if http.statusCode == 403, isRateLimited(http) {
                throw GitHubServiceError.rateLimited(resetAt: resetDate(http))
            }
            guard (200...299).contains(http.statusCode) else {
                throw GitHubServiceError.invalidResponse
            }

            let repos = try decoder.decode([GitHubRepo].self, from: data)
            if repos.isEmpty { break }
            all.append(contentsOf: repos.map { $0.htmlURL.absoluteString })
            if repos.count < 100 { break }
            page += 1
        }
        return Array(Set(all)).sorted()
    }

    private func makeRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubCollector", forHTTPHeaderField: "User-Agent")
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        if let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining"), remaining == "0" {
            return true
        }
        return false
    }

    private func resetDate(_ response: HTTPURLResponse) -> Date? {
        guard let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
              let ts = TimeInterval(reset) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()
