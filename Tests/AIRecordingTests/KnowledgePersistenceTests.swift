import CoreData
import XCTest
@testable import AIRecording

@MainActor
final class KnowledgePersistenceTests: XCTestCase {
    private var persistence: PersistenceController!
    private var repository: KnowledgeChatRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
        repository = KnowledgeChatRepository(context: persistence.container.viewContext)
    }

    func testDeletingSessionCascadesMessagesAndSources() throws {
        let session = try repository.createSession(title: "项目复盘")
        let message = try repository.appendAssistant(
            content: "张伟负责。[S1]", status: .completed, session: session,
            sources: [makeSource(sourceId: "S1")]
        )

        XCTAssertEqual((message.sources as? Set<KnowledgeSourceLink>)?.count, 1)
        try repository.deleteSession(session)

        XCTAssertEqual(try repository.fetchSessions(), [])
        XCTAssertEqual(try repository.fetchAllSources(), [])
    }

    func testMessageStatusesPersistAndFailureNeverSavesPartialContent() throws {
        let session = try repository.createSession(title: "测试")
        let user = try repository.appendUser(content: "问题", session: session)
        let completed = try repository.appendAssistant(content: "答案", status: .completed, session: session, sources: [])
        let failed = try repository.appendAssistant(content: "不应保存的部分答案", status: .failed, session: session, sources: [], errorCode: "NETWORK")
        let cancelled = try repository.appendAssistant(content: "", status: .cancelled, session: session, sources: [])

        XCTAssertEqual(user.statusEnum, .completed)
        XCTAssertEqual(completed.statusEnum, .completed)
        XCTAssertEqual(failed.statusEnum, .failed)
        XCTAssertEqual(failed.content, "")
        XCTAssertEqual(failed.errorCode, "NETWORK")
        XCTAssertEqual(cancelled.statusEnum, .cancelled)
        XCTAssertEqual(cancelled.content, "")
        XCTAssertEqual(cancelled.errorCode, "CANCELLED")
    }

    func testSourcesKeepCitationOrderAndDoNotPersistQuoteSnapshots() throws {
        let session = try repository.createSession(title: "测试")
        let message = try repository.appendAssistant(
            content: "答案", status: .completed, session: session,
            sources: [makeSource(sourceId: "S2"), makeSource(sourceId: "S1")]
        )
        let sources = ((message.sources as? Set<KnowledgeSourceLink>) ?? [])
            .sorted { $0.sourceOrder < $1.sourceOrder }

        XCTAssertEqual(sources.map(\.sourceId), ["S2", "S1"])
        XCTAssertEqual(sources.map(\.sourceOrder), [0, 1])
        XCTAssertNil(KnowledgeSourceLink.entity().attributesByName["quote"])
        XCTAssertNil(KnowledgeSourceLink.entity().attributesByName["text"])
        XCTAssertNotNil(sources.first?.segmentId)
    }

    func testExistingStoreReopensWithKnowledgeEntityDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacyModel = PersistenceController.managedObjectModel.copy() as! NSManagedObjectModel
        legacyModel.entities = legacyModel.entities.filter {
            !["KnowledgeChatSession", "KnowledgeChatMessage", "KnowledgeSourceLink"].contains($0.name)
        }
        let legacy = NSPersistentContainer(name: "AIRecording", managedObjectModel: legacyModel)
        legacy.persistentStoreDescriptions.first?.url = url
        legacy.loadPersistentStores { _, error in XCTAssertNil(error) }
        let recordingEntity = try XCTUnwrap(legacyModel.entitiesByName["Recording"])
        let recording = NSManagedObject(entity: recordingEntity, insertInto: legacy.viewContext)
        recording.setValue(UUID(), forKey: "id")
        try legacy.viewContext.save()

        let reopened = PersistenceController(storeURL: url)
        _ = KnowledgeChatSession(context: reopened.container.viewContext)
        try reopened.container.viewContext.save()
        let sessions = try reopened.container.viewContext.fetch(KnowledgeChatSession.fetchRequest())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(sessions[0].id)
        XCTAssertEqual(sessions[0].title, "新建对话")
    }

    func testBareKnowledgeObjectsUseDistinctDynamicIdentifiersAndCurrentDates() throws {
        let now = Date()
        let context = persistence.container.viewContext
        let firstSession = KnowledgeChatSession(context: context)
        let secondSession = KnowledgeChatSession(context: context)
        let firstMessage = KnowledgeChatMessage(context: context)
        let secondMessage = KnowledgeChatMessage(context: context)
        let firstSource = KnowledgeSourceLink(context: context)
        let secondSource = KnowledgeSourceLink(context: context)

        try context.save()

        XCTAssertNotEqual(firstSession.id, secondSession.id)
        XCTAssertNotEqual(firstMessage.id, secondMessage.id)
        XCTAssertNotEqual(firstSource.id, secondSource.id)
        XCTAssertGreaterThanOrEqual(firstSession.createdAt ?? .distantPast, now)
        XCTAssertGreaterThanOrEqual(firstSession.updatedAt ?? .distantPast, now)
        XCTAssertGreaterThanOrEqual(firstMessage.createdAt ?? .distantPast, now)
    }

    private func makeSource(sourceId: String) -> KnowledgeSourceDTO {
        KnowledgeSourceDTO(
            sourceId: sourceId,
            recordingId: UUID(),
            segmentIds: [UUID()],
            startTime: 12,
            endTime: 18,
            speakerName: nil
        )
    }
}
