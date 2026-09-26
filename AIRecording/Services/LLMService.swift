import Foundation

enum LLMError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case networkError
    case noContent
    case invalidAPIKey
    case encodingFailed

    static func == (lhs: LLMError, rhs: LLMError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.apiError(let a), .apiError(let b)): return a == b
        case (.networkError, .networkError): return true
        case (.noContent, .noContent): return true
        case (.invalidAPIKey, .invalidAPIKey): return true
        case (.encodingFailed, .encodingFailed): return true
        default: return false
        }
    }

    var localizedDescription: String {
        switch self {
        case .invalidURL: return "无效的 API 地址"
        case .invalidResponse: return "无效的响应"
        case .apiError(let msg): return "API 错误: \(msg)"
        case .networkError: return "网络错误，请检查网络连接"
        case .noContent: return "AI 未返回内容"
        case .invalidAPIKey: return "API Key 未配置"
        case .encodingFailed: return "请求编码失败"
        }
    }
}

struct LLMMessage: Codable {
    let role: String
    let content: String
}

struct LLMRequestBody: Codable {
    let model: String
    let messages: [LLMMessage]
    let temperature: Double
    let max_tokens: Int
}

struct LLMChoice: Codable {
    let message: LLMMessage
    let finish_reason: String?
}

struct LLMErrorDetail: Codable {
    let message: String
    let type: String?
    let code: String?
}

struct LLMResponse: Codable {
    let choices: [LLMChoice]?
    let error: LLMErrorDetail?
}

class LLMService {
    static let shared = LLMService()

    private let defaults = UserDefaults.standard

    private var baseURL: String {
        defaults.string(forKey: "llm.baseURL") ?? "https://api.deepseek.com/v1"
    }

    private var apiKey: String {
        defaults.string(forKey: "llm.apiKey") ?? ""
    }

    private var model: String {
        defaults.string(forKey: "llm.model") ?? "deepseek-v4-flash"
    }

    private init() {}

    // MARK: - Public API

    func generateSummary(from transcriptionText: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw LLMError.invalidAPIKey
        }

        let prompt = buildSummaryPrompt(transcriptionText)
        return try await sendChatRequest(prompt: prompt)
    }

    // MARK: - Prompt Engineering

    private func buildSummaryPrompt(_ text: String) -> String {
        return """
        你是一个专业的会议纪要助手。请将以下会议/对话转录文本整理成结构化的会议纪要。

        要求：
        1. 提取会议主题（一句话概括）
        2. 识别参与人（从对话内容中推断，如有说话人标识请直接使用）
        3. 总结关键讨论要点（3-7条，按重要性排序）
        4. 明确决策/结论（如有）
        5. 提取待办事项（包含负责人和截止日期，如果有的话）

        输出格式使用 Markdown，语言与输入文本保持一致。

        转录文本：
        \(text)
        """
    }

    // MARK: - Network

    private func sendChatRequest(prompt: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidURL
        }

        let requestBody = LLMRequestBody(
            model: model,
            messages: [LLMMessage(role: "user", content: prompt)],
            temperature: 0.7,
            max_tokens: 4096
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw LLMError.encodingFailed
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let decoded: LLMResponse
        do {
            decoded = try JSONDecoder().decode(LLMResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "无法解析"
            throw LLMError.apiError("解析失败 (HTTP \(httpResponse.statusCode)): \(raw)")
        }

        if let apiError = decoded.error {
            throw LLMError.apiError(apiError.message)
        }

        guard httpResponse.statusCode == 200 else {
            throw LLMError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let firstChoice = decoded.choices?.first else {
            throw LLMError.noContent
        }

        return firstChoice.message.content
    }
}
