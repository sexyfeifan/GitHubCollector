import Foundation

struct CategoryRules: Codable {
    struct KeywordRule: Codable { let contains: [String]; let category: String }
    var fixed: [String: String]? // "owner/repo" -> category
    var language: [String: String]? // language -> category
    var keywords: [KeywordRule]? // match all keywords (AND)
}

final class CategoryRulesLoader {
    static let shared = CategoryRulesLoader()
    private var cache: [String: CategoryRules] = [:]

    func load(from baseDir: URL) -> CategoryRules? {
        let path = baseDir.appendingPathComponent("categories_rules.json").path
        if let cached = cache[path] { return cached }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let rules = try JSONDecoder().decode(CategoryRules.self, from: data)
            cache[path] = rules
            return rules
        } catch {
            return nil
        }
    }

    func resolveCategory(for record: RepoRecord, baseDir: URL) -> String? {
        guard let rules = load(from: baseDir) else { return nil }
        let full = record.fullName.lowercased()
        if let fx = rules.fixed?.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value },
           let cat = fx[full], !cat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cat
        }
        if !record.language.isEmpty,
           let langMap = rules.language?.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value },
           let cat = langMap[record.language.lowercased()], !cat.isEmpty {
            return cat
        }
        if let kws = rules.keywords {
            let text = (record.descriptionEN + " " + record.descriptionZH).lowercased()
            for rule in kws {
                let allHit = rule.contains.allSatisfy { kw in text.contains(kw.lowercased()) }
                if allHit { return rule.category }
            }
        }
        return nil
    }
}
