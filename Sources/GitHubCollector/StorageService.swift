import Foundation

struct StorageService {
    private let fm = FileManager.default

    var defaultBaseDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/GitHubCollector", isDirectory: true)
    }

    func resolvedBaseDir(customPath: String) -> URL {
        let cleaned = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return defaultBaseDir
        }
        return URL(fileURLWithPath: cleaned, isDirectory: true)
    }

    func dbURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("records.json")
    }

    func ignoredIDsURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("ignored_ids.json")
    }

    func knownURLsURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("known_urls.json")
    }

    func prepareBaseIfNeeded(baseDir: URL) throws {
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    func directorySize(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    func categoryDir(baseDir: URL, _ category: String) -> URL {
        baseDir.appendingPathComponent(safe(category), isDirectory: true)
    }

    func projectDir(baseDir: URL, category: String, project: String) -> URL {
        categoryDir(baseDir: baseDir, category).appendingPathComponent(safe(project), isDirectory: true)
    }

    func hasProjectDirectory(baseDir: URL, project: String) -> Bool {
        let safeProject = safe(project)
        guard let categories = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for categoryDir in categories {
            let candidate = categoryDir.appendingPathComponent(safeProject, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        return false
    }

    func removeProjectDirectories(baseDir: URL, project: String) {
        let safeProject = safe(project)
        guard let categories = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for categoryDir in categories {
            let candidate = categoryDir.appendingPathComponent(safeProject, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.removeItem(at: candidate)
            }
        }
    }

    func saveOrUpdate(_ draft: RepoDraft, baseDir: URL) throws -> RepoRecord {
        try prepareBaseIfNeeded(baseDir: baseDir)

        var records = try loadRecords(baseDir: baseDir)
        let id = draft.identity.fullName.lowercased()
        try removeIgnoredID(id, baseDir: baseDir)

        let pDir = projectDir(baseDir: baseDir, category: draft.category, project: draft.projectName)
        try fm.createDirectory(at: pDir, withIntermediateDirectories: true)

        let infoJSON = pDir.appendingPathComponent("project_info.json")
        let infoMD = pDir.appendingPathComponent("README_COLLECTOR.md")

        let record = RepoRecord(
            id: id,
            owner: draft.identity.owner,
            repo: draft.identity.name,
            projectName: draft.projectName,
            sourceURL: draft.sourceURL.absoluteString,
            descriptionEN: draft.descriptionEN,
            descriptionZH: draft.descriptionZH,
            summaryZH: draft.summaryZH,
            releaseNotesEN: draft.releaseNotesEN,
            releaseNotesZH: draft.releaseNotesZH,
            setupGuideEN: draft.setupGuideEN,
            formattedZH: draft.formattedZH,
            category: draft.category,
            language: draft.language,
            stars: draft.stars,
            isFork: draft.isFork,
            releaseTag: draft.releaseTag,
            releaseAssetName: draft.releaseAssetName,
            releaseAssetURL: draft.releaseAssetURL,
            hasDownloadAsset: draft.hasDownloadAsset,
            localPath: draft.localPath,
            previewImagePath: draft.previewImagePath,
            storageRootPath: baseDir.path,
            infoFilePath: infoMD.path,
            updatedAt: Date()
        )
        return try upsertAndWrite(record, records: &records, baseDir: baseDir, infoJSON: infoJSON, infoMD: infoMD)
    }

    func saveRecord(_ record: RepoRecord, baseDir: URL) throws {
        try prepareBaseIfNeeded(baseDir: baseDir)
        var records = try loadRecords(baseDir: baseDir)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        try writeRecords(records, baseDir: baseDir)

        let infoPath: URL
        if record.infoFilePath.isEmpty {
            let pDir = projectDir(baseDir: baseDir, category: record.category, project: record.projectName)
            try fm.createDirectory(at: pDir, withIntermediateDirectories: true)
            infoPath = pDir.appendingPathComponent("README_COLLECTOR.md")
        } else {
            infoPath = URL(fileURLWithPath: record.infoFilePath)
        }
        let infoJSON = infoPath.deletingLastPathComponent().appendingPathComponent("project_info.json")
        try writeProjectInfoJSON(record, at: infoJSON)
        try writeProjectInfoMarkdown(record, at: infoPath)
    }

    func deleteRecord(_ record: RepoRecord, baseDir: URL, removeFiles: Bool) throws {
        try prepareBaseIfNeeded(baseDir: baseDir)
        try addIgnoredID(record.id, baseDir: baseDir)
        var records = try loadRecords(baseDir: baseDir)
        records.removeAll { $0.id == record.id }
        try writeRecords(records, baseDir: baseDir)

        if !record.infoFilePath.isEmpty {
            try? fm.removeItem(atPath: record.infoFilePath)
            let infoJSON = URL(fileURLWithPath: record.infoFilePath)
                .deletingLastPathComponent()
                .appendingPathComponent("project_info.json")
            try? fm.removeItem(at: infoJSON)
        }

        guard removeFiles else { return }
        if !record.localPath.isEmpty, fm.fileExists(atPath: record.localPath) {
            try? fm.removeItem(atPath: record.localPath)
        }
        if !record.previewImagePath.isEmpty, fm.fileExists(atPath: record.previewImagePath) {
            try? fm.removeItem(atPath: record.previewImagePath)
        }

        let projectDir = self.projectDir(baseDir: baseDir, category: record.category, project: record.projectName)
        try removeDirectoryIfEmpty(projectDir)
        try removeDirectoryIfEmpty(projectDir.deletingLastPathComponent())
    }

    func loadKnownURLs(baseDir: URL) throws -> [String] {
        try prepareBaseIfNeeded(baseDir: baseDir)
        let url = knownURLsURL(baseDir: baseDir)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func saveKnownURLs(_ urls: [String], baseDir: URL) throws {
        try prepareBaseIfNeeded(baseDir: baseDir)
        let cleaned = Array(Set(
            urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )).sorted()
        let data = try JSONEncoder.pretty.encode(cleaned)
        try data.write(to: knownURLsURL(baseDir: baseDir), options: .atomic)
    }

    func loadRecords(baseDir: URL, macOnly: Bool = false) throws -> [RepoRecord] {
        try prepareBaseIfNeeded(baseDir: baseDir)

        let db = dbURL(baseDir: baseDir)
        let recordsFromDB: [RepoRecord]
        if fm.fileExists(atPath: db.path) {
            let data = try Data(contentsOf: db)
            recordsFromDB = try JSONDecoder.compat.decode([RepoRecord].self, from: data)
        } else {
            recordsFromDB = []
        }

        let fromInfoFiles = try scanInfoFiles(baseDir: baseDir)
        let inferred = try inferRecordsFromPackages(baseDir: baseDir, macOnly: macOnly)
        let folderInferred = try inferRecordsFromProjectFolders(baseDir: baseDir, macOnly: macOnly)
        let ignored = try loadIgnoredIDs(baseDir: baseDir)

        var merged: [String: RepoRecord] = [:]
        for r in recordsFromDB + fromInfoFiles + inferred + folderInferred {
            if let existing = merged[r.id] {
                merged[r.id] = existing.updatedAt >= r.updatedAt ? existing : r
            } else {
                merged[r.id] = r
            }
        }

        let sorted = merged.values
            .filter { !ignored.contains($0.id) }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
        try writeRecords(sorted, baseDir: baseDir)
        return sorted
    }

    private func upsertAndWrite(
        _ record: RepoRecord,
        records: inout [RepoRecord],
        baseDir: URL,
        infoJSON: URL,
        infoMD: URL
    ) throws -> RepoRecord {
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        try writeRecords(records, baseDir: baseDir)
        try writeProjectInfoJSON(record, at: infoJSON)
        try writeProjectInfoMarkdown(record, at: infoMD)
        return record
    }

    private func writeRecords(_ records: [RepoRecord], baseDir: URL) throws {
        let data = try JSONEncoder.pretty.encode(records.sorted(by: { $0.updatedAt > $1.updatedAt }))
        try data.write(to: dbURL(baseDir: baseDir), options: .atomic)
    }

    private func writeProjectInfoJSON(_ record: RepoRecord, at url: URL) throws {
        let data = try JSONEncoder.pretty.encode(record)
        try data.write(to: url, options: .atomic)
    }

    private func writeProjectInfoMarkdown(_ record: RepoRecord, at url: URL) throws {
        let content = """
        # \(record.projectName)

        - Full Name: \(record.fullName)
        - Category: \(record.category)
        - Stars: \(record.stars)
        - Language: \(record.language)
        - Latest Tag: \(record.releaseTag)
        - Asset: \(record.releaseAssetName)
        - Source: \(record.sourceURL)
        - Local Path: \(record.localPath.isEmpty ? "(none)" : record.localPath)

        ## Summary (ZH)
        \(record.summaryZH)

        ## Description (EN)
        \(record.descriptionEN)

        ## Description (ZH)
        \(record.descriptionZH)

        ## Release Notes (EN)
        \(record.releaseNotesEN)

        ## Release Notes (ZH)
        \(record.releaseNotesZH)

        ## Setup Guide (EN)
        \(record.setupGuideEN)

        ## Formatted (ZH)
        \(record.formattedZH)
        """
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func scanInfoFiles(baseDir: URL) throws -> [RepoRecord] {
        guard let enumerator = fm.enumerator(
            at: baseDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var records: [RepoRecord] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent != "project_info.json" { continue }
            do {
                let data = try Data(contentsOf: fileURL)
                var record = try JSONDecoder.compat.decode(RepoRecord.self, from: data)
                if record.storageRootPath.isEmpty {
                    record.storageRootPath = baseDir.path
                }
                records.append(record)
            } catch {
                continue
            }
        }
        return records
    }

    private func inferRecordsFromPackages(baseDir: URL, macOnly: Bool) throws -> [RepoRecord] {
        guard let enumerator = fm.enumerator(
            at: baseDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let validSuffixes = [
            ".dmg", ".pkg", ".mpkg", ".app", ".app.zip",
            ".ipa", ".apk", ".xapk", ".apks", ".aab",
            ".zip"
        ]
        var inferred: [RepoRecord] = []

        for case let fileURL as URL in enumerator {
            let lower = fileURL.lastPathComponent.lowercased()
            guard validSuffixes.contains(where: { lower.hasSuffix($0) }) else { continue }
            if macOnly {
                let macOK = lower.hasSuffix(".dmg") || lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") || lower.hasSuffix(".app") || lower.hasSuffix(".app.zip") || (lower.hasSuffix(".zip") && (lower.contains("mac") || lower.contains("darwin") || lower.contains("osx") || lower.contains("app")))
                if !macOK { continue }
            } else if lower.hasSuffix(".zip") {
                let zipLikeInstall = lower.contains("app") || lower.contains("mac") || lower.contains("darwin") ||
                    lower.contains("osx") || lower.contains("ios") || lower.contains("iphone") ||
                    lower.contains("ipad") || lower.contains("android")
                if !zipLikeInstall { continue }
            }

            let rel = fileURL.path.replacingOccurrences(of: baseDir.path + "/", with: "")
            let comps = rel.split(separator: "/").map(String.init)
            guard comps.count >= 3 else { continue }

            let category = comps[0]
            let project = comps[1]
            let id = "local/\(safe(project).lowercased())"

            let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let record = RepoRecord(
                id: id,
                owner: "local",
                repo: safe(project).lowercased(),
                projectName: project,
                sourceURL: "",
                descriptionEN: "Detected from existing files in selected storage path.",
                descriptionZH: "从所选存储路径检测到的已有软件文件。",
                summaryZH: "检测到本地历史文件：\(fileURL.lastPathComponent)",
                releaseNotesEN: "",
                releaseNotesZH: "",
                setupGuideEN: "",
                formattedZH: "",
                category: category,
                language: "Unknown",
                stars: 0,
                isFork: false,
                releaseTag: "Unknown",
                releaseAssetName: fileURL.lastPathComponent,
                releaseAssetURL: "",
                hasDownloadAsset: true,
                localPath: fileURL.path,
                previewImagePath: "",
                storageRootPath: baseDir.path,
                infoFilePath: "",
                updatedAt: mod
            )
            inferred.append(record)
        }

        return inferred
    }


    private func inferRecordsFromProjectFolders(baseDir: URL, macOnly: Bool) throws -> [RepoRecord] {
        let validSuffixes = [
            ".dmg", ".pkg", ".mpkg", ".app", ".app.zip",
            ".ipa", ".apk", ".xapk", ".apks", ".aab",
            ".zip"
        ]

        func isInstallFileName(_ name: String) -> Bool {
            let lower = name.lowercased()
            guard validSuffixes.contains(where: { lower.hasSuffix($0) }) else { return false }

            if macOnly {
                if lower.hasSuffix(".dmg") || lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") ||
                    lower.hasSuffix(".app") || lower.hasSuffix(".app.zip") {
                    return true
                }
                if lower.hasSuffix(".zip") {
                    return lower.contains("mac") || lower.contains("darwin") || lower.contains("osx") || lower.contains("app")
                }
                return false
            }

            if lower.hasSuffix(".zip") {
                let zipLikeInstall = lower.contains("app") || lower.contains("mac") || lower.contains("darwin") ||
                    lower.contains("osx") || lower.contains("ios") || lower.contains("iphone") ||
                    lower.contains("ipad") || lower.contains("android")
                return zipLikeInstall
            }

            return true
        }

        guard let categories = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var inferred: [RepoRecord] = []

        for categoryDir in categories {
            var isCatDir: ObjCBool = false
            guard fm.fileExists(atPath: categoryDir.path, isDirectory: &isCatDir), isCatDir.boolValue else { continue }

            let category = categoryDir.lastPathComponent
            let projects = (try? fm.contentsOfDirectory(
                at: categoryDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for projectDir in projects {
                var isProjDir: ObjCBool = false
                guard fm.fileExists(atPath: projectDir.path, isDirectory: &isProjDir), isProjDir.boolValue else { continue }

                let projectName = projectDir.lastPathComponent
                if fm.fileExists(atPath: projectDir.appendingPathComponent("project_info.json").path) { continue }

                let entries = (try? fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

                let fileNames: [String] = entries.compactMap { url in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return isDir ? nil : url.lastPathComponent
                }

                // If this folder already has a recognizable install package, prefer package inference.
                if fileNames.contains(where: isInstallFileName) { continue }

                let sorted = fileNames.sorted()
                let sampleCSV = sorted.prefix(12).joined(separator: ", ")
                let descEN = sampleCSV.isEmpty
                    ? "Detected local project folder: \(projectName)."
                    : "Detected local project folder: \(projectName). Files: \(sampleCSV)"
                let summaryZH = sampleCSV.isEmpty
                    ? "从本地文件夹检测到项目目录（未识别安装包）。"
                    : "从本地文件夹检测到文件：\(sorted.prefix(6).joined(separator: ", "))"

                let mod = (try? projectDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let id = "folder/\(safe(category).lowercased())/\(safe(projectName).lowercased())"

                inferred.append(RepoRecord(
                    id: id,
                    owner: "local",
                    repo: safe(projectName).lowercased(),
                    projectName: projectName,
                    sourceURL: "",
                    descriptionEN: descEN,
                    descriptionZH: "",
                    summaryZH: summaryZH,
                    releaseNotesEN: "",
                    releaseNotesZH: "",
                    setupGuideEN: "",
                    formattedZH: "",
                    category: category,
                    language: "Unknown",
                    stars: 0,
                    isFork: false,
                    releaseTag: "Unknown",
                    releaseAssetName: "文件夹（未识别安装包）",
                    releaseAssetURL: "",
                    hasDownloadAsset: false,
                    localPath: "",
                    previewImagePath: "",
                    storageRootPath: baseDir.path,
                    infoFilePath: "",
                    updatedAt: mod
                ))
            }
        }

        return inferred
    }
    private func safe(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private func loadIgnoredIDs(baseDir: URL) throws -> Set<String> {
        let url = ignoredIDsURL(baseDir: baseDir)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let arr = try JSONDecoder().decode([String].self, from: data)
        return Set(arr)
    }

    private func addIgnoredID(_ id: String, baseDir: URL) throws {
        var set = try loadIgnoredIDs(baseDir: baseDir)
        set.insert(id)
        let data = try JSONEncoder().encode(Array(set).sorted())
        try data.write(to: ignoredIDsURL(baseDir: baseDir), options: .atomic)
    }

    private func removeIgnoredID(_ id: String, baseDir: URL) throws {
        var set = try loadIgnoredIDs(baseDir: baseDir)
        set.remove(id)
        let data = try JSONEncoder().encode(Array(set).sorted())
        try data.write(to: ignoredIDsURL(baseDir: baseDir), options: .atomic)
    }


    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        let contents = try fm.contentsOfDirectory(atPath: url.path)
        if contents.isEmpty {
            try? fm.removeItem(at: url)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var compat: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let stringValue = try? container.decode(String.self)
            if let str = stringValue {
                let iso = ISO8601DateFormatter()
                if let date = iso.date(from: str) {
                    return date
                }
            }
            if let ts = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ts)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format")
        }
        return d
    }
}
