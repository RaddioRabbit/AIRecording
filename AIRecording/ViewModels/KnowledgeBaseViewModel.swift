import Combine
import CoreData
import Foundation

@MainActor
final class KnowledgeBaseViewModel: ObservableObject {
    @Published private(set) var sessions: [KnowledgeChatSession] = []
    @Published var selectedSessionID: NSManagedObjectID? {
        didSet {
            if oldValue != selectedSessionID {
                cancelGeneration(showMessage: false)
            }
            reloadMessages()
        }
    }
    @Published private(set) var messages: [KnowledgeChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var displayedAnswer = ""
    @Published private(set) var pendingSources: [KnowledgeSourceDTO] = []
    @Published private(set) var knowledgeStatus: KnowledgeStatusDTO?
    @Published var errorMessage: String?

    private let repository: KnowledgeChatRepository
    private let client: any KnowledgeClientProtocol
    private var activeRequestID: UUID?
    private var generationTask: Task<Void, Never>?
    private var lastQuestion: String?

    init(
        repository: KnowledgeChatRepository = KnowledgeChatRepository(),
        client: any KnowledgeClientProtocol = KnowledgeClient.shared
    ) {
        self.repository = repository
        self.client = client
    }

    var isIndexDegraded: Bool {
        knowledgeStatus?.degraded == true
    }

    func load() async {
        reloadSessions()
        do {
            knowledgeStatus = try await client.status()
        } catch {
            knowledgeStatus = nil
        }
    }

    func createSession() {
        do {
            let session = try repository.createSession(title: "新建对话")
            reloadSessions()
            selectedSessionID = session.objectID
            errorMessage = nil
        } catch {
            showPersistenceError()
        }
    }

    func renameSelectedSession(to title: String) {
        guard let session = selectedSession else { return }
        do {
            try repository.renameSession(session, title: title)
            reloadSessions()
        } catch {
            showPersistenceError()
        }
    }

    func deleteSelectedSession() {
        guard let session = selectedSession else { return }
        cancelGeneration(showMessage: false)
        do {
            try repository.deleteSession(session)
            reloadSessions()
            selectedSessionID = sessions.first?.objectID
        } catch {
            showPersistenceError()
        }
    }

    func selectSession(_ objectID: NSManagedObjectID?) {
        selectedSessionID = objectID
    }

    func send(_ question: String) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !isGenerating else { return }
        guard let session = selectedSession else {
            errorMessage = "请先新建一个对话。"
            return
        }

        let history = makeHistory(for: session)
        do {
            _ = try repository.appendUser(content: trimmedQuestion, session: session)
            reloadSessions()
            reloadMessages()
        } catch {
            showPersistenceError()
            return
        }

        draft = ""
        lastQuestion = trimmedQuestion
        errorMessage = nil
        displayedAnswer = ""
        pendingSources = []
        isGenerating = true

        let requestID = UUID()
        activeRequestID = requestID
        let request = KnowledgeQueryRequest(
            requestId: requestID,
            sessionId: session.id ?? UUID(),
            query: trimmedQuestion,
            history: history
        )
        let task = Task { @MainActor [weak self, client] in
            guard let self else { return }
            do {
                for try await event in client.query(request) {
                    guard !Task.isCancelled else { return }
                    self.apply(event, requestID: requestID, session: session)
                }
                self.finishStreamIfNeeded(requestID: requestID)
            } catch is CancellationError {
                self.finishCancelledRequest(requestID: requestID)
            } catch {
                self.failRequest(requestID: requestID)
            }
        }
        generationTask = task
        await task.value
    }

    func cancelGeneration() {
        cancelGeneration(showMessage: true)
    }

    private func cancelGeneration(showMessage: Bool) {
        guard activeRequestID != nil else { return }
        activeRequestID = nil
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        displayedAnswer = ""
        pendingSources = []
        errorMessage = showMessage ? "已停止生成。" : nil
    }

    func retryLastQuestion() async {
        guard let lastQuestion else { return }
        await send(lastQuestion)
    }

    private var selectedSession: KnowledgeChatSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.objectID == selectedSessionID }
    }

    private func reloadSessions() {
        do {
            sessions = try repository.fetchSessions()
            if selectedSessionID == nil {
                selectedSessionID = sessions.first?.objectID
            }
        } catch {
            sessions = []
            messages = []
            showPersistenceError()
        }
    }

    private func reloadMessages() {
        guard let session = selectedSession else {
            messages = []
            return
        }
        messages = ((session.messages as? Set<KnowledgeChatMessage>) ?? [])
            .sorted {
                let lhs = $0.createdAt ?? .distantPast
                let rhs = $1.createdAt ?? .distantPast
                if lhs != rhs { return lhs < rhs }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
    }

    private func makeHistory(for session: KnowledgeChatSession) -> [KnowledgeHistoryMessageDTO] {
        let existingMessages = ((session.messages as? Set<KnowledgeChatMessage>) ?? [])
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        return existingMessages.compactMap { message in
            guard message.statusEnum == .completed,
                  let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return nil }
            let role: KnowledgeHistoryMessageDTO.Role = message.roleEnum == .user ? .user : .assistant
            return KnowledgeHistoryMessageDTO(role: role, content: content)
        }.suffix(6).map { $0 }
    }

    private func apply(_ event: KnowledgeStreamEvent, requestID: UUID, session: KnowledgeChatSession) {
        guard activeRequestID == requestID,
              UUID(uuidString: event.requestId) == requestID else { return }
        switch event.event {
        case .retrievalStarted:
            break
        case .sources:
            guard let sources = decodedSources(from: event) else {
                failRequest(requestID: requestID)
                return
            }
            pendingSources = sources
        case .answerDelta:
            guard let content = event.stringValue(for: "content") else {
                failRequest(requestID: requestID)
                return
            }
            displayedAnswer += content
        case .answerCompleted:
            guard let content = event.stringValue(for: "content"),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sources = decodedSources(from: event),
                  !sources.isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines) == Self.insufficientEvidenceAnswer else {
                failRequest(requestID: requestID)
                return
            }
            do {
                _ = try repository.appendAssistant(
                    content: content,
                    status: .completed,
                    session: session,
                    sources: sources
                )
                reloadSessions()
                reloadMessages()
                completeRequest(requestID: requestID)
            } catch {
                failRequest(requestID: requestID)
            }
        case .error:
            failRequest(requestID: requestID)
        }
    }

    private func finishStreamIfNeeded(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        failRequest(requestID: requestID)
    }

    private func finishCancelledRequest(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        isGenerating = false
        displayedAnswer = ""
        pendingSources = []
        errorMessage = "已停止生成。"
    }

    private func completeRequest(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        generationTask = nil
        isGenerating = false
        displayedAnswer = ""
        pendingSources = []
        errorMessage = nil
    }

    private func failRequest(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        displayedAnswer = ""
        pendingSources = []
        errorMessage = "知识库回答失败，请重试。"
    }

    private func decodedSources(from event: KnowledgeStreamEvent) -> [KnowledgeSourceDTO]? {
        guard case let .array(values)? = event.data["sources"] else { return nil }
        do {
            let data = try JSONEncoder().encode(values)
            return try JSONDecoder().decode([KnowledgeSourceDTO].self, from: data)
        } catch {
            return nil
        }
    }

    private func showPersistenceError() {
        errorMessage = "本地对话保存失败，请稍后重试。"
    }

    private static let insufficientEvidenceAnswer = "知识库中没有足够依据。"

}
