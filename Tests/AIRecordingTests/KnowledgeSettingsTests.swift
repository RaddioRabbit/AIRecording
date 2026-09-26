import Foundation
import Security
import XCTest
@testable import AIRecording

@MainActor
final class KnowledgeSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var credentialStore: TestKnowledgeCredentialStore!
    private var client: SettingsKnowledgeClient!
    private var retryCounter: SettingsRetryCounter!
    private var rescanCounter: SettingsRescanCounter!
    private var restartCounter: SettingsRestartCounter!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "KnowledgeSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        credentialStore = TestKnowledgeCredentialStore()
        client = SettingsKnowledgeClient()
        retryCounter = SettingsRetryCounter()
        rescanCounter = SettingsRescanCounter()
        restartCounter = SettingsRestartCounter()
    }

    override func tearDown() {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        credentialStore = nil
        client = nil
        retryCounter = nil
        rescanCounter = nil
        restartCounter = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavedKeyResolvesByProviderLikeSaveFlow() {
        credentialStore.seedLegacyDashScopeKey("dashscope-key-123456")
        let viewModel = makeViewModel()

        // dashscope:旧账户回退可见,与保存时的解析规则一致。
        XCTAssertEqual(viewModel.savedEmbeddingKey(provider: "dashscope"), "dashscope-key-123456")
        // openai:只认专属账户,不回退旧 Key(安全规则)。
        XCTAssertEqual(viewModel.savedEmbeddingKey(provider: "openai"), "")

        try? credentialStore.saveRerankAPIKey("rerank-secret-99ab")
        // 专属账户里的 Key 两种供应商都能读到(保存与读取都按账户,不按供应商隔离)。
        XCTAssertEqual(viewModel.savedRerankKey(provider: "dashscope"), "rerank-secret-99ab")
        XCTAssertEqual(viewModel.savedRerankKey(provider: "openai"), "rerank-secret-99ab")
    }

    func testSaveKnowledgeServiceSettingsStoresNonEmptyKeyAndKeepsBlankKeys() async {
        let viewModel = makeViewModel()
        try? credentialStore.saveRerankAPIKey("existing-rerank")
        let rerankSaveBaseline = credentialStore.saveRerankCallCount

        await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "openai",
            embeddingModel: "text-embedding-v4",
            embeddingDimension: nil,
            embeddingBaseURL: "https://api.siliconflow.cn/v1",
            embeddingAPIKey: "  embed-secret  ",
            rerankProvider: "dashscope",
            rerankModel: "gte-rerank-v2",
            rerankBaseURL: "",
            rerankAPIKey: "   "
        )

        XCTAssertEqual(credentialStore.embeddingAPIKey(), "embed-secret")
        XCTAssertEqual(credentialStore.rerankAPIKey(), "existing-rerank")
        XCTAssertEqual(credentialStore.saveEmbeddingCallCount, 1)
        XCTAssertEqual(credentialStore.saveRerankCallCount, rerankSaveBaseline)
        XCTAssertEqual(viewModel.knowledgeEmbeddingKeyMasked, "••••••••")
        XCTAssertEqual(viewModel.knowledgeRerankKeyMasked, "••••••••")
        XCTAssertNil(defaults.string(forKey: "knowledge.dashscope.apiKey"))
        let restartCount = await restartCounter.value
        XCTAssertEqual(restartCount, 1)
    }

    func testSaveKnowledgeServiceSettingsPersistsProvidersAndBaseURLsAndRestartsOnce() async {
        let viewModel = makeViewModel()

        let success = await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "azure",
            embeddingModel: "custom-embed",
            embeddingDimension: nil,
            embeddingBaseURL: "",
            embeddingAPIKey: nil,
            rerankProvider: "openai",
            rerankModel: "custom-rerank",
            rerankBaseURL: "https://rerank.example.com/v1",
            rerankAPIKey: nil
        )

        XCTAssertTrue(success)
        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingProvider"), "dashscope")
        XCTAssertEqual(defaults.string(forKey: "knowledge.rerankProvider"), "openai")
        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingBaseURL"), "")
        XCTAssertEqual(defaults.string(forKey: "knowledge.rerankBaseURL"), "https://rerank.example.com/v1")
        XCTAssertEqual(viewModel.knowledgeEmbeddingProvider, "dashscope")
        XCTAssertEqual(viewModel.knowledgeRerankProvider, "openai")
        XCTAssertEqual(credentialStore.saveEmbeddingCallCount, 0)
        XCTAssertEqual(credentialStore.saveRerankCallCount, 0)
        let restartCount = await restartCounter.value
        XCTAssertEqual(restartCount, 1)
    }

    func testSaveKnowledgeServiceSettingsFailsAtomicallyWhenKeychainWriteFails() async {
        defaults.set("keep-model", forKey: "knowledge.embeddingModel")
        credentialStore.embeddingSaveFailure = true
        let viewModel = makeViewModel()

        let success = await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "openai",
            embeddingModel: "new-model",
            embeddingDimension: 512,
            embeddingBaseURL: "https://example.com/v1",
            embeddingAPIKey: "secret",
            rerankProvider: "dashscope",
            rerankModel: "gte-rerank-v2",
            rerankBaseURL: "",
            rerankAPIKey: nil
        )

        XCTAssertFalse(success)
        XCTAssertNil(defaults.string(forKey: "knowledge.embeddingProvider"))
        XCTAssertNil(defaults.string(forKey: "knowledge.rerankProvider"))
        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingModel"), "keep-model")
        XCTAssertNil(defaults.object(forKey: "knowledge.embeddingDimension"))
        XCTAssertNil(defaults.string(forKey: "knowledge.embeddingBaseURL"))
        XCTAssertNil(defaults.string(forKey: "knowledge.rerankModel"))
        XCTAssertNil(defaults.string(forKey: "knowledge.rerankBaseURL"))
        XCTAssertEqual(credentialStore.embeddingAPIKey(), "")
        XCTAssertEqual(viewModel.knowledgeEmbeddingProvider, "dashscope")
        XCTAssertEqual(viewModel.knowledgeEmbeddingModel, KnowledgeModelCatalog.defaultEmbeddingModel)
        XCTAssertEqual(viewModel.knowledgeEmbeddingBaseURL, "")
        XCTAssertEqual(viewModel.knowledgeEmbeddingKeyMasked, "未配置")
        let restartCount = await restartCounter.value
        XCTAssertEqual(restartCount, 0)
    }

    func testSaveOpenAIProviderSettingsRoundTripForSheetSeeding() async {
        let viewModel = makeViewModel()

        let success = await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "openai",
            embeddingModel: "text-embedding-v4",
            embeddingDimension: 1536,
            embeddingBaseURL: "https://api.siliconflow.cn/v1",
            embeddingAPIKey: nil,
            rerankProvider: "openai",
            rerankModel: "gte-rerank-v2",
            rerankBaseURL: "",
            rerankAPIKey: nil
        )
        XCTAssertTrue(success)

        let reloaded = makeViewModel()
        reloaded.loadSettings()
        XCTAssertEqual(reloaded.knowledgeEmbeddingProvider, "openai")
        XCTAssertEqual(reloaded.knowledgeEmbeddingModel, "text-embedding-v4")
        XCTAssertEqual(reloaded.knowledgeEmbeddingDimension, 1536)
        XCTAssertEqual(reloaded.knowledgeEmbeddingBaseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(reloaded.knowledgeRerankProvider, "openai")
        XCTAssertEqual(reloaded.knowledgeRerankModel, "gte-rerank-v2")
    }

    func testLoadSettingsKeyMaskFollowsProviderRule() {
        credentialStore.seedLegacyDashScopeKey("legacy-key")
        defaults.set("openai", forKey: "knowledge.embeddingProvider")
        defaults.set("dashscope", forKey: "knowledge.rerankProvider")
        let viewModel = makeViewModel()

        viewModel.loadSettings()

        XCTAssertEqual(viewModel.knowledgeEmbeddingKeyMasked, "未配置")
        XCTAssertEqual(viewModel.knowledgeRerankKeyMasked, "••••••••")
    }

    func testCredentialStoreWritesRouteToNewAccountsAndReadsFallBackToLegacy() throws {
        let box = InMemoryCredentialBox()
        let store = KnowledgeCredentialStore(
            read: { box.values[$0] },
            write: { account, value in
                if let value {
                    box.values[account] = value
                } else {
                    box.values.removeValue(forKey: account)
                }
            }
        )

        try store.saveEmbeddingAPIKey("  embed-1  ")
        try store.saveRerankAPIKey("rerank-1")
        XCTAssertEqual(box.values["embedding-api-key"], "embed-1")
        XCTAssertEqual(box.values["rerank-api-key"], "rerank-1")
        XCTAssertNil(box.values["dashscope-api-key"])
        XCTAssertEqual(store.strictEmbeddingAPIKey(), "embed-1")
        XCTAssertEqual(store.embeddingAPIKey(), "embed-1")

        try store.saveEmbeddingAPIKey(" ")
        XCTAssertNil(box.values["embedding-api-key"])
        XCTAssertEqual(store.strictEmbeddingAPIKey(), "")
        XCTAssertEqual(store.embeddingAPIKey(), "")
        box.values["dashscope-api-key"] = "legacy"
        XCTAssertEqual(store.embeddingAPIKey(), "legacy")
        XCTAssertEqual(store.rerankAPIKey(), "rerank-1")
        XCTAssertEqual(store.strictEmbeddingAPIKey(), "")

        try store.saveRerankAPIKey("")
        XCTAssertNil(box.values["rerank-api-key"])
        XCTAssertEqual(store.rerankAPIKey(), "legacy")

        // 新账户与旧账户均为空 → ""
        box.values.removeValue(forKey: "dashscope-api-key")
        XCTAssertEqual(store.rerankAPIKey(), "")
        XCTAssertEqual(store.embeddingAPIKey(), "")
        XCTAssertEqual(store.dashScopeAPIKey(), "")
    }

    func testRetryResubmitsSourcesRetriesAgentAndRefreshesStatus() async {
        let viewModel = makeViewModel()

        await viewModel.retryFailedKnowledgeSync()

        let retriedSyncCount = await retryCounter.value
        let retryCount = await client.retryCount
        XCTAssertEqual(retriedSyncCount, 1)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(viewModel.knowledgeDocumentCount, 2)
        XCTAssertEqual(viewModel.knowledgeChunkCount, 3)
        XCTAssertEqual(viewModel.knowledgeFailedCount, 1)
    }

    func testRetryFailureShowsStableErrorInsteadOfSilentSuccess() async {
        await client.setRetryFailure(true)
        let viewModel = makeViewModel()

        await viewModel.retryFailedKnowledgeSync()

        let retryCount = await retryCounter.value
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(viewModel.knowledgeStatusError, "重试失败，请稍后重试。")
    }

    func testStatusPublishesDegradedState() async {
        let viewModel = makeViewModel()

        await viewModel.loadKnowledgeStatus()
        XCTAssertFalse(viewModel.isKnowledgeIndexDegraded)

        await client.setDegraded(true)
        await viewModel.loadKnowledgeStatus()
        XCTAssertTrue(viewModel.isKnowledgeIndexDegraded)
    }

    func testResetIndexCallsClientOnceAndRefreshesStatus() async {
        let viewModel = makeViewModel()

        await viewModel.resetKnowledgeIndex()

        let resetCount = await client.resetCount
        XCTAssertEqual(resetCount, 1)
        let rescanCount = await rescanCounter.value
        XCTAssertEqual(rescanCount, 1)
        XCTAssertEqual(viewModel.knowledgeDocumentCount, 0)
        XCTAssertEqual(viewModel.knowledgeChunkCount, 0)
    }

    func testStatusAutoRefreshesWhenSyncQueueDrainsAfterReset() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadKnowledgeStatus()
        XCTAssertEqual(viewModel.knowledgeDocumentCount, 2)

        // 重建瞬间服务端已清空 → 界面立即显示 0/0/0(后台重扫仍在进行)。
        await viewModel.resetKnowledgeIndex()
        XCTAssertEqual(viewModel.knowledgeDocumentCount, 0)

        // 后台重扫完成后数据回到服务端,协调器发出队列排空通知,
        // 设置页必须自动刷新——用户不需要再点任何按钮。
        await client.markRescanCompleted()
        NotificationCenter.default.post(name: .knowledgeSyncQueueDrained, object: nil)

        for _ in 0..<200 where viewModel.knowledgeDocumentCount != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewModel.knowledgeDocumentCount, 2)
        XCTAssertEqual(viewModel.knowledgeChunkCount, 3)
    }

    func testResetSuccessTriggersExactlyOneFullRescan() async {
        let viewModel = makeViewModel()

        await viewModel.resetKnowledgeIndex()

        let rescanCount = await rescanCounter.value
        XCTAssertEqual(rescanCount, 1)
        let retryCount = await retryCounter.value
        XCTAssertEqual(retryCount, 0)
    }

    func testResetFailureDoesNotTriggerRescan() async {
        await client.setResetFailure(true)
        let viewModel = makeViewModel()

        await viewModel.resetKnowledgeIndex()

        let resetCount = await client.resetCount
        XCTAssertEqual(resetCount, 1)
        let rescanCount = await rescanCounter.value
        XCTAssertEqual(rescanCount, 0)
        XCTAssertEqual(viewModel.knowledgeStatusError, "重建知识库失败，请重试。")
    }

    func testOlderDelayedStatusCannotOverwritePostResetStatus() async {
        let delayedClient = DelayedStatusKnowledgeClient()
        let viewModel = SettingsViewModel(
            defaults: defaults,
            credentialStore: credentialStore,
            knowledgeClient: delayedClient,
            retryKnowledgeSync: {},
            rescanKnowledge: {}
        )
        let staleLoad = Task { await viewModel.loadKnowledgeStatus() }
        await delayedClient.waitForFirstStatusRequest()

        await viewModel.resetKnowledgeIndex()
        await delayedClient.releaseFirstStatus()
        await staleLoad.value

        XCTAssertEqual(viewModel.knowledgeDocumentCount, 0)
        XCTAssertEqual(viewModel.knowledgeChunkCount, 0)
    }

    func testSaveKnowledgeModelSettingsPersistsValuesAndRestartsService() async {
        let viewModel = makeViewModel()

        await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "dashscope",
            embeddingModel: "text-embedding-v4",
            embeddingDimension: 1536,
            embeddingBaseURL: "",
            embeddingAPIKey: nil,
            rerankProvider: "dashscope",
            rerankModel: "gte-rerank-v2",
            rerankBaseURL: "",
            rerankAPIKey: nil
        )

        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingModel"), "text-embedding-v4")
        XCTAssertEqual(defaults.integer(forKey: "knowledge.embeddingDimension"), 1536)
        XCTAssertEqual(defaults.string(forKey: "knowledge.rerankModel"), "gte-rerank-v2")
        XCTAssertEqual(viewModel.knowledgeEmbeddingModel, "text-embedding-v4")
        XCTAssertEqual(viewModel.knowledgeEmbeddingDimension, 1536)
        XCTAssertEqual(viewModel.knowledgeRerankModel, "gte-rerank-v2")
        let restartCount = await restartCounter.value
        XCTAssertEqual(restartCount, 1)
    }

    func testSaveCustomModelClearsStoredDimension() async {
        let viewModel = makeViewModel()

        await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "dashscope",
            embeddingModel: "custom-embedding",
            embeddingDimension: nil,
            embeddingBaseURL: "",
            embeddingAPIKey: nil,
            rerankProvider: "dashscope",
            rerankModel: "custom-reranker",
            rerankBaseURL: "",
            rerankAPIKey: nil
        )

        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingModel"), "custom-embedding")
        XCTAssertNil(defaults.object(forKey: "knowledge.embeddingDimension"))
        XCTAssertEqual(viewModel.knowledgeEmbeddingDimension, 0)
        let restartCount = await restartCounter.value
        XCTAssertEqual(restartCount, 1)
    }

    func testLoadSettingsSeedsKnowledgeModelDefaultsWhenUnset() {
        let viewModel = makeViewModel()

        viewModel.loadSettings()

        XCTAssertEqual(viewModel.knowledgeEmbeddingModel, KnowledgeModelCatalog.defaultEmbeddingModel)
        XCTAssertEqual(viewModel.knowledgeEmbeddingDimension, 0)
        XCTAssertEqual(viewModel.knowledgeRerankModel, KnowledgeModelCatalog.defaultRerankModel)
        XCTAssertEqual(viewModel.knowledgeEmbeddingProvider, "dashscope")
        XCTAssertEqual(viewModel.knowledgeRerankProvider, "dashscope")
        XCTAssertEqual(viewModel.knowledgeEmbeddingBaseURL, "")
        XCTAssertEqual(viewModel.knowledgeRerankBaseURL, "")
        XCTAssertEqual(viewModel.knowledgeEmbeddingKeyMasked, "未配置")
        XCTAssertEqual(viewModel.knowledgeRerankKeyMasked, "未配置")
    }

    func testLoadSettingsFallsBackToDashScopeForInvalidProvider() {
        defaults.set("openai", forKey: "knowledge.embeddingProvider")
        defaults.set("azure", forKey: "knowledge.rerankProvider")
        defaults.set("https://api.siliconflow.cn/v1", forKey: "knowledge.embeddingBaseURL")
        try? credentialStore.saveEmbeddingAPIKey("stored-embed")
        let viewModel = makeViewModel()

        viewModel.loadSettings()

        XCTAssertEqual(viewModel.knowledgeEmbeddingProvider, "openai")
        XCTAssertEqual(viewModel.knowledgeRerankProvider, "dashscope")
        XCTAssertEqual(viewModel.knowledgeEmbeddingBaseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(viewModel.knowledgeEmbeddingKeyMasked, "••••••••")
        XCTAssertEqual(viewModel.knowledgeRerankKeyMasked, "未配置")
    }

    func testRestartSeesPersistedModelSettings() async {
        let viewModel = makeViewModel()

        await viewModel.saveKnowledgeServiceSettings(
            embeddingProvider: "dashscope",
            embeddingModel: "text-embedding-v3",
            embeddingDimension: 768,
            embeddingBaseURL: "",
            embeddingAPIKey: nil,
            rerankProvider: "dashscope",
            rerankModel: "qwen3-rerank",
            rerankBaseURL: "",
            rerankAPIKey: nil
        )

        let models = await restartCounter.embeddingModelsAtRestart
        XCTAssertEqual(models, ["text-embedding-v3"])
    }

    private func makeViewModel() -> SettingsViewModel {
        SettingsViewModel(
            defaults: defaults,
            credentialStore: credentialStore,
            knowledgeClient: client,
            retryKnowledgeSync: { [retryCounter] in await retryCounter?.increment() },
            rescanKnowledge: { [rescanCounter] in await rescanCounter?.increment() },
            restartKnowledgeService: { [restartCounter, defaults] in
                await restartCounter?.record(embeddingModel: defaults?.string(forKey: "knowledge.embeddingModel"))
            }
        )
    }
}

private final class TestKnowledgeCredentialStore: KnowledgeCredentialStoreProtocol, @unchecked Sendable {
    private var values: [String: String] = [:]
    private(set) var saveEmbeddingCallCount = 0
    private(set) var saveRerankCallCount = 0
    var embeddingSaveFailure = false
    var rerankSaveFailure = false

    func saveEmbeddingAPIKey(_ value: String) throws {
        if embeddingSaveFailure { throw KnowledgeCredentialError.keychain(errSecAuthFailed) }
        saveEmbeddingCallCount += 1
        values["embedding-api-key"] = normalized(value)
    }

    func saveRerankAPIKey(_ value: String) throws {
        if rerankSaveFailure { throw KnowledgeCredentialError.keychain(errSecAuthFailed) }
        saveRerankCallCount += 1
        values["rerank-api-key"] = normalized(value)
    }

    func seedLegacyDashScopeKey(_ value: String) {
        values["dashscope-api-key"] = value
    }

    func dashScopeAPIKey() -> String { values["dashscope-api-key"] ?? "" }

    /// 与真实存储一致:新账户为空时回退旧账户。
    func embeddingAPIKey() -> String {
        let value = values["embedding-api-key"] ?? ""
        return value.isEmpty ? dashScopeAPIKey() : value
    }

    /// 与真实存储一致:新账户为空时回退旧账户。
    func rerankAPIKey() -> String {
        let value = values["rerank-api-key"] ?? ""
        return value.isEmpty ? dashScopeAPIKey() : value
    }

    func strictEmbeddingAPIKey() -> String { values["embedding-api-key"] ?? "" }

    func strictRerankAPIKey() -> String { values["rerank-api-key"] ?? "" }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class InMemoryCredentialBox: @unchecked Sendable {
    var values: [String: String] = [:]
}

private actor SettingsKnowledgeClient: KnowledgeClientProtocol {
    private(set) var retryCount = 0
    private(set) var resetCount = 0
    private var shouldFailRetry = false
    private var shouldFailReset = false
    private var degraded = false
    private var rescanCompleted = false

    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1", serviceVersion: "1", indexVersion: 1) }
    func status() async throws -> KnowledgeStatusDTO {
        if resetCount > 0, !rescanCompleted {
            return .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false)
        }
        return .init(documents: 2, chunks: 3, pendingJobs: 0, failedJobs: 1, degraded: degraded)
    }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { .init(status: "indexed", generationChunks: 0, retrievalChunks: 0, summaryChunks: 0, embeddedChunks: 0) }
    func delete(recordingId _: UUID) async throws { }
    func retryFailed() async throws {
        retryCount += 1
        if shouldFailRetry { throw KnowledgeClientError.network }
    }
    func resetIndex() async throws {
        resetCount += 1
        if shouldFailReset { throw KnowledgeClientError.network }
    }
    nonisolated func query(_: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func setDegraded(_ value: Bool) { degraded = value }
    func setRetryFailure(_ value: Bool) { shouldFailRetry = value }
    func setResetFailure(_ value: Bool) { shouldFailReset = value }
    /// 模拟后台重扫完成:服务端重新有了数据。
    func markRescanCompleted() { rescanCompleted = true }
}

private actor SettingsRetryCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor SettingsRescanCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor SettingsRestartCounter {
    private(set) var value = 0
    private(set) var embeddingModelsAtRestart: [String?] = []

    func increment() { value += 1 }

    func record(embeddingModel: String?) {
        embeddingModelsAtRestart.append(embeddingModel)
        value += 1
    }
}

private actor DelayedStatusKnowledgeClient: KnowledgeClientProtocol {
    private var statusRequestCount = 0
    private var firstStatusContinuation: CheckedContinuation<Void, Never>?
    private var firstStatusStarted: CheckedContinuation<Void, Never>?

    func health() async throws -> KnowledgeHealthDTO { .init(status: "ok", apiVersion: "1", serviceVersion: "1", indexVersion: 1) }

    func status() async throws -> KnowledgeStatusDTO {
        statusRequestCount += 1
        if statusRequestCount == 1 {
            firstStatusStarted?.resume()
            firstStatusStarted = nil
            await withCheckedContinuation { firstStatusContinuation = $0 }
            return .init(documents: 99, chunks: 99, pendingJobs: 0, failedJobs: 0, degraded: true)
        }
        return .init(documents: 0, chunks: 0, pendingJobs: 0, failedJobs: 0, degraded: false)
    }

    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { .init(status: "indexed", generationChunks: 0, retrievalChunks: 0, summaryChunks: 0, embeddedChunks: 0) }
    func delete(recordingId _: UUID) async throws { }
    func retryFailed() async throws { }
    func resetIndex() async throws { }
    nonisolated func query(_: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func waitForFirstStatusRequest() async {
        if statusRequestCount > 0 { return }
        await withCheckedContinuation { firstStatusStarted = $0 }
    }

    func releaseFirstStatus() {
        firstStatusContinuation?.resume()
        firstStatusContinuation = nil
    }
}
