import CoreData
import XCTest
@testable import AIRecording

final class KnowledgeSyncCoordinatorTests: XCTestCase {
    func testInitialScanIndexesOnlyCompletedNonDeletedRecordings() async throws {
        let persistence = PersistenceController(inMemory: true)
        let completed = try await makeRecording(in: persistence, completed: true, deleted: false)
        _ = try await makeRecording(in: persistence, completed: false, deleted: false)
        _ = try await makeRecording(in: persistence, completed: true, deleted: true)
        let client = RecordingKnowledgeClient()
        let coordinator = makeCoordinator(persistence: persistence, client: client)

        await coordinator.scanHistoricalRecordings()
        await coordinator.drainForTesting()

        let requests = await client.upserts()
        XCTAssertEqual(requests.map(\.recordingId), [completed])
    }

    func testSummaryChangeUpsertsSameRecordingWithoutDuplicateQueueEntry() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient()
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        let objectID = try await objectID(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.drainForTesting()

        let requests = await client.upserts()
        XCTAssertEqual(requests.map(\.recordingId), [id])
    }

    func testRecordingAndChildChangesCoalesceToOneSerialUpsert() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient(suspendFirstUpsert: true)
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        let ids = try await graphObjectIDs(for: id, in: persistence)

        let first = Task { await coordinator.recordingDidChange(objectID: ids.recording) }
        await client.waitUntilFirstUpsertIsSuspended()
        await coordinator.recordingDidChange(objectID: ids.transcription)
        await coordinator.recordingDidChange(objectID: ids.segment)
        await client.resumeFirstUpsert()
        await first.value
        await coordinator.drainForTesting()

        let requests = await client.upserts()
        XCTAssertEqual(requests.map(\.recordingId), [id])
    }

    @MainActor
    func testDidSaveNotificationCoalescesRecordingTranscriptionAndMultipleSegments() async throws {
        let persistence = PersistenceController(inMemory: true)
        let client = RecordingKnowledgeClient()
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let context = persistence.container.viewContext
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.title = "录音"
        recording.createdAt = Date()
        recording.status = Int16(RecordingStatus.completed.rawValue)
        let transcription = Transcription(context: context)
        transcription.id = UUID()
        transcription.recordingId = recording.id
        transcription.status = Int16(TranscriptionStatus.completed.rawValue)
        transcription.recording = recording
        for sequence in 0..<2 {
            let segment = TranscriptionSegment(context: context)
            segment.id = UUID()
            segment.sequence = Int32(sequence)
            segment.text = "片段 \(sequence)"
            segment.transcription = transcription
        }
        try context.save()
        await Task.yield()
        await coordinator.drainForTesting()

        let requests = await client.upserts()
        let recordingID = try XCTUnwrap(recording.id)
        XCTAssertEqual(requests.map(\.recordingId), [recordingID])
    }

    func testSoftDeleteRemovesRecordingFromIndex() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: true)
        let client = RecordingKnowledgeClient()
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        let objectID = try await objectID(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.drainForTesting()

        let deleted = await client.deleted()
        XCTAssertEqual(deleted, [id])
    }

    func testThreeRetriesUseFiveThirtyAndOneTwentySecondDelays() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient(failUpserts: 4)
        let clock = RecordingKnowledgeClock()
        let coordinator = makeCoordinator(persistence: persistence, client: client, sleeper: { delay in
            await clock.sleep(delay)
        })
        let objectID = try await objectID(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.drainForTesting()

        let delays = await clock.delays()
        let requests = await client.upserts()
        XCTAssertEqual(delays, [5, 30, 120])
        XCTAssertEqual(requests.count, 4)
    }

    func testRetryRestartsServiceBeforeTransportAfterAgentDies() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient(failUpserts: 1)
        let availability = RecordingKnowledgeAvailability(values: [true, false, true])
        let clock = RecordingKnowledgeClock()
        let coordinator = KnowledgeSyncCoordinator(
            container: persistence.container,
            client: client,
            ensureServiceRunning: { await availability.next() },
            debounce: 0,
            sleeper: { delay in await clock.sleep(delay) }
        )
        let objectID = try await objectID(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.drainForTesting()

        let delays = await clock.delays()
        let requests = await client.upserts()
        let calls = await availability.calls()
        XCTAssertEqual(delays, [5, 30])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(calls, 3)
    }

    func testStopInvalidatesSuspendedSyncBeforeServiceOrTransport() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient()
        let availability = RecordingKnowledgeAvailability(values: [true], suspendFirstCheck: true)
        let coordinator = KnowledgeSyncCoordinator(
            container: persistence.container,
            client: client,
            ensureServiceRunning: { await availability.next() },
            debounce: 0
        )
        let objectID = try await objectID(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await availability.waitUntilFirstCheckIsSuspended()
        await coordinator.stop()
        await availability.resumeFirstCheck()
        try? await Task.sleep(nanoseconds: 10_000_000)

        let requests = await client.upserts()
        let deleted = await client.deleted()
        let calls = await availability.calls()
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(deleted, [])
        XCTAssertEqual(calls, 1)
    }

    func testStopCancelsQueuedDebounceBeforeServiceStartupOrTransport() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient()
        let availability = RecordingKnowledgeAvailability(values: [true])
        let coordinator = KnowledgeSyncCoordinator(
            container: persistence.container,
            client: client,
            ensureServiceRunning: { await availability.next() },
            debounce: 0.05
        )
        let objectID = try await objectID(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let requests = await client.upserts()
        let deleted = await client.deleted()
        let calls = await availability.calls()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(requests, [])
        XCTAssertEqual(deleted, [])
    }

    func testSyncFailureNeverChangesTranscriptionStatus() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient(failUpserts: 1)
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        let objectID = try await objectID(for: id, in: persistence)
        let original = try await transcriptionStatus(for: id, in: persistence)

        await coordinator.recordingDidChange(objectID: objectID)
        await coordinator.drainForTesting()

        let final = try await transcriptionStatus(for: id, in: persistence)
        XCTAssertEqual(final, original)
    }

    func testRescanAfterIndexResetResubmitsUnchangedRecordings() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient()
        let coordinator = makeCoordinator(persistence: persistence, client: client)

        await coordinator.scanHistoricalRecordings()
        await coordinator.drainForTesting()

        // 重建知识库清空服务端索引后,内容未变的录音也必须重新提交,
        // 否则索引永远停留在 0 条录音/0 个片段。
        await coordinator.rescanAfterIndexReset(waitTimeout: 0)
        await coordinator.drainForTesting()

        let requests = await client.upserts()
        XCTAssertEqual(requests.map(\.recordingId), [id, id])
    }

    func testRescanAfterIndexResetWaitsUntilOperationsFinish() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient()
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        await coordinator.scanHistoricalRecordings()
        await coordinator.drainForTesting()

        // 带等待的重建:返回时重扫必须已经全部提交完成——
        // 调用方(设置页)拿到返回即可查询状态并直接显示终态。
        await coordinator.rescanAfterIndexReset(waitTimeout: 10)

        let requests = await client.upserts()
        XCTAssertEqual(requests.map(\.recordingId), [id, id])
    }

    func testRescanAfterIndexResetReturnsAtTimeoutInsteadOfHanging() async throws {
        let persistence = PersistenceController(inMemory: true)
        _ = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient(suspendFirstUpsert: true)
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        // 首个提交被挂起(此时不能 drain,否则测试自身会等挂起任务);
        // 等待式重扫必须在超时后返回,绝不永久卡死重建流程。
        await coordinator.scanHistoricalRecordings()
        await coordinator.rescanAfterIndexReset(waitTimeout: 0.2)
        await client.resumeFirstUpsert()
        await coordinator.drainForTesting()
    }

    func testQueueDrainedNotificationFiresWhenAllOperationsFinish() async throws {
        let persistence = PersistenceController(inMemory: true)
        _ = try await makeRecording(in: persistence, completed: true, deleted: false)
        let client = RecordingKnowledgeClient(suspendFirstUpsert: true)
        let coordinator = makeCoordinator(persistence: persistence, client: client)
        let drained = expectation(description: "queue drained notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .knowledgeSyncQueueDrained, object: nil, queue: nil
        ) { _ in drained.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        await coordinator.scanHistoricalRecordings()
        // 提交仍挂起,队列未排空,此时不应发出通知。
        await client.waitUntilFirstUpsertIsSuspended()
        await client.resumeFirstUpsert()
        await fulfillment(of: [drained], timeout: 5)
        await coordinator.drainForTesting()
    }

    private func makeCoordinator(
        persistence: PersistenceController,
        client: any KnowledgeClientProtocol,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
    ) -> KnowledgeSyncCoordinator {
        KnowledgeSyncCoordinator(
            container: persistence.container,
            client: client,
            ensureServiceRunning: { true },
            debounce: 0,
            sleeper: sleeper
        )
    }

    private func makeRecording(in persistence: PersistenceController, completed: Bool, deleted: Bool) async throws -> UUID {
        try await persistence.container.performBackgroundTask { context in
            let recording = Recording(context: context)
            recording.id = UUID()
            recording.title = "录音"
            recording.createdAt = Date(timeIntervalSince1970: 0)
            recording.status = Int16((completed ? RecordingStatus.completed : .recording).rawValue)
            recording.isDeletedValue = deleted
            let transcription = Transcription(context: context)
            transcription.id = UUID()
            transcription.recordingId = recording.id
            transcription.status = Int16((completed ? TranscriptionStatus.completed : .processing).rawValue)
            transcription.recording = recording
            let segment = TranscriptionSegment(context: context)
            segment.id = UUID()
            segment.sequence = 0
            segment.text = "张伟负责上线"
            segment.transcription = transcription
            try context.save()
            return try XCTUnwrap(recording.id)
        }
    }

    private func objectID(for id: UUID, in persistence: PersistenceController) async throws -> NSManagedObjectID {
        try await persistence.container.performBackgroundTask { context in
            let request = Recording.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try XCTUnwrap(context.fetch(request).first).objectID
        }
    }

    private func transcriptionStatus(for id: UUID, in persistence: PersistenceController) async throws -> Int16 {
        try await persistence.container.performBackgroundTask { context in
            let request = Recording.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try XCTUnwrap(context.fetch(request).first?.transcription).status
        }
    }

    private func graphObjectIDs(for id: UUID, in persistence: PersistenceController) async throws -> (recording: NSManagedObjectID, transcription: NSManagedObjectID, segment: NSManagedObjectID) {
        try await persistence.container.performBackgroundTask { context in
            let request = Recording.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let recording = try XCTUnwrap(context.fetch(request).first)
            let transcription = try XCTUnwrap(recording.transcription)
            let segment = try XCTUnwrap((transcription.segments as? Set<TranscriptionSegment>)?.first)
            return (recording.objectID, transcription.objectID, segment.objectID)
        }
    }
}

private actor RecordingKnowledgeClock {
    private var values: [TimeInterval] = []
    func sleep(_ delay: TimeInterval) { values.append(delay) }
    func delays() -> [TimeInterval] { values }
}

private actor RecordingKnowledgeAvailability {
    private var values: [Bool]
    private var count = 0
    private var suspendFirstCheck: Bool
    private var firstCheckSuspended = false
    private var firstCheckContinuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    init(values: [Bool], suspendFirstCheck: Bool = false) {
        self.values = values
        self.suspendFirstCheck = suspendFirstCheck
    }
    func next() async -> Bool {
        count += 1
        let value = values.isEmpty ? true : values.removeFirst()
        if suspendFirstCheck, !firstCheckSuspended {
            firstCheckSuspended = true
            waitingContinuation?.resume()
            await withCheckedContinuation { firstCheckContinuation = $0 }
        }
        return value
    }
    func calls() -> Int { count }
    func waitUntilFirstCheckIsSuspended() async {
        guard !firstCheckSuspended else { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }
    func resumeFirstCheck() {
        firstCheckContinuation?.resume()
        firstCheckContinuation = nil
    }
}

private actor RecordingKnowledgeClient: KnowledgeClientProtocol {
    private var upsertRequests: [KnowledgeRecordingRequest] = []
    private var deletedIDs: [UUID] = []
    private var remainingUpsertFailures: Int
    private var suspendFirstUpsert: Bool
    private var firstUpsertSuspended = false
    private var firstUpsertContinuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    init(failUpserts: Int = 0, suspendFirstUpsert: Bool = false) {
        remainingUpsertFailures = failUpserts
        self.suspendFirstUpsert = suspendFirstUpsert
    }
    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1) }
    func status() async throws -> KnowledgeStatusDTO { .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false) }
    func upsert(_ request: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse {
        upsertRequests.append(request)
        if suspendFirstUpsert, !firstUpsertSuspended {
            firstUpsertSuspended = true
            waitingContinuation?.resume()
            await withCheckedContinuation { firstUpsertContinuation = $0 }
        }
        if remainingUpsertFailures > 0 { remainingUpsertFailures -= 1; throw KnowledgeClientError.network }
        return .init(status: "ok", generationChunks: 1, retrievalChunks: 1, summaryChunks: 0, embeddedChunks: 1)
    }
    func delete(recordingId: UUID) async throws {
        deletedIDs.append(recordingId)
    }
    nonisolated func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func retryFailed() async throws { }
    func resetIndex() async throws { }
    func upserts() -> [KnowledgeRecordingRequest] {
        return upsertRequests
    }
    func deleted() -> [UUID] {
        return deletedIDs
    }
    func waitUntilFirstUpsertIsSuspended() async {
        guard !firstUpsertSuspended else { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }
    func resumeFirstUpsert() {
        firstUpsertContinuation?.resume()
        firstUpsertContinuation = nil
    }
}
