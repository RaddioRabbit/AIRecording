import Foundation
import AppKit
import Combine

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var recordingFormat: String = "caf"
    @Published var sampleRate: Double = 44100
    @Published var channels: Int = 1
    @Published var transcriptionLanguage: String = "auto"
    @Published var enhancedMode: Bool = false
    @Published var storagePath: String = ""

    @Published var llmBaseURL: String = ""
    @Published var llmAPIKey: String = ""
    @Published var llmModel: String = ""

    @Published var defaultAudioSource: AudioSource = .microphone
    @Published var transcriptionEngine: TranscriptionEngine = .appleSpeech
    @Published var funASRAPIKey: String = ""
    @Published var speakerCount: Int = 0

    @Published var ossAccessKeyId: String = ""
    @Published var ossAccessKeySecret: String = ""
    @Published var ossBucket: String = ""
    @Published var ossEndpoint: String = ""

    @Published private(set) var knowledgeEmbeddingKeyMasked = "未配置"
    @Published private(set) var knowledgeRerankKeyMasked = "未配置"
    @Published private(set) var knowledgeDocumentCount = 0
    @Published private(set) var knowledgeChunkCount = 0
    @Published private(set) var knowledgeFailedCount = 0
    @Published private(set) var isKnowledgeIndexDegraded = false
    @Published private(set) var isKnowledgeOperationInProgress = false
    @Published private(set) var knowledgeStatusError: String?

    @Published var knowledgeEmbeddingProvider = "dashscope"
    @Published var knowledgeEmbeddingModel = KnowledgeModelCatalog.defaultEmbeddingModel
    @Published var knowledgeEmbeddingDimension = 0
    @Published var knowledgeEmbeddingBaseURL = ""
    @Published var knowledgeRerankProvider = "dashscope"
    @Published var knowledgeRerankModel = KnowledgeModelCatalog.defaultRerankModel
    @Published var knowledgeRerankBaseURL = ""

    var storagePathDisplay: String {
        if storagePath.isEmpty {
            return "默认位置"
        }
        return storagePath
    }

    var apiKeyMasked: String {
        if llmAPIKey.isEmpty { return "未配置" }
        if llmAPIKey.count <= 8 { return "********" }
        let prefix = String(llmAPIKey.prefix(4))
        let suffix = String(llmAPIKey.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    var funASRAPIKeyMasked: String {
        if funASRAPIKey.isEmpty { return "未配置" }
        if funASRAPIKey.count <= 8 { return "********" }
        let prefix = String(funASRAPIKey.prefix(4))
        let suffix = String(funASRAPIKey.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    var ossAccessKeyIdMasked: String {
        if ossAccessKeyId.isEmpty { return "未配置" }
        if ossAccessKeyId.count <= 8 { return "********" }
        let prefix = String(ossAccessKeyId.prefix(4))
        let suffix = String(ossAccessKeyId.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    var ossAccessKeySecretMasked: String {
        if ossAccessKeySecret.isEmpty { return "未配置" }
        return "********"
    }

    private let defaults: UserDefaults
    private let credentialStore: any KnowledgeCredentialStoreProtocol
    private let knowledgeClient: any KnowledgeClientProtocol
    private let retryKnowledgeSync: @Sendable () async -> Void
    private let rescanKnowledge: @Sendable () async -> Void
    private let restartKnowledgeService: @Sendable () async -> Void
    private var knowledgeStatusGeneration = 0
    private var knowledgeSyncCancellables: Set<AnyCancellable> = []
    private let storagePathKey = "storage.location"
    private let formatKey = "recording.format"
    private let sampleRateKey = "recording.sampleRate"
    private let channelsKey = "recording.channels"
    private let languageKey = "transcription.defaultLanguage"
    private let enhancedKey = "transcription.enhancedMode"

    private let llmBaseURLKey = "llm.baseURL"
    private let llmAPIKeyKey = "llm.apiKey"
    private let llmModelKey = "llm.model"
    private let defaultAudioSourceKey = "recording.defaultAudioSource"
    private let transcriptionEngineKey = "transcription.engine"
    private let funASRAPIKeyKey = "funasr.apiKey"
    private let speakerCountKey = "transcription.speakerCount"

    private let ossAccessKeyIdKey = "oss.accessKeyId"
    private let ossAccessKeySecretKey = "oss.accessKeySecret"
    private let ossBucketKey = "oss.bucket"
    private let ossEndpointKey = "oss.endpoint"

    private let knowledgeEmbeddingProviderKey = "knowledge.embeddingProvider"
    private let knowledgeEmbeddingModelKey = "knowledge.embeddingModel"
    private let knowledgeEmbeddingDimensionKey = "knowledge.embeddingDimension"
    private let knowledgeEmbeddingBaseURLKey = "knowledge.embeddingBaseURL"
    private let knowledgeRerankProviderKey = "knowledge.rerankProvider"
    private let knowledgeRerankModelKey = "knowledge.rerankModel"
    private let knowledgeRerankBaseURLKey = "knowledge.rerankBaseURL"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any KnowledgeCredentialStoreProtocol = KnowledgeCredentialStore(),
        knowledgeClient: any KnowledgeClientProtocol = KnowledgeClient.shared,
        retryKnowledgeSync: @escaping @Sendable () async -> Void = {
            await KnowledgeSyncCoordinator.shared.retryFailed()
        },
        rescanKnowledge: @escaping @Sendable () async -> Void = {
            await KnowledgeSyncCoordinator.shared.rescanAfterIndexReset()
        },
        restartKnowledgeService: @escaping @Sendable () async -> Void = {
            await KnowledgeServiceManager.shared.restartService()
        }
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.knowledgeClient = knowledgeClient
        self.retryKnowledgeSync = retryKnowledgeSync
        self.rescanKnowledge = rescanKnowledge
        self.restartKnowledgeService = restartKnowledgeService
        // 后台同步队列排空时自动刷新状态:重建/重试触发的是异步后台任务,
        // 按钮流程内的即时查询只能看到 0/0/0 中间态,必须在队列真正排空后再刷一次。
        NotificationCenter.default.publisher(for: .knowledgeSyncQueueDrained)
            .sink { [weak self] _ in
                Task { await self?.refreshKnowledgeStatusAfterSyncDrain() }
            }
            .store(in: &knowledgeSyncCancellables)
    }

    func loadSettings() {
        storagePath = defaults.string(forKey: storagePathKey) ?? ""
        recordingFormat = defaults.string(forKey: formatKey) ?? "caf"
        sampleRate = defaults.double(forKey: sampleRateKey)
        if sampleRate == 0 { sampleRate = 44100 }
        channels = defaults.integer(forKey: channelsKey)
        if channels == 0 { channels = 1 }
        transcriptionLanguage = defaults.string(forKey: languageKey) ?? "auto"
        enhancedMode = defaults.bool(forKey: enhancedKey)

        llmBaseURL = defaults.string(forKey: llmBaseURLKey) ?? "https://api.deepseek.com/v1"
        llmAPIKey = defaults.string(forKey: llmAPIKeyKey) ?? ""
        llmModel = defaults.string(forKey: llmModelKey) ?? "deepseek-v4-flash"

        if let raw = defaults.object(forKey: defaultAudioSourceKey) as? Int,
           let source = AudioSource(rawValue: raw) {
            defaultAudioSource = source
        } else {
            defaultAudioSource = .microphone
        }

        if let raw = defaults.object(forKey: transcriptionEngineKey) as? Int,
           let engine = TranscriptionEngine(rawValue: raw) {
            transcriptionEngine = engine
        } else {
            transcriptionEngine = .appleSpeech
        }

        funASRAPIKey = defaults.string(forKey: funASRAPIKeyKey) ?? ""
        speakerCount = defaults.integer(forKey: speakerCountKey)

        ossAccessKeyId = defaults.string(forKey: ossAccessKeyIdKey) ?? ""
        ossAccessKeySecret = defaults.string(forKey: ossAccessKeySecretKey) ?? ""
        ossBucket = defaults.string(forKey: ossBucketKey) ?? ""
        ossEndpoint = defaults.string(forKey: ossEndpointKey) ?? ""
        knowledgeEmbeddingProvider = Self.normalizedKnowledgeProvider(defaults.string(forKey: knowledgeEmbeddingProviderKey))
        knowledgeRerankProvider = Self.normalizedKnowledgeProvider(defaults.string(forKey: knowledgeRerankProviderKey))
        knowledgeEmbeddingBaseURL = defaults.string(forKey: knowledgeEmbeddingBaseURLKey) ?? ""
        knowledgeRerankBaseURL = defaults.string(forKey: knowledgeRerankBaseURLKey) ?? ""
        knowledgeEmbeddingKeyMasked = Self.knowledgeKeyMask(for: Self.knowledgeKeyValue(
            provider: knowledgeEmbeddingProvider,
            strict: credentialStore.strictEmbeddingAPIKey(),
            fallback: credentialStore.embeddingAPIKey()
        ))
        knowledgeRerankKeyMasked = Self.knowledgeKeyMask(for: Self.knowledgeKeyValue(
            provider: knowledgeRerankProvider,
            strict: credentialStore.strictRerankAPIKey(),
            fallback: credentialStore.rerankAPIKey()
        ))
        knowledgeEmbeddingModel = defaults.string(forKey: knowledgeEmbeddingModelKey)
            ?? KnowledgeModelCatalog.defaultEmbeddingModel
        knowledgeEmbeddingDimension = defaults.integer(forKey: knowledgeEmbeddingDimensionKey)
        knowledgeRerankModel = defaults.string(forKey: knowledgeRerankModelKey)
            ?? KnowledgeModelCatalog.defaultRerankModel

        if defaults.object(forKey: transcriptionEngineKey) == nil {
            transcriptionEngine = .funASR
            defaults.set(transcriptionEngine.rawValue, forKey: transcriptionEngineKey)
        }
    }

    func saveSettings() {
        defaults.set(storagePath, forKey: storagePathKey)
        defaults.set(recordingFormat, forKey: formatKey)
        defaults.set(sampleRate, forKey: sampleRateKey)
        defaults.set(channels, forKey: channelsKey)
        defaults.set(transcriptionLanguage, forKey: languageKey)
        defaults.set(enhancedMode, forKey: enhancedKey)

        defaults.set(llmBaseURL, forKey: llmBaseURLKey)
        defaults.set(llmAPIKey, forKey: llmAPIKeyKey)
        defaults.set(llmModel, forKey: llmModelKey)
        defaults.set(defaultAudioSource.rawValue, forKey: defaultAudioSourceKey)
        defaults.set(transcriptionEngine.rawValue, forKey: transcriptionEngineKey)
        defaults.set(funASRAPIKey, forKey: funASRAPIKeyKey)
        defaults.set(speakerCount, forKey: speakerCountKey)

        defaults.set(ossAccessKeyId, forKey: ossAccessKeyIdKey)
        defaults.set(ossAccessKeySecret, forKey: ossAccessKeySecretKey)
        defaults.set(ossBucket, forKey: ossBucketKey)
        defaults.set(ossEndpoint, forKey: ossEndpointKey)
    }

    func chooseStoragePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            storagePath = url.path
            saveSettings()
        }
    }

    func loadKnowledgeStatus() async {
        guard !isKnowledgeOperationInProgress else { return }
        let generation = nextKnowledgeStatusGeneration()
        await applyKnowledgeStatus(for: generation)
    }

    /// 队列排空触发的后台刷新:不检查按钮操作进行中(排空可发生在任意时刻),
    /// 依靠 generation 机制保证只有最新一次刷新的结果会显示。
    private func refreshKnowledgeStatusAfterSyncDrain() async {
        let generation = nextKnowledgeStatusGeneration()
        await applyKnowledgeStatus(for: generation)
    }

    /// 保存知识库检索服务配置。Keychain 写失败时返回 false 且不改动任何 defaults/状态/服务(原子);
    /// 成功时返回 true 并重启服务。
    @discardableResult
    func saveKnowledgeServiceSettings(
        embeddingProvider: String,
        embeddingModel: String,
        embeddingDimension: Int?,
        embeddingBaseURL: String,
        embeddingAPIKey: String?,
        rerankProvider: String,
        rerankModel: String,
        rerankBaseURL: String,
        rerankAPIKey: String?
    ) async -> Bool {
        let normalizedEmbeddingProvider = Self.normalizedKnowledgeProvider(embeddingProvider)
        let normalizedRerankProvider = Self.normalizedKnowledgeProvider(rerankProvider)
        // Key 参数为 nil 或 trim 后为空表示保持现有密钥,不碰 Keychain。
        let trimmedEmbeddingKey = embeddingAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRerankKey = rerankAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if !trimmedEmbeddingKey.isEmpty {
                try credentialStore.saveEmbeddingAPIKey(trimmedEmbeddingKey)
            }
            if !trimmedRerankKey.isEmpty {
                try credentialStore.saveRerankAPIKey(trimmedRerankKey)
            }
        } catch {
            AppLogger.log(.error, category: "settings", event: "knowledge_api_key_save_failed", errorCode: "KEYCHAIN")
            return false
        }

        defaults.set(normalizedEmbeddingProvider, forKey: knowledgeEmbeddingProviderKey)
        defaults.set(normalizedRerankProvider, forKey: knowledgeRerankProviderKey)
        defaults.set(embeddingBaseURL, forKey: knowledgeEmbeddingBaseURLKey)
        defaults.set(rerankBaseURL, forKey: knowledgeRerankBaseURLKey)
        defaults.set(embeddingModel, forKey: knowledgeEmbeddingModelKey)
        defaults.set(rerankModel, forKey: knowledgeRerankModelKey)
        if let embeddingDimension {
            defaults.set(embeddingDimension, forKey: knowledgeEmbeddingDimensionKey)
        } else {
            defaults.removeObject(forKey: knowledgeEmbeddingDimensionKey)
        }

        knowledgeEmbeddingProvider = normalizedEmbeddingProvider
        knowledgeRerankProvider = normalizedRerankProvider
        knowledgeEmbeddingBaseURL = embeddingBaseURL
        knowledgeRerankBaseURL = rerankBaseURL
        knowledgeEmbeddingModel = embeddingModel
        knowledgeEmbeddingDimension = embeddingDimension ?? 0
        knowledgeRerankModel = rerankModel
        knowledgeEmbeddingKeyMasked = Self.knowledgeKeyMask(for: Self.knowledgeKeyValue(
            provider: normalizedEmbeddingProvider,
            strict: credentialStore.strictEmbeddingAPIKey(),
            fallback: credentialStore.embeddingAPIKey()
        ))
        knowledgeRerankKeyMasked = Self.knowledgeKeyMask(for: Self.knowledgeKeyValue(
            provider: normalizedRerankProvider,
            strict: credentialStore.strictRerankAPIKey(),
            fallback: credentialStore.rerankAPIKey()
        ))
        await restartKnowledgeService()
        return true
    }

    private static func normalizedKnowledgeProvider(_ raw: String?) -> String {
        raw?.lowercased() == "openai" ? "openai" : "dashscope"
    }

    /// 已保存密钥(按供应商解析,规则与保存流程一致:openai 只认专属账户,不回退旧 Key)。
    func savedEmbeddingKey(provider: String) -> String {
        Self.knowledgeKeyValue(
            provider: provider,
            strict: credentialStore.strictEmbeddingAPIKey(),
            fallback: credentialStore.embeddingAPIKey()
        )
    }

    func savedRerankKey(provider: String) -> String {
        Self.knowledgeKeyValue(
            provider: provider,
            strict: credentialStore.strictRerankAPIKey(),
            fallback: credentialStore.rerankAPIKey()
        )
    }

    /// Key 取值按供应商区分:openai 只看严格读取(避免旧阿里云 Key 泄漏给第三方端点),dashscope/缺省用回退版。
    private static func knowledgeKeyValue(provider: String, strict: String, fallback: String) -> String {
        provider == "openai" ? strict : fallback
    }

    private static func knowledgeKeyMask(for key: String) -> String {
        key.isEmpty ? "未配置" : "••••••••"
    }

    func retryFailedKnowledgeSync() async {
        guard beginKnowledgeOperation() else { return }
        let generation = nextKnowledgeStatusGeneration()
        defer { isKnowledgeOperationInProgress = false }
        await retryKnowledgeSync()
        do {
            try await knowledgeClient.retryFailed()
        } catch {
            guard generation == knowledgeStatusGeneration else { return }
            knowledgeStatusError = "重试失败，请稍后重试。"
            return
        }
        await applyKnowledgeStatus(for: generation)
    }

    func resetKnowledgeIndex() async {
        guard beginKnowledgeOperation() else { return }
        let generation = nextKnowledgeStatusGeneration()
        defer { isKnowledgeOperationInProgress = false }
        do {
            try await knowledgeClient.resetIndex()
        } catch {
            guard generation == knowledgeStatusGeneration else { return }
            knowledgeStatusError = "重建知识库失败，请重试。"
            return
        }
        // 清空索引后历史录音不会自动重新提交,必须触发一次全量重扫,
        // 否则索引永远停在 0/0/0。
        await rescanKnowledge()
        await applyKnowledgeStatus(for: generation)
    }

    private func beginKnowledgeOperation() -> Bool {
        guard !isKnowledgeOperationInProgress else { return false }
        isKnowledgeOperationInProgress = true
        return true
    }

    private func nextKnowledgeStatusGeneration() -> Int {
        knowledgeStatusGeneration &+= 1
        return knowledgeStatusGeneration
    }

    private func applyKnowledgeStatus(for generation: Int) async {
        let status: KnowledgeStatusDTO
        do {
            status = try await knowledgeClient.status()
        } catch {
            guard generation == knowledgeStatusGeneration else { return }
            knowledgeStatusError = "知识库状态暂时不可用。"
            return
        }
        guard generation == knowledgeStatusGeneration else { return }
        knowledgeDocumentCount = status.documents
        knowledgeChunkCount = status.chunks
        knowledgeFailedCount = status.failedJobs
        isKnowledgeIndexDegraded = status.degraded
        knowledgeStatusError = nil
    }
}
