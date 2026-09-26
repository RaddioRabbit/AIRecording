import CoreData
import XCTest
@testable import AIRecording

@MainActor
final class KnowledgeBaseViewModelTests: XCTestCase {
    private var persistence: PersistenceController!
    private var repository: KnowledgeChatRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
        repository = KnowledgeChatRepository(context: persistence.container.viewContext)
    }

    func testCompletedStreamPersistsOneAssistantMessageAndOrderedSources() async throws {
        let client = ViewModelKnowledgeClient(events: [
            .sources([source("S1"), source("S2")]),
            .answerDelta("张伟负责上线。[S1]"),
            .answerCompleted(content: "张伟负责上线。[S1]", sources: [source("S1"), source("S2")])
        ])
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()

        await viewModel.send("谁负责上线？")

        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 1)
        let assistant = try XCTUnwrap(viewModel.messages.last)
        let sources = ((assistant.sources as? Set<KnowledgeSourceLink>) ?? []).sorted { $0.sourceOrder < $1.sourceOrder }
        XCTAssertEqual(sources.map(\.sourceId), ["S1", "S2"])
        XCTAssertEqual(sources.first?.sourceOrder, 0)
        XCTAssertEqual(viewModel.displayedAnswer, "")
    }

    func testSwitchingSessionsCancelsOldRequestBeforeItsLateEventsArrive() async throws {
        let client = DelayedKnowledgeClient()
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()
        let firstRequest = Task { await viewModel.send("旧问题") }
        try await Task.sleep(for: .milliseconds(20))
        viewModel.createSession()

        await viewModel.send("新问题")
        try await Task.sleep(for: .milliseconds(120))
        await firstRequest.value

        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "新答案。[S1]")
    }

    func testAnswerCompletedWithoutSourcesDoesNotPersistAssistant() async throws {
        let client = ViewModelKnowledgeClient(events: [.answerCompletedMissingSources("无来源答案")])
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()

        await viewModel.send("问题")

        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testAnswerCompletedWithMalformedSourcesDoesNotPersistAssistant() async throws {
        let client = ViewModelKnowledgeClient(events: [.answerCompletedMalformedSources("错误来源答案")])
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()

        await viewModel.send("问题")

        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testRefusalMayPersistWithAnExplicitEmptySourceList() async throws {
        let client = ViewModelKnowledgeClient(events: [.answerCompleted(content: "知识库中没有足够依据。", sources: [])])
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()

        await viewModel.send("问题")

        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 1)
    }

    func testFailurePersistsNoPartialAssistantContentAndCanRetry() async throws {
        let client = ViewModelKnowledgeClient(events: [.answerDelta("不应保存")], error: .network)
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()

        await viewModel.send("谁负责？")

        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 0)
        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .user }.count, 1)
        XCTAssertEqual(viewModel.displayedAnswer, "")
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.retryLastQuestion()
        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .user }.count, 2)
    }

    func testErrorEventCancelsTheStillOpenStream() async throws {
        let client = ErrorThenOpenKnowledgeClient()
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()

        await viewModel.send("问题")
        try await Task.sleep(for: .milliseconds(30))
        let wasTerminated = await client.wasTerminated

        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertTrue(wasTerminated)
        XCTAssertEqual(viewModel.messages.filter { $0.roleEnum == .assistant }.count, 0)
    }

    func testSessionCRUDAndHistoryAreCappedAtSixMessages() async throws {
        let client = HistoryCapturingKnowledgeClient()
        let viewModel = makeViewModel(client: client)
        viewModel.createSession()
        let first = try XCTUnwrap(viewModel.selectedSessionID)
        viewModel.renameSelectedSession(to: "项目复盘")
        XCTAssertEqual(viewModel.sessions.first?.title, "项目复盘")

        let session = try XCTUnwrap(viewModel.sessions.first)
        for index in 0..<8 {
            _ = try repository.appendUser(content: "问题 \(index)", session: session)
        }
        viewModel.selectSession(first)
        await viewModel.send("最后一个问题")
        let history = client.lastHistory
        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(history.first?.content, "问题 2")

        viewModel.deleteSelectedSession()
        XCTAssertTrue(viewModel.sessions.isEmpty)
    }

    func testEmptyQuestionDoesNotPersistMessageAndDegradedStatusShowsBanner() async throws {
        let client = ViewModelKnowledgeClient(
            events: [],
            status: .init(documents: 2, chunks: 3, pendingJobs: 1, failedJobs: 1, degraded: true)
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.load()
        viewModel.createSession()

        await viewModel.send("  \n ")

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.isIndexDegraded)
    }

    private func makeViewModel(client: some KnowledgeClientProtocol) -> KnowledgeBaseViewModel {
        KnowledgeBaseViewModel(repository: repository, client: client)
    }

    private func source(_ sourceID: String) -> KnowledgeSourceDTO {
        .init(sourceId: sourceID, recordingId: UUID(), segmentIds: [UUID()], startTime: 12, endTime: 18, speakerName: nil)
    }
}

private final class HistoryCapturingKnowledgeClient: KnowledgeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedHistory: [KnowledgeHistoryMessageDTO] = []

    var lastHistory: [KnowledgeHistoryMessageDTO] {
        lock.lock()
        defer { lock.unlock() }
        return storedHistory
    }

    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1) }
    func status() async throws -> KnowledgeStatusDTO { .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false) }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { .init(status: "indexed", generationChunks: 0, retrievalChunks: 0, summaryChunks: 0, embeddedChunks: 0) }
    func delete(recordingId _: UUID) async throws { }
    func retryFailed() async throws { }
    func resetIndex() async throws { }

    func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        lock.lock()
        storedHistory = request.history
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(event: .answerCompleted, requestId: request.requestId.uuidString, data: ["content": .string("完成")]))
            continuation.finish()
        }
    }
}

private actor ErrorThenOpenKnowledgeClient: KnowledgeClientProtocol {
    private var terminated = false

    var wasTerminated: Bool { terminated }

    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1) }
    func status() async throws -> KnowledgeStatusDTO { .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false) }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { .init(status: "indexed", generationChunks: 0, retrievalChunks: 0, summaryChunks: 0, embeddedChunks: 0) }
    func delete(recordingId _: UUID) async throws { }
    func retryFailed() async throws { }
    func resetIndex() async throws { }

    nonisolated func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                Task { await self.markTerminated() }
            }
            Task {
                continuation.yield(.init(event: .error, requestId: request.requestId.uuidString, data: ["code": .string("QUERY_FAILED")]))
                try? await Task.sleep(for: .seconds(5))
                continuation.yield(.init(event: .answerCompleted, requestId: request.requestId.uuidString, data: ["content": .string("不应到达"), "sources": .array([])]))
            }
        }
    }

    private func markTerminated() {
        terminated = true
    }
}

private actor DelayedKnowledgeClient: KnowledgeClientProtocol {
    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1) }
    func status() async throws -> KnowledgeStatusDTO { .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false) }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { .init(status: "indexed", generationChunks: 0, retrievalChunks: 0, summaryChunks: 0, embeddedChunks: 0) }
    func delete(recordingId _: UUID) async throws { }
    func retryFailed() async throws { }
    func resetIndex() async throws { }

    nonisolated func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if request.query == "旧问题" {
                    try? await Task.sleep(for: .milliseconds(100))
                    continuation.yield(.init(event: .answerDelta, requestId: request.requestId.uuidString, data: ["content": .string("旧答案")]))
                    continuation.finish()
                    return
                }
                let source = KnowledgeJSONValue.object([
                    "sourceId": .string("S1"),
                    "recordingId": .string(UUID().uuidString),
                    "segmentIds": .array([]),
                    "startTime": .number(0),
                    "endTime": .number(1),
                    "speakerName": .null,
                ])
                continuation.yield(.init(event: .sources, requestId: request.requestId.uuidString, data: ["sources": .array([source])]))
                continuation.yield(.init(event: .answerCompleted, requestId: request.requestId.uuidString, data: ["content": .string("新答案。[S1]"), "sources": .array([source])]))
                continuation.finish()
            }
        }
    }
}

private actor ViewModelKnowledgeClient: KnowledgeClientProtocol {
    enum FixtureEvent {
        case sources([KnowledgeSourceDTO])
        case answerDelta(String)
        case answerCompleted(content: String, sources: [KnowledgeSourceDTO])
        case answerCompletedMissingSources(String)
        case answerCompletedMalformedSources(String)
    }

    private let events: [FixtureEvent]
    private let streamError: KnowledgeClientError?
    private let statusValue: KnowledgeStatusDTO

    init(
        events: [FixtureEvent],
        error: KnowledgeClientError? = nil,
        status: KnowledgeStatusDTO = .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false)
    ) {
        self.events = events
        streamError = error
        statusValue = status
    }

    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1) }
    func status() async throws -> KnowledgeStatusDTO { statusValue }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { .init(status: "indexed", generationChunks: 0, retrievalChunks: 0, summaryChunks: 0, embeddedChunks: 0) }
    func delete(recordingId _: UUID) async throws { }
    func retryFailed() async throws { }
    func resetIndex() async throws { }

    nonisolated func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for fixture in events {
                    let event: KnowledgeStreamEvent
                    switch fixture {
                    case let .sources(sources):
                        event = .init(event: .sources, requestId: request.requestId.uuidString, data: ["sources": .array(sources.map(encode))])
                    case let .answerDelta(content):
                        event = .init(event: .answerDelta, requestId: request.requestId.uuidString, data: ["content": .string(content)])
                    case let .answerCompleted(content, sources):
                        event = .init(event: .answerCompleted, requestId: request.requestId.uuidString, data: ["content": .string(content), "sources": .array(sources.map(encode))])
                    case let .answerCompletedMissingSources(content):
                        event = .init(event: .answerCompleted, requestId: request.requestId.uuidString, data: ["content": .string(content)])
                    case let .answerCompletedMalformedSources(content):
                        event = .init(event: .answerCompleted, requestId: request.requestId.uuidString, data: ["content": .string(content), "sources": .array([.string("not-a-source")])])
                    }
                    continuation.yield(event)
                }
                if let streamError {
                    continuation.finish(throwing: streamError)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    nonisolated private func encode(_ source: KnowledgeSourceDTO) -> KnowledgeJSONValue {
        .object([
            "sourceId": .string(source.sourceId),
            "recordingId": .string(source.recordingId.uuidString),
            "segmentIds": .array(source.segmentIds.map { .string($0.uuidString) }),
            "startTime": .number(source.startTime),
            "endTime": .number(source.endTime),
            "speakerName": source.speakerName.map(KnowledgeJSONValue.string) ?? .null,
        ])
    }
}
