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
            guard isInstallableAsset(name) else { return (asset, -1000) }

            var score = 20
            if name.hasSuffix(".dmg") { score = 120 }
            else if name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") { score = 110 }
            else if name.hasSuffix(".app.zip") { score = 100 }
            else if name.hasSuffix(".zip") { score = 90 }
            else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { score = 80 }
            else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { score = 75 }
            else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { score = 72 }
            else if name.hasSuffix(".tar") { score = 68 }
            else if name.hasSuffix(".7z") { score = 66 }
            else if name.hasSuffix(".gz") || name.hasSuffix(".xz") || name.hasSuffix(".bz2") { score = 60 }

            if name.contains("mac") || name.contains("darwin") || name.contains("osx") { score += 15 }
            if name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon") { score += 6 }
            if name.contains("universal") { score += 5 }
            if name.contains("checksum") || name.contains("sha256") || name.contains(".sig") || name.contains(".asc") { score -= 80 }
            if name.contains("windows") || name.contains(".exe") || name.contains(".msi") { score -= 40 }
            if name.contains("linux") && !(name.contains("darwin") || name.contains("mac") || name.contains("osx")) { score -= 25 }
            return (asset, score)
        }
        return scored.max(by: { $0.1 < $1.1 }).flatMap { $0.1 >= 0 ? $0.0 : nil }
    }

    private func isInstallableAsset(_ name: String) -> Bool {
        let suffixes = [
            ".dmg", ".pkg", ".mpkg", ".app.zip",
            ".zip", ".tar.gz", ".tgz", ".tar.xz", ".txz",
            ".tar.bz2", ".tbz2", ".tar", ".7z", ".gz", ".xz", ".bz2",
            ".appimage", ".deb", ".rpm"
        ]
        return suffixes.contains(where: { name.hasSuffix($0) })
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
