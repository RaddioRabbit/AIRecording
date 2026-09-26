@preconcurrency import CoreData
import Foundation

extension Notification.Name {
    /// 后台同步队列排空(所有已调度的提交与重试结束)时发出,UI 据此自动刷新知识库状态。
    static let knowledgeSyncQueueDrained = Notification.Name("knowledgeSyncQueueDrained")
}

actor KnowledgeSyncCoordinator {
    static let shared = KnowledgeSyncCoordinator()

    private enum Snapshot: Sendable {
        case upsert(KnowledgeRecordingRequest)
        case delete(UUID)
        case none

        var recordingID: UUID? {
            switch self {
            case let .upsert(request): request.recordingId
            case let .delete(id): id
            case .none: nil
            }
        }
    }

    private struct SubmittedRevision: Equatable {
        let contentHash: String
        let summaryHash: String
    }

    private let container: NSPersistentContainer
    private let client: any KnowledgeClientProtocol
    private let ensureServiceRunning: @Sendable () async -> Bool
    private let debounce: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let retryDelays: [TimeInterval] = [5, 30, 120]

    private var observer: NSObjectProtocol?
    private var pendingTokens: [UUID: UUID] = [:]
    private var retryTokens: [UUID: UUID] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var inFlightRecordingIDs: Set<UUID> = []
    private var needsResync: Set<UUID> = []
    private var submittedRevisions: [UUID: SubmittedRevision] = [:]
    private var isStarted = false
    private var acceptsWork = true
    private var lifecycleGeneration = 0

    init(
        container: NSPersistentContainer = PersistenceController.shared.container,
        client: any KnowledgeClientProtocol = KnowledgeClient.shared,
        ensureServiceRunning: @escaping @Sendable () async -> Bool = {
            await KnowledgeServiceManager.shared.ensureServiceRunning()
        },
        debounce: TimeInterval = 0.5,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            guard delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) {
        self.container = container
        self.client = client
        self.ensureServiceRunning = ensureServiceRunning
        self.debounce = debounce
        self.sleeper = sleeper
    }

    func start() async {
        guard !isStarted else { return }
        lifecycleGeneration &+= 1
        acceptsWork = true
        isStarted = true
        observeChanges()
        await scanHistoricalRecordings()
    }

    func stop() {
        lifecycleGeneration &+= 1
        acceptsWork = false
        isStarted = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        pendingTokens.removeAll()
        retryTokens.removeAll()
        inFlightRecordingIDs.removeAll()
        needsResync.removeAll()
    }

    func scanHistoricalRecordings() async {
        let generation = lifecycleGeneration
        for recordingID in await historicalRecordingIDs() {
            await schedule(recordingID: recordingID, generation: generation)
        }
    }

    /// 重建知识库后的全量重扫:作废已提交缓存并重新调度全部录音。
    /// `waitTimeout > 0` 时等待所有已调度任务(含仍在进行的存量同步)结束或超时,
    /// 返回后调用方查询状态拿到的即是重扫终态——重建按钮必须”等结果再报数”,
    /// 否则用户在后台重扫完成前只能看到必然过期的 0/0/0。
    func rescanAfterIndexReset(waitTimeout: TimeInterval = 60) async {
        // 服务端索引已被清空,客户端的已提交缓存随之整体失效;
        // 否则重扫会因”内容未变”跳过所有提交,索引停留在 0 录音/0 片段。
        submittedRevisions.removeAll()
        await scanHistoricalRecordings()
        guard waitTimeout > 0 else { return }
        let deadline = Date().addingTimeInterval(waitTimeout)
        while !operations.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func recordingDidChange(objectID: NSManagedObjectID) async {
        let generation = lifecycleGeneration
        guard let recordingID = await owningRecordingID(for: objectID) else { return }
        await schedule(recordingID: recordingID, generation: generation)
    }

    func retryFailed() async {
        let generation = lifecycleGeneration
        for recordingID in await historicalRecordingIDs() {
            await schedule(recordingID: recordingID, generation: generation)
        }
    }

    func drainForTesting() async {
        while !operations.isEmpty {
            let active = Array(operations.values)
            for operation in active { await operation.value }
            await Task.yield()
        }
    }

    private func observeChanges() {
        let generation = lifecycleGeneration
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: container.viewContext,
            queue: nil
        ) { [weak self] notification in
            let objects = ([notification.userInfo?[NSInsertedObjectsKey], notification.userInfo?[NSUpdatedObjectsKey], notification.userInfo?[NSDeletedObjectsKey]]
                .compactMap { $0 as? Set<NSManagedObject> })
                .flatMap { $0 }
            let recordingIDs = Set(objects.compactMap(Self.owningRecordingID(from:)))
            guard !recordingIDs.isEmpty else { return }
            Task { await self?.recordingsDidChange(recordingIDs, generation: generation) }
        }
    }

    private func recordingsDidChange(_ recordingIDs: Set<UUID>, generation: Int) async {
        guard isCurrent(generation) else { return }
        for recordingID in recordingIDs {
            await schedule(recordingID: recordingID, generation: generation)
        }
    }

    private func schedule(recordingID: UUID, generation: Int) async {
        guard isCurrent(generation) else { return }
        if inFlightRecordingIDs.contains(recordingID) {
            needsResync.insert(recordingID)
            return
        }
        guard pendingTokens[recordingID] == nil else { return }

        let token = UUID()
        let delay = debounce
        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                await self?.finishOperation(token)
                return
            }
            guard await self?.isCurrent(generation) == true else {
                await self?.finishOperation(token)
                return
            }
            await self?.beginSync(recordingID: recordingID, pendingToken: token, generation: generation)
            await self?.finishOperation(token)
        }
        pendingTokens[recordingID] = token
        operations[token] = task
    }

    private func beginSync(recordingID: UUID, pendingToken: UUID, generation: Int) async {
        guard isCurrent(generation), pendingTokens[recordingID] == pendingToken else { return }
        pendingTokens[recordingID] = nil
        guard !inFlightRecordingIDs.contains(recordingID) else {
            needsResync.insert(recordingID)
            return
        }
        inFlightRecordingIDs.insert(recordingID)
        let snapshot = await snapshot(recordingID: recordingID)
        guard isCurrent(generation) else { return }
        await send(snapshot, generation: generation)
        guard isCurrent(generation) else { return }
        inFlightRecordingIDs.remove(recordingID)
        if needsResync.remove(recordingID) != nil {
            await schedule(recordingID: recordingID, generation: generation)
        }
    }

    private func send(_ snapshot: Snapshot, generation: Int) async {
        guard isCurrent(generation), let recordingID = snapshot.recordingID else { return }
        cancelRetry(for: recordingID)
        guard isCurrent(generation) else { return }
        let serviceIsRunning = await ensureServiceRunning()
        guard isCurrent(generation) else { return }
        guard serviceIsRunning else {
            scheduleRetries(for: snapshot, generation: generation)
            return
        }
        do {
            try await submit(snapshot, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            AppLogger.log(.warning, category: "knowledge-sync", event: "recording_sync_failed", recordingId: recordingID.uuidString, errorCode: "TRANSPORT")
            scheduleRetries(for: snapshot, generation: generation)
        }
    }

    private func submit(_ snapshot: Snapshot, generation: Int) async throws {
        guard isCurrent(generation) else { throw CancellationError() }
        switch snapshot {
        case let .upsert(request):
            let revision = SubmittedRevision(contentHash: request.contentHash, summaryHash: request.summaryHash)
            guard submittedRevisions[request.recordingId] != revision else { return }
            guard isCurrent(generation) else { throw CancellationError() }
            _ = try await client.upsert(request)
            guard isCurrent(generation) else { throw CancellationError() }
            submittedRevisions[request.recordingId] = revision
        case let .delete(recordingID):
            guard isCurrent(generation) else { throw CancellationError() }
            try await client.delete(recordingId: recordingID)
            guard isCurrent(generation) else { throw CancellationError() }
            submittedRevisions[recordingID] = nil
        case .none:
            return
        }
    }

    private func scheduleRetries(for snapshot: Snapshot, generation: Int) {
        guard isCurrent(generation), let recordingID = snapshot.recordingID else { return }
        cancelRetry(for: recordingID)
        let token = UUID()
        let delays = retryDelays
        let task = Task { [weak self] in
            guard let self else { return }
            for delay in delays {
                await self.sleeper(delay)
                guard !Task.isCancelled else {
                    await self.finishOperation(token)
                    return
                }
                guard await self.isCurrent(generation) else {
                    await self.finishOperation(token)
                    return
                }
                let serviceIsRunning = await self.ensureServiceRunning()
                guard await self.isCurrent(generation) else {
                    await self.finishOperation(token)
                    return
                }
                guard serviceIsRunning else { continue }
                do {
                    try await self.submit(snapshot, generation: generation)
                    await self.finishOperation(token)
                    return
                } catch is CancellationError {
                    await self.finishOperation(token)
                    return
                } catch {
                    continue
                }
            }
            await self.finishOperation(token)
        }
        retryTokens[recordingID] = token
        operations[token] = task
    }

    private func cancelRetry(for recordingID: UUID) {
        guard let token = retryTokens[recordingID] else { return }
        operations[token]?.cancel()
        retryTokens[recordingID] = nil
    }

    private func finishOperation(_ token: UUID) {
        operations[token] = nil
        pendingTokens = pendingTokens.filter { $0.value != token }
        retryTokens = retryTokens.filter { $0.value != token }
        if operations.isEmpty {
            NotificationCenter.default.post(name: .knowledgeSyncQueueDrained, object: nil)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        acceptsWork && lifecycleGeneration == generation
    }

    private func historicalRecordingIDs() async -> [UUID] {
        await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                let request = Recording.fetchRequest()
                request.predicate = NSPredicate(
                    format: "isDeletedValue == NO AND status == %d",
                    RecordingStatus.completed.rawValue
                )
                request.includesPendingChanges = false
                let ids = (try? context.fetch(request).compactMap(\.id)) ?? []
                continuation.resume(returning: ids)
            }
        }
    }

    private func owningRecordingID(for objectID: NSManagedObjectID) async -> UUID? {
        await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                guard let object = try? context.existingObject(with: objectID) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.owningRecordingID(from: object))
            }
        }
    }

    private func snapshot(recordingID: UUID) async -> Snapshot {
        await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                let request = Recording.fetchRequest()
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "id == %@", recordingID as CVarArg)
                let recording = try? context.fetch(request).first
                continuation.resume(returning: Self.snapshot(from: recording ?? nil))
            }
        }
    }

    private static func owningRecordingID(from object: NSManagedObject) -> UUID? {
        switch object {
        case let recording as Recording: return recording.id
        case let transcription as Transcription: return transcription.recording?.id ?? transcription.recordingId
        case let segment as TranscriptionSegment: return segment.transcription?.recording?.id ?? segment.transcription?.recordingId
        default: return nil
        }
    }

    private static func snapshot(from recording: Recording?) -> Snapshot {
        guard let recording, let recordingID = recording.id else { return .none }
        if recording.isDeletedValue { return .delete(recordingID) }
        guard recording.status == Int16(RecordingStatus.completed.rawValue),
              recording.transcription?.isCompleted == true,
              let request = KnowledgeRecordingRequest.make(recording: recording) else {
            return .none
        }
        return .upsert(request)
    }
}
