import Foundation

enum GitHubServiceError: Error, LocalizedError {
    case invalidResponse
    case missingRelease
    case missingAsset

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回异常，请稍后重试。"
        case .missingRelease:
            return "该项目暂无可用 Release。"
        case .missingAsset:
            return "最新 Release 没有可下载资产。"
        }
    }
}

struct GitHubService {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func fetchRepo(_ identity: RepoIdentity) async throws -> GitHubRepo {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubCollector", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GitHubServiceError.invalidResponse
        }

        return try decoder.decode(GitHubRepo.self, from: data)
    }

    func fetchReadmeText(_ identity: RepoIdentity) async -> String {
        do {
            let url = URL(string: "https://raw.githubusercontent.com/\(identity.owner)/\(identity.name)/HEAD/README.md")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    func fetchLatestRelease(_ identity: RepoIdentity) async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(identity.owner)/\(identity.name)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubCollector", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubServiceError.invalidResponse }

        if http.statusCode == 404 {
            return nil
        }

        guard (200...299).contains(http.statusCode) else {
            throw GitHubServiceError.invalidResponse
        }

        return try decoder.decode(GitHubRelease.self, from: data)
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

    func fetchStarredRepoURLs(username: String) async throws -> [String] {
        var page = 1
        var all: [String] = []
        while page <= 20 {
            let url = URL(string: "https://api.github.com/users/\(username)/starred?per_page=100&page=\(page)")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("GitHubCollector", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
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
}
