import Foundation

struct DownloadProgressInfo {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speedBytesPerSec: Double
    let sourceURL: URL

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }
}

struct RepoSyncResult {
    let localPath: String
    let cloned: Bool
}

enum DownloadServiceError: Error, LocalizedError {
    case gitUnavailable
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return "系统未找到 git 命令。"
        case .gitFailed(let output):
            return "同步仓库失败：\(output)"
        }
    }
}

struct DownloadService {
    private let fm = FileManager.default

    func download(
        asset: GitHubAsset,
        to projectDir: URL,
        onProgress: ((DownloadProgressInfo) -> Void)? = nil
    ) async throws -> URL {
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let destination = projectDir.appendingPathComponent(asset.name)
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        let helper = DownloadTaskHelper(url: asset.browserDownloadURL, onProgress: onProgress)
        let tmpURL = try await helper.start()
        try fm.moveItem(at: tmpURL, to: destination)
        return destination
    }

    func syncRepository(identity: RepoIdentity, to projectDir: URL) async throws -> RepoSyncResult {
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let repoDir = projectDir.appendingPathComponent("source", isDirectory: true)
        let gitMetadata = repoDir.appendingPathComponent(".git", isDirectory: true)
        let remote = "https://github.com/\(identity.owner)/\(identity.name).git"

        if fm.fileExists(atPath: gitMetadata.path) {
            _ = try await runGit(arguments: ["-C", repoDir.path, "pull", "--ff-only"])
            return RepoSyncResult(localPath: repoDir.path, cloned: false)
        }

        if fm.fileExists(atPath: repoDir.path) {
            return RepoSyncResult(localPath: repoDir.path, cloned: false)
        }

        _ = try await runGit(arguments: ["clone", "--depth", "1", remote, repoDir.path])
        return RepoSyncResult(localPath: repoDir.path, cloned: true)
    }

    func downloadImage(from url: URL, to projectDir: URL) async -> String {
        do {
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let name = imageFileName(from: url)
            let destination = projectDir.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                return destination.path
            }

            let helper = DownloadTaskHelper(url: url, onProgress: nil)
            let tmpURL = try await helper.start()
            try fm.moveItem(at: tmpURL, to: destination)
            return destination.path
        } catch {
            return ""
        }
    }

    private func imageFileName(from url: URL) -> String {
        let last = url.lastPathComponent
        if last.isEmpty || !last.contains(".") {
            return "preview_image.jpg"
        }
        return "preview_" + last
    }

    private func runGit(arguments: [String]) async throws -> String {
        let gitPath = "/usr/bin/git"
        guard fm.isExecutableFile(atPath: gitPath) else {
            throw DownloadServiceError.gitUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = arguments

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            process.terminationHandler = { proc in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let merged = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: merged)
                } else {
                    continuation.resume(throwing: DownloadServiceError.gitFailed(merged.isEmpty ? "git exit \(proc.terminationStatus)" : merged))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class DownloadTaskHelper: NSObject, URLSessionDownloadDelegate {
    private let sourceURL: URL
    private let onProgress: ((DownloadProgressInfo) -> Void)?

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var startTime = Date()
    private var lastTickTime = Date()
    private var lastBytes: Int64 = 0

    init(url: URL, onProgress: ((DownloadProgressInfo) -> Void)?) {
        self.sourceURL = url
        self.onProgress = onProgress
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            continuation = cont
            let config = URLSessionConfiguration.default
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            startTime = Date()
            lastTickTime = startTime
            lastBytes = 0
            let task = session!.downloadTask(with: sourceURL)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        continuation?.resume(returning: location)
        continuation = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let onProgress else { return }
        let now = Date()
        let deltaT = now.timeIntervalSince(lastTickTime)
        if deltaT < 0.2 { return }

        let deltaBytes = totalBytesWritten - lastBytes
        let speed = deltaT > 0 ? Double(deltaBytes) / deltaT : 0
        lastTickTime = now
        lastBytes = totalBytesWritten

        onProgress(
            DownloadProgressInfo(
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                speedBytesPerSec: max(speed, 0),
                sourceURL: sourceURL
            )
        )
    }
}
