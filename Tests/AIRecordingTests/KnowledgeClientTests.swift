import Foundation
import XCTest
@testable import AIRecording

final class KnowledgeClientTests: XCTestCase {
    override func tearDown() {
        KnowledgeURLProtocol.handler = nil
        super.tearDown()
    }

    func testHealthAndStatusDecode() async throws {
        let client = makeClient { request in
            let json = request.url?.path == "/health"
                ? #"{"status":"ok","apiVersion":"1.0","serviceVersion":"\#(KnowledgeServiceManager.expectedServiceVersion)","indexVersion":1}"#
                : #"{"documents":2,"chunks":3,"pendingJobs":0,"failedJobs":1,"degraded":true}"#
            return self.response(for: request, status: 200, body: json)
        }
        let health = try await client.health()
        let status = try await client.status()
        XCTAssertEqual(health.serviceVersion, KnowledgeServiceManager.expectedServiceVersion)
        XCTAssertEqual(status.failedJobs, 1)
        XCTAssertTrue(status.degraded)
    }

    func testQueryDecodesSplitUTF8SSEInOrder() async throws {
        let requestID = UUID()
        let body = """
        data: {\"event\":\"retrieval_started\",\"requestId\":\"\(requestID.uuidString)\",\"data\":{}}\n\n
        data: {\"event\":\"answer_delta\",\"requestId\":\"\(requestID.uuidString)\",\"data\":{\"content\":\"张伟负责\"}}\n\n
        data: {\"event\":\"answer_completed\",\"requestId\":\"\(requestID.uuidString)\",\"data\":{\"content\":\"张伟负责。 [S1]\"}}\n\n
        """
        let client = makeClient { request in
            self.response(for: request, status: 200, body: body, splitEvery: 7)
        }
        let request = KnowledgeQueryRequest(requestId: requestID, sessionId: UUID(), query: "谁负责？", history: [])
        var events: [KnowledgeStreamEvent] = []
        for try await event in client.query(request) {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.event), [.retrievalStarted, .answerDelta, .answerCompleted])
        XCTAssertEqual(events[1].stringValue(for: "content"), "张伟负责")
    }

    func testHTTPErrorMapsToStableError() async throws {
        let client = makeClient { request in
            self.response(for: request, status: 503, body: #"{"detail":"ignored"}"#)
        }
        do {
            _ = try await client.health()
            XCTFail("Expected serviceUnavailable")
        } catch let error as KnowledgeClientError {
            XCTAssertEqual(error, .serviceUnavailable)
        }
    }

    func testQueryRejectsMismatchedSSEEventOrRequestID() async throws {
        let requestID = UUID()
        let client = makeClient { request in
            let body = """
            event: sources
            data: {\"event\":\"answer_delta\",\"requestId\":\"\(requestID.uuidString)\",\"data\":{}}

            """
            return self.response(for: request, status: 200, body: body)
        }
        do {
            for try await _ in client.query(.init(requestId: requestID, sessionId: UUID(), query: "问题", history: [])) { }
            XCTFail("Expected decodingFailed")
        } catch let error as KnowledgeClientError {
            XCTAssertEqual(error, .decodingFailed)
        }
    }

    func testQueryRejectsForeignRequestID() async throws {
        let requestID = UUID()
        let client = makeClient { request in
            let body = """
            data: {"event":"answer_completed","requestId":"00000000-0000-0000-0000-000000000000","data":{}}

            """
            return self.response(for: request, status: 200, body: body)
        }
        do {
            for try await _ in client.query(.init(requestId: requestID, sessionId: UUID(), query: "问题", history: [])) { }
            XCTFail("Expected decodingFailed")
        } catch let error as KnowledgeClientError {
            XCTAssertEqual(error, .decodingFailed)
        }
    }

    func testMutatingEndpointsUseExpectedMethodsAndPaths() async throws {
        var requests: [(String, String)] = []
        let client = makeClient { request in
            requests.append((request.httpMethod ?? "", request.url?.path ?? ""))
            return self.response(for: request, status: 200, body: #"{"status":"indexed","generationChunks":1,"retrievalChunks":1,"summaryChunks":0,"embeddedChunks":1}"#)
        }
        let recordingID = UUID()
        _ = try await client.upsert(.init(
            recordingId: recordingID,
            title: "title",
            recordedAt: Date(),
            contentHash: "content",
            summaryHash: "summary",
            indexVersion: 1,
            summaryMarkdown: nil,
            segments: [.init(id: UUID(), sequence: 0, startTime: 0, endTime: 1, speakerId: nil, speakerName: nil, text: "text")]
        ))
        try await client.delete(recordingId: recordingID)
        try await client.retryFailed()
        try await client.resetIndex()
        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, [
            "PUT /knowledge/recordings/\(recordingID.uuidString)",
            "DELETE /knowledge/recordings/\(recordingID.uuidString)",
            "POST /knowledge/retry-failed",
            "POST /knowledge/reset-index",
        ])
    }

    func testCancellingAStreamDoesNotLeaveTheConsumerRunning() async throws {
        let client = makeClient { request in
            Thread.sleep(forTimeInterval: 0.2)
            return self.response(for: request, status: 200, body: "")
        }
        let stream = client.query(.init(requestId: UUID(), sessionId: UUID(), query: "问题", history: []))
        let task = Task {
            do {
                for try await _ in stream { }
                return true
            } catch let error as KnowledgeClientError {
                return error == .cancelled
            } catch {
                return false
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(result)
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, [Data])
    ) -> KnowledgeClient {
        KnowledgeURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KnowledgeURLProtocol.self]
        return KnowledgeClient(baseURL: URL(string: "http://127.0.0.1:8766")!, session: URLSession(configuration: config))
    }

    private func response(for request: URLRequest, status: Int, body: String, splitEvery: Int? = nil) -> (HTTPURLResponse, [Data]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        let data = Data(body.utf8)
        guard let splitEvery else { return (response, [data]) }
        return (response, stride(from: 0, to: data.count, by: splitEvery).map { start in
            Data(data[start..<min(start + splitEvery, data.count)])
        })
    }
}

private final class KnowledgeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, [Data]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, chunks) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
