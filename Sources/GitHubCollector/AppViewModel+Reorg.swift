import Foundation

extension AppViewModel {
    // Public entry
    func startReorganizePreview() {
        buildReorgPreview()
        showReorgPreview = true
    }

    // Core logic
    @MainActor
    func runReorganizeCategories(selectedIDs: Set<String>? = nil) async {
        errorMessage = ""
        isLoading = true
        defer { isLoading = false }

        log("开始重新整理项目到类型分类文件夹...")
        reloadRecords()
        guard !records.isEmpty else {
            statusMessage = "无记录可整理。"
            log("无记录可整理。")
            return
        }

        let fm = FileManager.default
        let base = StorageService().resolvedBaseDir(customPath: downloadRootPath)
        var moved = 0
        var examined = 0

        let targets = records.filter { r in
            if let set = selectedIDs { return set.contains(r.id) }
            return true
        }
        let total = targets.count
        var index = 0

        for r in targets {
            index += 1
            examined += 1
            let currentCat = (folderCategoryFromPaths(for: r, base: base) ?? r.category)
            let targetCat = computeTypeCategory(for: r)
            if targetCat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("(\(index)/\(total)) \(r.projectName) -> 未识别分类，跳过")
                continue
            }
            log("(\(index)/\(total)) \(r.projectName) -> \(targetCat)")
            if currentCat == targetCat && currentCat != "有安装包项目" && currentCat != "无安装包项目" && currentCat != "未分类" { continue }
            if currentCat == targetCat { continue }

            let src = base.appendingPathComponent(safeName(currentCat)).appendingPathComponent(safeName(r.projectName), isDirectory: true)
            let dstParent = base.appendingPathComponent(safeName(targetCat), isDirectory: true)
            let dst = dstParent.appendingPathComponent(safeName(r.projectName), isDirectory: true)

            do {
                try fm.createDirectory(at: dstParent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) {
                    if let files = try? fm.contentsOfDirectory(atPath: src.path) {
                        for name in files {
                            let s = src.appendingPathComponent(name)
                            let d = dst.appendingPathComponent(name)
                            if fm.fileExists(atPath: d.path) { continue }
                            try? fm.moveItem(at: s, to: d)
                        }
                        try? fm.removeItem(at: src)
                    }
                } else {
                    try? fm.moveItem(at: src, to: dst)
                }

                var updated = r
                updated.category = targetCat
                let oldDir = src.standardizedFileURL.path
                let newDir = dst.standardizedFileURL.path
                if !updated.infoFilePath.isEmpty, updated.infoFilePath.hasPrefix(oldDir) {
                    updated.infoFilePath = updated.infoFilePath.replacingOccurrences(of: oldDir, with: newDir)
                } else {
                    updated.infoFilePath = dst.appendingPathComponent("README_COLLECTOR.md").path
                }
                if !updated.localPath.isEmpty, updated.localPath.hasPrefix(oldDir) {
                    updated.localPath = updated.localPath.replacingOccurrences(of: oldDir, with: newDir)
                }
                if !updated.previewImagePath.isEmpty, updated.previewImagePath.hasPrefix(oldDir) {
                    updated.previewImagePath = updated.previewImagePath.replacingOccurrences(of: oldDir, with: newDir)
                }

                let ss = StorageService()
                try? ss.saveRecord(updated, baseDir: base)
                moved += 1
                log("已整理：\(r.projectName) => \(targetCat)")
            } catch {
                log("整理失败：\(r.projectName) - \(error.localizedDescription)")
            }
        }

        for stale in ["有安装包项目", "无安装包项目"] {
            let dir = base.appendingPathComponent(safeName(stale))
            if let items = try? fm.contentsOfDirectory(atPath: dir.path), items.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }

        reloadRecords()
        statusMessage = "整理完成：检查 \(examined) 项，移动 \(moved) 项。"
        log(statusMessage)
    }

    // Category resolver used by reorganizer
    func computeTypeCategory(for record: RepoRecord) -> String {
        // rules override first
        let base = StorageService().resolvedBaseDir(customPath: downloadRootPath)
        if let cat = CategoryRulesLoader.shared.resolveCategory(for: record, baseDir: base), !cat.isEmpty {
            return cat
        }
        // fallback to classifier
        let desc = record.descriptionEN.isEmpty ? record.descriptionZH : record.descriptionEN
        let lang: String? = (record.language == "Unknown") ? nil : record.language
        let url = URL(string: record.sourceURL) ?? URL(string: "https://github.com/\(record.fullName)")!
        let stub = GitHubRepo(
            name: record.projectName,
            fullName: record.fullName,
            description: desc,
            language: lang,
            stargazersCount: record.stars,
            htmlURL: url,
            topics: nil,
            updatedAt: nil,
            archived: nil,
            disabled: nil,
            fork: record.isFork
        )
        return ClassifierService().classify(repo: stub, text: desc)
    }

    private func safeName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private func folderCategoryFromPaths(for record: RepoRecord, base: URL) -> String? {
        let basePath = (record.storageRootPath.isEmpty ? base.path : record.storageRootPath)
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
                if !category.isEmpty { return category }
            }
        }
        return nil
    }


    private func buildReorgPreview() {
        var items: [ReorgPreviewItem] = []
        let base = StorageService().resolvedBaseDir(customPath: downloadRootPath)
        for r in records {
            let currentCat = (folderCategoryFromPaths(for: r, base: base) ?? r.category)
            let targetCat = computeTypeCategory(for: r)
            if currentCat == targetCat && currentCat != "有安装包项目" && currentCat != "无安装包项目" && currentCat != "未分类" { continue }
            items.append(ReorgPreviewItem(id: r.id, selected: true, name: r.projectName, currentCategory: currentCat, targetCategory: targetCat))
        }
        reorgPreviewItems = items
    }

    func setAllReorgPreviewItems(_ value: Bool) {
        reorgPreviewItems = reorgPreviewItems.map { var it = $0; it.selected = value; return it }
    }

    func confirmReorganizeFromPreview() {
        let ids = Set(reorgPreviewItems.filter { $0.selected }.map { $0.id })
        showReorgPreview = false
        Task { @MainActor in
            await runReorganizeCategories(selectedIDs: ids)
        }
    }
}


extension AppViewModel {
    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        realtimeLogs.append("[\(ts)] " + message)
        if realtimeLogs.count > 5000 { realtimeLogs.removeFirst(realtimeLogs.count - 4000) }
    }
}
