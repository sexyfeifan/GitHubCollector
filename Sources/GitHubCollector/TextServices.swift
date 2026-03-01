import Foundation

struct OpenAIUsage {
    let promptTokens: Int
    let completionTokens: Int

    var totalTokens: Int { promptTokens + completionTokens }
}

struct TranslationResult {
    let text: String
    let usage: OpenAIUsage?
}

struct TranslationConfig {
    let apiKey: String
    let baseURL: String
    let model: String

    var isEnabled: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct TranslatorService {
    func translateToChinese(_ text: String, config: TranslationConfig) async -> String {
        let result = await translateToChineseDetailed(text, config: config)
        return result.text
    }

    func translateToChineseDetailed(_ text: String, config: TranslationConfig) async -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TranslationResult(text: "", usage: nil) }
        guard config.isEnabled else { return TranslationResult(text: trimmed, usage: nil) }

        do {
            return try await translateWithOpenAI(trimmed, config: config)
        } catch {
            return TranslationResult(text: trimmed, usage: nil)
        }
    }

    private func translateWithOpenAI(_ text: String, config: TranslationConfig) async throws -> TranslationResult {
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
        let usage = decoded.usage.map { OpenAIUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens) }
        return TranslationResult(text: output.isEmpty ? text : output, usage: usage)
    }
}

struct LayoutFormatterService {
    func formatChineseContent(
        title: String,
        descriptionZH: String,
        releaseNotesZH: String,
        config: TranslationConfig
    ) async -> TranslationResult {
        let source = [descriptionZH, releaseNotesZH].joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return TranslationResult(text: "", usage: nil) }
        guard config.isEnabled else { return TranslationResult(text: source, usage: nil) }

        do {
            guard let url = URL(string: "\(config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))/chat/completions") else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

            let payload = OpenAIChatRequest(
                model: config.model,
                temperature: 0.2,
                messages: [
                    .init(role: "system", content: "你是技术文档编辑。将输入整理为结构清晰的简体中文 Markdown，保留命令/版本信息，不要编造内容。"),
                    .init(role: "user", content: "项目：\(title)\n\n请离线排版以下内容：\n\(source)")
                ]
            )
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            let output = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usage = decoded.usage.map { OpenAIUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens) }
            return TranslationResult(text: output.isEmpty ? source : output, usage: usage)
        } catch {
            return TranslationResult(text: source, usage: nil)
        }
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

struct SetupGuideExtractor {
    func extract(from markdown: String) -> String {
        guard !markdown.isEmpty else { return "" }
        let codeBlocks = extractCodeBlocks(from: markdown)
        let hits = codeBlocks.filter { block in
            let lower = block.lowercased()
            return lower.contains("docker") ||
                lower.contains("docker compose") ||
                lower.contains("compose.yml") ||
                lower.contains("docker-compose")
        }
        guard !hits.isEmpty else { return "" }
        return hits.prefix(3).map { "```bash\n\($0)\n```" }.joined(separator: "\n\n")
    }

    private func extractCodeBlocks(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_-]*\\n([\\s\\S]*?)```") else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
    let usage: Usage?

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}
