import CoreData
import Foundation
import XCTest
@testable import AIRecording

final class SmartChartTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testHealthRejectsStaleBackends() async {
        let v2Service = makeService { request in
            XCTAssertEqual(request.url?.path, "/health")
            return self.response(
                url: request.url!,
                json: #"{"status":"ok","apiVersion":"2.0","serviceVersion":"2.0.0","llmConfigured":true}"#
            )
        }
        let v2Healthy = await v2Service.checkHealth()
        XCTAssertFalse(v2Healthy)

        // Same protocol but an older service build: stale, must be replaced.
        let staleService = makeService { request in
            self.response(
                url: request.url!,
                json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"4.0.0","llmConfigured":true}"#
            )
        }
        let staleHealthy = await staleService.checkHealth()
        XCTAssertFalse(staleHealthy)

        let v5Service = makeService { request in
            self.response(
                url: request.url!,
                json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#
            )
        }
        let v5Healthy = await v5Service.checkHealth()
        XCTAssertTrue(v5Healthy)
    }

    func testSupportedHealthRequiresMatchingServiceVersion() {
        let current = ChartHealthInfo(status: "ok", apiVersion: "5.0", serviceVersion: "5.0.0")
        XCTAssertTrue(ChartServiceManager.isSupportedHealth(current))

        let stale = ChartHealthInfo(status: "ok", apiVersion: "5.0", serviceVersion: "4.0.0")
        XCTAssertFalse(ChartServiceManager.isSupportedHealth(stale))

        let wrongProtocol = ChartHealthInfo(status: "ok", apiVersion: "2.0", serviceVersion: "5.0.0")
        XCTAssertFalse(ChartServiceManager.isSupportedHealth(wrongProtocol))

        let down = ChartHealthInfo(status: "error", apiVersion: "5.0", serviceVersion: "5.0.0")
        XCTAssertFalse(ChartServiceManager.isSupportedHealth(down))
    }

    func testFailedResponsePreservesGenerationError() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(
                    url: request.url!,
                    json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#
                )
            }
            return self.response(url: request.url!, json: self.failedResponseJSON)
        }

        let request = SmartChartGenerateRequest(
            requestId: "request-1",
            recordingId: "recording-1",
            segments: [
                TranscriptSegmentDTO(
                    id: "segment-1",
                    speaker: "发言人",
                    startTime: 0,
                    endTime: 5,
                    text: "这是一个长度足够的测试转录片段，用来验证错误信息能够正确返回。"
                )
            ]
        )

        do {
            _ = try await service.generate(request: request)
            XCTFail("Expected generationFailed")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .generationFailed("LLM 图表路由失败"))
        }
    }

    func testEarliestSourceUsesStartTimeInsteadOfArrayOrder() {
        let result = ChartSourceResolver.earliestSegmentID(
            in: ["later", "missing", "earlier"],
            startTimes: ["later": 20, "earlier": 5]
        )
        XCTAssertEqual(result, "earlier")
        XCTAssertNil(ChartSourceResolver.earliestSegmentID(in: ["missing"], startTimes: [:]))
    }

    func testChartServicePreservesLLMEnvironment() {
        let environment = ChartServiceManager.serviceEnvironment(
            from: [
                "OPENAI_API_KEY": "secret",
                "OPENAI_BASE_URL": "https://example.invalid/v1",
                "LLM_MODEL": "model-name",
                "PATH": "/usr/bin"
            ],
            port: 8765
        )
        XCTAssertEqual(environment["OPENAI_API_KEY"], "secret")
        XCTAssertEqual(environment["OPENAI_BASE_URL"], "https://example.invalid/v1")
        XCTAssertEqual(environment["LLM_MODEL"], "model-name")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["PORT"], "8765")
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
    }

    func testChartServiceUsesSavedLLMSettingsWhenEnvironmentIsEmpty() {
        let environment = ChartServiceManager.serviceEnvironment(
            from: ["PATH": "/usr/bin"],
            port: 8765,
            llmConfiguration: [
                "OPENAI_API_KEY": "saved-key",
                "OPENAI_BASE_URL": "https://api.deepseek.com/v1",
                "LLM_MODEL": "deepseek-chat"
            ]
        )
        XCTAssertEqual(environment["OPENAI_API_KEY"], "saved-key")
        XCTAssertEqual(environment["OPENAI_BASE_URL"], "https://api.deepseek.com/v1")
        XCTAssertEqual(environment["LLM_MODEL"], "deepseek-chat")
    }

    func testChartAgentMainScriptIsBundled() {
        XCTAssertNotNil(ChartServiceManager.bundledScriptURL)
    }

    func testBackendTimeoutErrorCodeMapsToTimeout() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(
                    url: request.url!,
                    json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#
                )
            }
            return self.response(url: request.url!, json: self.timeoutFailedResponseJSON)
        }

        let request = SmartChartGenerateRequest(
            requestId: "request-timeout",
            recordingId: "recording-1",
            segments: [
                TranscriptSegmentDTO(
                    id: "segment-1",
                    speaker: "发言人",
                    startTime: 0,
                    endTime: 5,
                    text: "这是一个长度足够的测试转录片段，用来验证后端超时错误码映射。"
                )
            ]
        )

        do {
            _ = try await service.generate(request: request)
            XCTFail("Expected timeout")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testURLSessionTimedOutMapsToTimeout() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(
                    url: request.url!,
                    json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#
                )
            }
            throw URLError(.timedOut)
        }

        let request = SmartChartGenerateRequest(
            requestId: "request-url-timeout",
            recordingId: "recording-1",
            segments: [
                TranscriptSegmentDTO(
                    id: "segment-1",
                    speaker: "发言人",
                    startTime: 0,
                    endTime: 5,
                    text: "这是一个长度足够的测试转录片段，用来验证 URLSession 超时映射。"
                )
            ]
        )

        do {
            _ = try await service.generate(request: request)
            XCTFail("Expected timeout")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testChartRequestGateInvalidatesPreviousTokens() {
        let gate = ChartRequestGate()
        let first = gate.begin()
        XCTAssertTrue(gate.isCurrent(first))

        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))

        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertFalse(gate.isCurrent(second))

        let third = gate.begin()
        XCTAssertTrue(gate.isCurrent(third))
    }

    func testMismatchedResponseRequestIDThrowsInvalidResponse() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(
                    url: request.url!,
                    json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#
                )
            }
            return self.response(
                url: request.url!,
                json: self.successResponseJSON(requestId: "different-request")
            )
        }
        let request = makeRequest(
            requestId: "expected-request",
            texts: ["这是一个长度足够的有效转录片段，用来校验响应身份。"]
        )

        do {
            _ = try await service.generate(request: request)
            XCTFail("Expected invalidResponse")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testGenerateFiltersBlankSegmentsBeforeSending() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(
                    url: request.url!,
                    json: #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#
                )
            }
            let body = try XCTUnwrap(self.bodyData(from: request))
            let decoded = try JSONDecoder().decode(SmartChartGenerateRequest.self, from: body)
            XCTAssertEqual(decoded.segments.map(\.text), ["有效转录内容"])
            return self.response(
                url: request.url!,
                json: self.successResponseJSON(requestId: decoded.requestId)
            )
        }

        let request = makeRequest(
            requestId: "request-filter",
            texts: ["   ", "  有效转录内容  "]
        )
        _ = try await service.generate(request: request)
    }

    func testGenerateRejectsAllBlankSegmentsBeforeHealthCheck() async throws {
        let service = makeService { _ in
            XCTFail("全空白请求不应访问服务")
            throw URLError(.badServerResponse)
        }
        let request = makeRequest(
            requestId: "request-empty",
            texts: [" ", "\n"]
        )

        do {
            _ = try await service.generate(request: request)
            XCTFail("Expected contentTooShort")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .contentTooShort)
        }
    }

    func testResponseDecodesContentTypeFields() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return (self.httpOK(request.url!), Data(self.healthV5JSON.utf8))
            }
            return (self.httpOK(request.url!), Data(self.successResponseJSON(requestId: "r1").utf8))
        }
        let result = try await service.generate(request: makeRequest(requestId: "r1"))
        XCTAssertEqual(result.contentType, .meeting)
        XCTAssertEqual(result.contentTypeDisplayName, "会议")
        XCTAssertEqual(result.chartType, "decision_board")
        XCTAssertEqual(result.chartTypeDisplayName, "决策行动看板")
    }

    func testForceContentTypeIsEncodedWhenSet() async throws {
        var capturedBody: Data?
        let service = makeService { request in
            if request.url?.path == "/health" {
                return (self.httpOK(request.url!), Data(self.healthV5JSON.utf8))
            }
            capturedBody = self.bodyData(from: request)
            return (self.httpOK(request.url!), Data(self.successResponseJSON(requestId: "r1").utf8))
        }
        var request = makeRequest(requestId: "r1")
        request.forceContentType = .lecture
        _ = try await service.generate(request: request)
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any]
        XCTAssertEqual(json?["forceContentType"] as? String, "lecture")
        XCTAssertEqual(json?["version"] as? String, "5.0")
    }

    func testForceContentTypeOmittedWhenNil() async throws {
        var capturedBody: Data?
        let service = makeService { request in
            if request.url?.path == "/health" {
                return (self.httpOK(request.url!), Data(self.healthV5JSON.utf8))
            }
            capturedBody = self.bodyData(from: request)
            return (self.httpOK(request.url!), Data(self.successResponseJSON(requestId: "r1").utf8))
        }
        _ = try await service.generate(request: makeRequest(requestId: "r1"))
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any]
        XCTAssertNil(json?["forceContentType"])
    }

    func testRenderPostsToChartRenderEndpoint() async throws {
        var capturedBody: Data?
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(url: request.url!, json: self.healthV5JSON)
            }
            XCTAssertEqual(request.url?.path, "/chart/render")
            capturedBody = self.bodyData(from: request)
            return self.response(url: request.url!, json: """
                {"version":"5.0","requestId":"render-1","status":"success",
                 "htmlFragment":"<svg>mind</svg>","errorCode":null}
                """)
        }
        var request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: makeMindMapDoc())
        request.requestId = "render-1"
        let response = try await service.render(request: request)
        XCTAssertEqual(response.htmlFragment, "<svg>mind</svg>")
        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "5.0")
        XCTAssertNotNil(json["mindMap"])
    }

    func testRenderFailedStatusMapsToValidationFailed() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(url: request.url!, json: self.healthV5JSON)
            }
            return self.response(url: request.url!, json: """
                {"version":"5.0","requestId":"render-1","status":"failed",
                 "htmlFragment":"","errorCode":"INVALID_MINDMAP"}
                """)
        }
        var request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: makeMindMapDoc())
        request.requestId = "render-1"
        do {
            _ = try await service.render(request: request)
            XCTFail("Expected validationFailed")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .validationFailed("INVALID_MINDMAP"))
        }
    }

    func testRenderRejectsMismatchedRequestID() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(url: request.url!, json: self.healthV5JSON)
            }
            return self.response(url: request.url!, json: """
                {"version":"5.0","requestId":"other-id","status":"success",
                 "htmlFragment":"<svg/>","errorCode":null}
                """)
        }
        var request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: makeMindMapDoc())
        request.requestId = "render-1"
        do {
            _ = try await service.render(request: request)
            XCTFail("Expected invalidResponse")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testHealthRequiresV5Protocol() async {
        let v4Service = makeService { request in
            self.response(url: request.url!, json: self.healthV4JSON)
        }
        let v4Healthy = await v4Service.checkHealth()
        XCTAssertFalse(v4Healthy, "v4 后端必须被版本自检驱逐")

        let v5Service = makeService { request in
            self.response(url: request.url!, json: self.healthV5JSON)
        }
        let v5Healthy = await v5Service.checkHealth()
        XCTAssertTrue(v5Healthy)
    }

    @MainActor
    func testCleanupEndsChartLoadingState() {
        let controller = PersistenceController(inMemory: true)
        let recording = Recording(context: controller.container.viewContext)
        recording.id = UUID()
        let viewModel = RecordingDetailViewModel(objectID: recording.objectID)
        viewModel.isGeneratingChart = true

        viewModel.cleanup()

        XCTAssertFalse(viewModel.isGeneratingChart)
    }

    func testLogRotationKeepsBoundedCopies() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("chart-agent.log")
        let rotated1 = directory.appendingPathComponent("chart-agent.1.log")
        let rotated2 = directory.appendingPathComponent("chart-agent.2.log")

        // Below the threshold: no rotation, content untouched.
        try Data("old".utf8).write(to: logURL)
        ChartServiceManager.rotateLogIfNeeded(at: logURL, maxBytes: 100, keep: 3)
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "old")
        XCTAssertFalse(fileManager.fileExists(atPath: rotated1.path))

        // Over the threshold: current log moves to .1.
        try Data(repeating: UInt8(ascii: "a"), count: 200).write(to: logURL)
        ChartServiceManager.rotateLogIfNeeded(at: logURL, maxBytes: 100, keep: 3)
        XCTAssertFalse(fileManager.fileExists(atPath: logURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: rotated1.path))

        // Further rotations shift copies and never exceed keep files.
        try Data(repeating: UInt8(ascii: "b"), count: 200).write(to: logURL)
        ChartServiceManager.rotateLogIfNeeded(at: logURL, maxBytes: 100, keep: 3)
        try Data(repeating: UInt8(ascii: "c"), count: 200).write(to: logURL)
        ChartServiceManager.rotateLogIfNeeded(at: logURL, maxBytes: 100, keep: 3)

        let files = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["chart-agent.1.log", "chart-agent.2.log"])
        let newest = try String(contentsOf: rotated1, encoding: .utf8)
        XCTAssertEqual(newest, String(repeating: "c", count: 200))
        XCTAssertTrue(fileManager.fileExists(atPath: rotated2.path))
    }

    func testOpenAppendingLogHandleAppendsInsteadOfOverwriting() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("chart-agent.log")
        try Data("old".utf8).write(to: logURL)

        let handle = ChartServiceManager.openAppendingLogHandle(at: logURL)
        XCTAssertNotNil(handle)
        handle?.write(Data("new".utf8))
        try? handle?.close()

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("old"))
        XCTAssertTrue(content.contains("new"))

        // Creates the file when it does not exist yet.
        let createdURL = directory.appendingPathComponent("created.log")
        let created = ChartServiceManager.openAppendingLogHandle(at: createdURL)
        XCTAssertNotNil(created)
        try? created?.close()
        XCTAssertTrue(fileManager.fileExists(atPath: createdURL.path))
    }

    private let healthV4JSON = #"{"status":"ok","apiVersion":"4.0","serviceVersion":"4.0.0","llmConfigured":true}"#

    private let healthV5JSON = #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#

    private func makeMindMapDoc() -> MindMapDocDTO {
        MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会纪要"),
            branches: [
                MindMapBranchDTO(id: "b0", text: "议题一", segmentIds: ["s1"], children: [
                    MindMapNodeDTO(id: "b0c0", text: "结论", segmentIds: ["s1"]),
                ]),
            ]
        )
    }

    private func httpOK(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    private func makeService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> HTTPChartSkill {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPChartSkill(
            baseURL: URL(string: "http://127.0.0.1:8765")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func response(url: URL, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private func makeRequest(
        requestId: String,
        texts: [String] = ["这是一个长度足够的有效转录片段，用来生成图表。"]
    ) -> SmartChartGenerateRequest {
        SmartChartGenerateRequest(
            requestId: requestId,
            recordingId: "recording-1",
            segments: texts.enumerated().map { index, text in
                TranscriptSegmentDTO(
                    id: "segment-\(index)",
                    speaker: "发言人",
                    startTime: Double(index * 5),
                    endTime: Double(index * 5 + 5),
                    text: text
                )
            }
        )
    }

    private func successResponseJSON(requestId: String) -> String {
        """
        {
          "version": "5.0",
          "requestId": "\(requestId)",
          "status": "success",
          "contentType": "meeting",
          "contentTypeDisplayName": "会议",
          "chartType": "decision_board",
          "chartTypeDisplayName": "决策行动看板",
          "title": "测试图表",
          "htmlFragment": "<div data-segment-ids=\\"s1\\">ok</div>",
          "plan": {"chartType": "decision_board", "title": "测试图表", "topics": []},
          "errors": []
        }
        """
    }

    /// URLSession may hand the protocol a body stream instead of `httpBody`;
    /// read whichever form the request carries.
    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    private let failedResponseJSON = #"""
    {
      "version":"5.0",
      "requestId":"request-1",
      "status":"failed",
      "contentType":"other",
      "contentTypeDisplayName":"其他",
      "chartType":"highlights",
      "chartTypeDisplayName":"重点句子",
      "title":"生成失败",
      "htmlFragment":"",
      "errors":["LLM 图表路由失败"]
    }
    """#

    private let timeoutFailedResponseJSON = #"""
    {
      "version":"5.0",
      "requestId":"request-timeout",
      "status":"failed",
      "contentType":"other",
      "contentTypeDisplayName":"其他",
      "chartType":"highlights",
      "chartTypeDisplayName":"重点句子",
      "title":"生成失败",
      "htmlFragment":"",
      "errors":["图表生成超时"],
      "errorCode":"TIMEOUT"
    }
    """#
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
