import CoreData
import Foundation

@MainActor
final class KnowledgeChatRepository {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }

    func fetchSessions() throws -> [KnowledgeChatSession] {
        let request = KnowledgeChatSession.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(request)
    }

    func fetchAllSources() throws -> [KnowledgeSourceLink] {
        try context.fetch(KnowledgeSourceLink.fetchRequest())
    }

    func createSession(title: String) throws -> KnowledgeChatSession {
        let now = Date()
        let session = KnowledgeChatSession(context: context)
        session.id = UUID()
        session.title = normalizedTitle(title)
        session.createdAt = now
        session.updatedAt = now
        try context.save()
        return session
    }

    func renameSession(_ session: KnowledgeChatSession, title: String) throws {
        session.title = normalizedTitle(title)
        session.updatedAt = Date()
        try context.save()
    }

    func deleteSession(_ session: KnowledgeChatSession) throws {
        context.delete(session)
        try context.save()
    }

    func appendUser(content: String, session: KnowledgeChatSession) throws -> KnowledgeChatMessage {
        try appendMessage(
            role: .user,
            content: content,
            status: .completed,
            errorCode: nil,
            session: session,
            sources: []
        )
    }

    func appendAssistant(
        content: String,
        status: KnowledgeMessageStatus,
        session: KnowledgeChatSession,
        sources: [KnowledgeSourceDTO],
        errorCode: String? = nil
    ) throws -> KnowledgeChatMessage {
        try appendMessage(
            role: .assistant,
            content: status == .completed ? content : "",
            status: status,
            errorCode: status == .completed ? nil : (errorCode ?? defaultErrorCode(for: status)),
            session: session,
            sources: status == .completed ? sources : []
        )
    }

    private func appendMessage(
        role: KnowledgeMessageRole,
        content: String,
        status: KnowledgeMessageStatus,
        errorCode: String?,
        session: KnowledgeChatSession,
        sources: [KnowledgeSourceDTO]
    ) throws -> KnowledgeChatMessage {
        let message = KnowledgeChatMessage(context: context)
        message.id = UUID()
        message.role = role.rawValue
        message.status = status.rawValue
        message.content = content
        message.errorCode = errorCode
        message.createdAt = Date()
        message.session = session
        session.updatedAt = message.createdAt

        for (index, source) in sources.enumerated() {
            let link = KnowledgeSourceLink(context: context)
            link.id = UUID()
            link.sourceId = source.sourceId
            link.recordingId = source.recordingId
            link.segmentId = source.segmentIds.first
            link.startTime = source.startTime
            link.endTime = source.endTime
            link.sourceOrder = Int32(index)
            link.message = message
        }
        try context.save()
        return message
    }

    private func normalizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "新建对话" : trimmed
    }

    private func defaultErrorCode(for status: KnowledgeMessageStatus) -> String {
        status == .cancelled ? "CANCELLED" : "UNKNOWN"
    }
}
