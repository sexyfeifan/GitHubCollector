import Foundation

enum GitHubServiceError: Error, LocalizedError {
    case invalidResponse
    case unauthorized
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回异常，请稍后重试。"
        case .unauthorized:
            return "GitHub Token 无效或权限不足。"
        case .rateLimited:
            return "GitHub API 触发限流，请稍后重试或配置有效 Token。"
        }
    }
}

struct GitHubService {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func fetchRepo(_ identity: RepoIdentity, token: String = "") async throws -> GitHubRepo {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)")!
        let (data, _) = try await dataWithAuthFallback(
            url: url,
            token: token,
            accept: "application/vnd.github+json"
        )
        return try decoder.decode(GitHubRepo.self, from: data)
    }

    func fetchReadmeText(_ identity: RepoIdentity, token: String = "") async -> String {
        do {
            // Prefer GitHub API readme endpoint, which can resolve README filename and default branch automatically.
            let apiURL = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)/readme")!
            let (data, response) = try await dataWithAuthFallback(
                url: apiURL,
                token: token,
                accept: "application/vnd.github.raw+json"
            )
            if (200...299).contains(response.statusCode) {
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { return text }
            }
        } catch {
            // Fallback to raw URL probing.
        }

        let candidates = ["README.md", "Readme.md", "readme.md", "README", "readme"]
        for name in candidates {
            do {
                let rawURL = URL(string: "https://raw.githubusercontent.com/\(identity.owner)/\(identity.name)/HEAD/\(name)")!
                let (data, response) = try await URLSession.shared.data(from: rawURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    return text
                }
            } catch {
                continue
            }
        }
        return ""
    }

    func fetchLatestRelease(_ identity: RepoIdentity, token: String = "") async throws -> GitHubRelease? {
        if let latest = try await fetchLatestReleaseFromEndpoint(identity, token: token) {
            if !latest.assets.isEmpty {
                return latest
            }
            if let withAssets = try await fetchNewestReleaseWithAssets(identity, token: token) {
                return withAssets
            }
            return latest
        }

        return try await fetchNewestReleaseWithAssets(identity, token: token)
    }

    private func fetchLatestReleaseFromEndpoint(_ identity: RepoIdentity, token: String) async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)/releases/latest")!
        let request = makeRequest(url: url, token: token, accept: "application/vnd.github+json")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }

        if http.statusCode == 404 {
            return nil
        }
        if (http.statusCode == 401 || http.statusCode == 403), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (retryData, retryHttp) = try await dataWithAuthFallback(
                url: url,
                token: "",
                accept: "application/vnd.github+json",
                allowFallbackToAnonymous: false
            )
            if retryHttp.statusCode == 404 {
                return nil
            }
            return try decoder.decode(GitHubRelease.self, from: retryData)
        }

        try throwIfNeeded(http: http)

        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func fetchReleases(_ identity: RepoIdentity, token: String) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)/releases?per_page=20")!
        let (data, _) = try await dataWithAuthFallback(
            url: url,
            token: token,
            accept: "application/vnd.github+json"
        )
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    private func fetchNewestReleaseWithAssets(_ identity: RepoIdentity, token: String) async throws -> GitHubRelease? {
        let releases = try await fetchReleases(identity, token: token)
        let nonDraft = releases.filter { $0.draft != true }
        let candidates = nonDraft.isEmpty ? releases : nonDraft

        if let withAssets = candidates.first(where: { !$0.assets.isEmpty }) {
            return withAssets
        }
        return candidates.first
    }

    func selectBestAsset(from assets: [GitHubAsset]) -> GitHubAsset? {
        let scored = assets.map { asset -> (GitHubAsset, Int) in
            let name = asset.name.lowercased()
            let score: Int
            if name.hasSuffix(".dmg") { score = 100 }
            else if name.hasSuffix(".pkg") { score = 90 }
            else if name.hasSuffix(".zip") { score = 70 }
            else if name.contains("mac") || name.contains("darwin") || name.contains("osx") { score = 60 }
            else if name.hasSuffix(".tar.gz") { score = 40 }
            else { score = 10 }
            return (asset, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    func fetchStarredRepoURLs(username: String, token: String = "") async throws -> [String] {
        var page = 1
        var all: [String] = []
        while page <= 20 {
            let url = URL(string: "https://api.github.com/users/\(username)/starred?per_page=100&page=\(page)")!
            let (data, _) = try await dataWithAuthFallback(
                url: url,
                token: token,
                accept: "application/vnd.github+json"
            )

            let repos = try decoder.decode([GitHubRepo].self, from: data)
            if repos.isEmpty { break }
            all.append(contentsOf: repos.map { $0.htmlURL.absoluteString })
            if repos.count < 100 { break }
            page += 1
        }
        return Array(Set(all)).sorted()
    }

    func validateToken(_ token: String) async throws -> String {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw GitHubServiceError.unauthorized }

        let url = URL(string: "https://api.github.com/user")!
        let (data, _) = try await dataWithAuthFallback(
            url: url,
            token: cleaned,
            accept: "application/vnd.github+json",
            allowFallbackToAnonymous: false
        )

        struct User: Decodable { let login: String }
        let decoded = try decoder.decode(User.self, from: data)
        return decoded.login
    }

    private func dataWithAuthFallback(
        url: URL,
        token: String,
        accept: String,
        allowFallbackToAnonymous: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let request = makeRequest(url: url, token: token, accept: accept)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        if (200...299).contains(http.statusCode) {
            return (data, http)
        }

        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowFallbackToAnonymous && !cleaned.isEmpty && (http.statusCode == 401 || http.statusCode == 403) {
            let fallbackRequest = makeRequest(url: url, token: "", accept: accept)
            let (fallbackData, fallbackResponse) = try await URLSession.shared.data(for: fallbackRequest)
            guard let fallbackHttp = fallbackResponse as? HTTPURLResponse else {
                throw GitHubServiceError.invalidResponse
            }
            if (200...299).contains(fallbackHttp.statusCode) {
                return (fallbackData, fallbackHttp)
            }
            try throwIfNeeded(http: fallbackHttp)
        }

        try throwIfNeeded(http: http)
        throw GitHubServiceError.invalidResponse
    }

    private func throwIfNeeded(http: HTTPURLResponse) throws {
        if (200...299).contains(http.statusCode) { return }
        if http.statusCode == 401 {
            throw GitHubServiceError.unauthorized
        }
        if http.statusCode == 403, http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
            throw GitHubServiceError.rateLimited
        }
        throw GitHubServiceError.invalidResponse
    }

    private func makeRequest(url: URL, token: String, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("GitHubCollector", forHTTPHeaderField: "User-Agent")
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedToken.isEmpty {
            request.setValue("Bearer \(cleanedToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
