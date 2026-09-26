import Foundation

final class HTTPChartSkill: ChartSkill, @unchecked Sendable {
    static let shared = HTTPChartSkill()

    let skillId = "chart.agent.v5"
    let skillVersion = "5.0.0"
    let displayName = "智能图表生成"

    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval = 120

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - ChartSkill

    func checkAvailability() async -> Bool {
        return await checkHealth()
    }

    func generate(request: SmartChartGenerateRequest) async throws -> SmartChartGenerateResponse {
        // Sanitize at the transport boundary: drop blank segments and trim text
        // so the backend never receives whitespace-only transcript bodies.
        let cleanedSegments = request.segments.compactMap { segment -> TranscriptSegmentDTO? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegmentDTO(
                id: segment.id,
                speaker: segment.speaker,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: text
            )
        }
        guard !cleanedSegments.isEmpty else {
            throw ChartSkillError.contentTooShort
        }
        let transportRequest = SmartChartGenerateRequest(
            requestId: request.requestId,
            recordingId: request.recordingId,
            segments: cleanedSegments,
            summaryMarkdown: request.summaryMarkdown,
            forceContentType: request.forceContentType
        )

        let available = await checkAvailability()
        if !available {
            let started = await ChartServiceManager.shared.ensureServiceRunning()
            guard started else {
                throw ChartSkillError.serviceNotRunning
            }
        }

        let url = baseURL.appendingPathComponent("/chart/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = timeout

        do {
            urlRequest.httpBody = try JSONEncoder().encode(transportRequest)
        } catch {
            throw ChartSkillError.invalidRequest
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw ChartSkillError.timeout
        } catch {
            throw ChartSkillError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChartSkillError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChartSkillError.generationFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let result: SmartChartGenerateResponse
        do {
            result = try JSONDecoder().decode(SmartChartGenerateResponse.self, from: data)
        } catch {
            throw ChartSkillError.decodingFailed
        }
        // Reject responses that belong to a different request so a stale or
        // misrouted body can never surface as this request's result.
        guard result.requestId == request.requestId else {
            throw ChartSkillError.invalidResponse
        }
        if result.status == "failed" {
            if result.errorCode == "TIMEOUT" {
                throw ChartSkillError.timeout
            }
            throw ChartSkillError.generationFailed(result.errors.first ?? "未知错误")
        }
        return result
    }

    /// 纯渲染接口（编辑回路专用）：只要求服务在线，不主动拉起服务、不走 LLM 链路。
    func render(request: SmartChartRenderRequest) async throws -> SmartChartRenderResponse {
        let available = await checkHealth()
        if !available {
            throw ChartSkillError.serviceNotRunning
        }

        let url = baseURL.appendingPathComponent("/chart/render")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 15

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw ChartSkillError.invalidRequest
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw ChartSkillError.timeout
        } catch {
            throw ChartSkillError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChartSkillError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ChartSkillError.generationFailed("HTTP \(httpResponse.statusCode)")
        }

        let result: SmartChartRenderResponse
        do {
            result = try JSONDecoder().decode(SmartChartRenderResponse.self, from: data)
        } catch {
            throw ChartSkillError.decodingFailed
        }
        guard result.requestId == request.requestId else {
            throw ChartSkillError.invalidResponse
        }
        if result.status == "failed" {
            if result.errorCode == "TIMEOUT" {
                throw ChartSkillError.timeout
            }
            throw ChartSkillError.validationFailed(result.errorCode ?? "RENDER_FAILED")
        }
        return result
    }

    // MARK: - Health Check

    func checkHealth() async -> Bool {
        let url = baseURL.appendingPathComponent("/health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard httpResponse.statusCode == 200,
                  let health = try? JSONDecoder().decode(ChartHealthInfo.self, from: data) else {
                return false
            }
            return ChartServiceManager.isSupportedHealth(health)
        } catch {
            return false
        }
    }
}

extension HTTPChartSkill: MindMapRendering {}
