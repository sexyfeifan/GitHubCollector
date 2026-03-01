import Foundation

struct TranslationConfig {
    let apiKey: String
    let baseURL: String
    let model: String

    var isEnabled: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct TranslatorService {
    func translateToChinese(_ text: String, config: TranslationConfig) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard config.isEnabled else { return trimmed }

        do {
            return try await translateWithOpenAI(trimmed, config: config)
        } catch {
            return trimmed
        }
    }

    private func translateWithOpenAI(_ text: String, config: TranslationConfig) async throws -> String {
        guard let url = URL(string: "\(config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let payload = OpenAIChatRequest(
            model: config.model,
            temperature: 0.1,
            messages: [
                .init(role: "system", content: "你是专业技术翻译助手。将输入英文技术说明翻译为简体中文，保持术语准确，输出纯文本。"),
                .init(role: "user", content: text)
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        let output = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? text : output
    }
}

struct SummarizerService {
    func summarize(_ text: String, fallbackTitle: String) -> String {
        let source = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty {
            return "\(fallbackTitle)：GitHub 开源项目，可用于快速评估与本地安装。"
        }
        let compact = source
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
        let short = String(compact.prefix(90))
        return short + (compact.count > 90 ? "..." : "")
    }
}

struct ClassifierService {
    func classify(repo: GitHubRepo, text: String) -> String {
        let joined = ([repo.description ?? "", text] + (repo.topics ?? [])).joined(separator: " ").lowercased()
        let rules: [(String, [String])] = [
            ("AI 工具", ["ai", "llm", "rag", "machine learning", "agent", "gpt"]),
            ("开发工具", ["terminal", "cli", "developer", "devtool", "sdk", "compiler", "debug"]),
            ("效率工具", ["note", "todo", "productivity", "task", "calendar", "workflow"]),
            ("媒体工具", ["video", "audio", "image", "media", "photo", "ffmpeg"]),
            ("安全工具", ["security", "encrypt", "crypto", "vulnerability", "auth"]),
            ("系统工具", ["system", "monitor", "performance", "benchmark", "ops"]),
            ("网络工具", ["network", "proxy", "http", "api", "dns", "gateway"]),
            ("数据库工具", ["database", "sql", "postgres", "mysql", "redis", "sqlite"]),
            ("设计工具", ["design", "ui", "figma", "theme", "font"])
        ]

        var bestCategory = "通用工具"
        var bestScore = 0
        for (category, keywords) in rules {
            let score = keywords.reduce(0) { partial, kw in
                partial + (joined.contains(kw) ? 1 : 0)
            }
            if score > bestScore {
                bestScore = score
                bestCategory = category
            }
        }

        if bestScore > 0 {
            return bestCategory
        }
        if let lang = repo.language, !lang.isEmpty {
            return "\(lang) 工具"
        }
        return "通用工具"
    }
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let messages: [Message]
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
