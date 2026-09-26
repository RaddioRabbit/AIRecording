import Foundation
import KnowledgeAgentResources

struct KnowledgeLLMConfiguration: Sendable, Equatable {
    let baseURL: String
    let apiKey: String
    let model: String
}

enum KnowledgeServiceError: Error, Equatable {
    case runtimeUnavailable
    case launchFailed
}

@MainActor
final class KnowledgeServiceManager: ObservableObject {
    static let shared = KnowledgeServiceManager()
    nonisolated static let expectedServiceVersion = "1.1.0"

    nonisolated static var bundledMainURL: URL? {
        KnowledgeAgentBundle.bundle.url(forResource: "main", withExtension: "py")
    }

    nonisolated static var bundledAgentExecutableURL: URL? {
        guard let resourceRoot = Bundle.main.resourceURL else { return nil }
        return releaseExecutableURL(resourceRoot: resourceRoot)
    }

    nonisolated static var developmentProjectRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    nonisolated static func releaseExecutableURL(resourceRoot: URL) -> URL? {
        let executable = resourceRoot.appendingPathComponent("KnowledgeAgent/knowledge-agent")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    nonisolated static func developmentLaunchConfiguration(
        projectRoot: URL,
        mainURL: URL,
        configuredPython: String?
    ) -> (executable: URL, arguments: [String], workingDirectory: URL)? {
        guard FileManager.default.fileExists(atPath: mainURL.path) else { return nil }
        let configured = configuredPython.flatMap { path in
            FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let venv = projectRoot.appendingPathComponent("KnowledgeAgent/.venv/bin/python")
        let executable = configured ?? (FileManager.default.isExecutableFile(atPath: venv.path) ? venv : nil)
        guard let executable else { return nil }
        return (executable, [mainURL.path], mainURL.deletingLastPathComponent())
    }

    @Published private(set) var isRunning = false
    private let servicePort = 8766
    private let serviceHost = "127.0.0.1"
    private let client: any KnowledgeClientProtocol
    private let credentialStore: any KnowledgeCredentialLoading
    private let startupGate = KnowledgeStartupGate()
    private let onProcessLaunchAttempt: (() -> Void)?
    private var process: Process?
    private var lifecycleGeneration = 0
    private var acceptsStarts = true

    init(
        client: any KnowledgeClientProtocol = KnowledgeClient.shared,
        credentialStore: any KnowledgeCredentialLoading = KnowledgeCredentialStore(),
        ownedProcess: Process? = nil,
        onProcessLaunchAttempt: (() -> Void)? = nil
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.process = ownedProcess
        self.onProcessLaunchAttempt = onProcessLaunchAttempt
    }

    nonisolated static func isSupportedHealth(_ health: KnowledgeHealthDTO) -> Bool {
        health.status == "ok" && health.apiVersion == "1.0" && health.serviceVersion == expectedServiceVersion
    }

    nonisolated static func serviceEnvironment(
        parent: [String: String],
        dashScopeKey: String,
        llm: KnowledgeLLMConfiguration,
        databasePath: String,
        port: Int,
        embeddingModel: String? = nil,
        embeddingDimension: Int? = nil,
        rerankModel: String? = nil,
        embeddingProvider: String? = nil,
        embeddingAPIKey: String? = nil,
        embeddingBaseURL: String? = nil,
        rerankProvider: String? = nil,
        rerankAPIKey: String? = nil,
        rerankBaseURL: String? = nil
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["PATH", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = parent[key], !value.isEmpty { environment[key] = value }
        }
        if !dashScopeKey.isEmpty { environment["DASHSCOPE_API_KEY"] = dashScopeKey }
        if !llm.apiKey.isEmpty { environment["OPENAI_API_KEY"] = llm.apiKey }
        if !llm.baseURL.isEmpty { environment["OPENAI_BASE_URL"] = llm.baseURL }
        if !llm.model.isEmpty { environment["LLM_MODEL"] = llm.model }
        if let embeddingModel, !embeddingModel.isEmpty { environment["EMBEDDING_MODEL"] = embeddingModel }
        if let embeddingDimension, embeddingDimension > 0 { environment["EMBEDDING_DIMENSION"] = String(embeddingDimension) }
        if let rerankModel, !rerankModel.isEmpty { environment["RERANK_MODEL"] = rerankModel }
        if let embeddingProvider, !embeddingProvider.isEmpty { environment["EMBEDDING_PROVIDER"] = embeddingProvider }
        if let embeddingAPIKey, !embeddingAPIKey.isEmpty { environment["EMBEDDING_API_KEY"] = embeddingAPIKey }
        if let embeddingBaseURL, !embeddingBaseURL.isEmpty { environment["EMBEDDING_BASE_URL"] = embeddingBaseURL }
        if let rerankProvider, !rerankProvider.isEmpty { environment["RERANK_PROVIDER"] = rerankProvider }
        if let rerankAPIKey, !rerankAPIKey.isEmpty { environment["RERANK_API_KEY"] = rerankAPIKey }
        if let rerankBaseURL, !rerankBaseURL.isEmpty { environment["RERANK_BASE_URL"] = rerankBaseURL }
        environment["KNOWLEDGE_DB_PATH"] = databasePath
        environment["PORT"] = String(port)
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    nonisolated static func developmentDotenvValues(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let allowed = Set([
            "DASHSCOPE_API_KEY", "EMBEDDING_MODEL", "EMBEDDING_DIMENSION", "RERANK_MODEL",
            "EMBEDDING_PROVIDER", "RERANK_PROVIDER",
            "EMBEDDING_API_KEY", "RERANK_API_KEY",
            "EMBEDDING_BASE_URL", "RERANK_BASE_URL",
        ])
        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { return }
            let key = String(text[..<equals]).trimmingCharacters(in: .whitespaces)
            guard allowed.contains(key) else { return }
            var value = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst(); value.removeLast()
            }
            values[key] = value
        }
    }

    nonisolated static func resolveDashScopeAPIKey(
        environment: [String: String],
        dotenv: [String: String],
        keychainValue: String
    ) -> String {
        environment["DASHSCOPE_API_KEY"].nilIfEmpty
            ?? dotenv["DASHSCOPE_API_KEY"].nilIfEmpty
            ?? keychainValue
    }

    /// 供应商归一化:非 "openai"(大小写不敏感)一律按 "dashscope";空/缺省返回 nil(不注入,Python 端缺省 dashscope)。
    nonisolated private static func resolvedProvider(raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.lowercased() == "openai" ? "openai" : "dashscope"
    }

    /// 纯函数解析供应商/Key/维度守卫:从环境变量、dotenv、UserDefaults 与 Keychain 读出子进程配置,便于单测。
    nonisolated static func resolvedKnowledgeConfiguration(
        environment: [String: String],
        dotenv: [String: String],
        defaults: UserDefaults,
        credentialStore: any KnowledgeCredentialLoading
    ) -> KnowledgeAgentConfiguration {
        let key = resolveDashScopeAPIKey(
            environment: environment,
            dotenv: dotenv,
            keychainValue: credentialStore.dashScopeAPIKey()
        )
        let embeddingModel = environment["EMBEDDING_MODEL"].nilIfEmpty
            ?? dotenv["EMBEDDING_MODEL"].nilIfEmpty
            ?? defaults.string(forKey: "knowledge.embeddingModel").nilIfEmpty
        let rerankModel = environment["RERANK_MODEL"].nilIfEmpty
            ?? dotenv["RERANK_MODEL"].nilIfEmpty
            ?? defaults.string(forKey: "knowledge.rerankModel").nilIfEmpty
        let embeddingProvider = resolvedProvider(
            raw: environment["EMBEDDING_PROVIDER"].nilIfEmpty
                ?? dotenv["EMBEDDING_PROVIDER"].nilIfEmpty
                ?? defaults.string(forKey: "knowledge.embeddingProvider").nilIfEmpty
        )
        let rerankProvider = resolvedProvider(
            raw: environment["RERANK_PROVIDER"].nilIfEmpty
                ?? dotenv["RERANK_PROVIDER"].nilIfEmpty
                ?? defaults.string(forKey: "knowledge.rerankProvider").nilIfEmpty
        )
        let embeddingBaseURL = environment["EMBEDDING_BASE_URL"].nilIfEmpty
            ?? dotenv["EMBEDDING_BASE_URL"].nilIfEmpty
            ?? defaults.string(forKey: "knowledge.embeddingBaseURL").nilIfEmpty
        let rerankBaseURL = environment["RERANK_BASE_URL"].nilIfEmpty
            ?? dotenv["RERANK_BASE_URL"].nilIfEmpty
            ?? defaults.string(forKey: "knowledge.rerankBaseURL").nilIfEmpty
        let embeddingDimension: Int?
        if let raw = environment["EMBEDDING_DIMENSION"].nilIfEmpty ?? dotenv["EMBEDDING_DIMENSION"].nilIfEmpty {
            embeddingDimension = Int(raw)
        } else if embeddingProvider == "openai" {
            // OpenAI 兼容:无目录校验,>0 即透传,缺省不注入。
            if let saved = defaults.object(forKey: "knowledge.embeddingDimension") as? Int, saved > 0 {
                embeddingDimension = saved
            } else {
                embeddingDimension = nil
            }
        } else if let saved = defaults.object(forKey: "knowledge.embeddingDimension") as? Int, saved > 0 {
            if let model = embeddingModel {
                if let options = KnowledgeModelCatalog.dimensions(for: model) {
                    // dashscope 预设模型(含供应商缺省,老配置行为保持升级前不变):必须在官方维度表内。
                    embeddingDimension = options.contains(saved) ? saved : nil
                } else {
                    // dashscope 自定义模型(目录查不到):正整数即透传,与配置面板的「自定义维度」一致。
                    embeddingDimension = saved
                }
            } else {
                // 模型缺省(Python 端按默认预设模型运行):保持升级前行为,不注入。
                embeddingDimension = nil
            }
        } else {
            embeddingDimension = nil
        }
        // Key 按供应商选择:dashscope/缺省→回退版(兼容老用户旧账户);openai→严格读取,无新 Key 就不注入,
        // 避免把旧阿里云 Key 发给第三方端点。
        let embeddingAPIKey = embeddingProvider == "openai"
            ? credentialStore.strictEmbeddingAPIKey()
            : credentialStore.embeddingAPIKey()
        let rerankAPIKey = rerankProvider == "openai"
            ? credentialStore.strictRerankAPIKey()
            : credentialStore.rerankAPIKey()
        return KnowledgeAgentConfiguration(
            dashScopeKey: key,
            embeddingModel: embeddingModel,
            embeddingDimension: embeddingDimension,
            rerankModel: rerankModel,
            embeddingProvider: embeddingProvider,
            embeddingAPIKey: embeddingAPIKey,
            embeddingBaseURL: embeddingBaseURL,
            rerankProvider: rerankProvider,
            rerankAPIKey: rerankAPIKey,
            rerankBaseURL: rerankBaseURL,
            llm: KnowledgeLLMConfiguration(
                baseURL: defaults.string(forKey: "llm.baseURL") ?? "https://api.deepseek.com/v1",
                apiKey: defaults.string(forKey: "llm.apiKey") ?? "",
                model: defaults.string(forKey: "llm.model") ?? "deepseek-v4-flash"
            )
        )
    }

    func ensureServiceRunning() async -> Bool {
        guard acceptsStarts else { return false }
        let generation = lifecycleGeneration
        return await startupGate.run { [weak self] in
            guard let self else { return false }
            return await self.startOrReuseService(lifecycleGeneration: generation)
        }
    }

    private func startOrReuseService(lifecycleGeneration: Int) async -> Bool {
        guard isCurrentLifecycle(lifecycleGeneration) else { return false }
        if let process, process.isRunning, await hasSupportedHealth() {
            guard isCurrentLifecycle(lifecycleGeneration) else { return false }
            isRunning = true
            return true
        }
        guard isCurrentLifecycle(lifecycleGeneration) else { return false }

        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard isCurrentLifecycle(lifecycleGeneration) else { return false }
            }
        }
        process = nil
        guard isCurrentLifecycle(lifecycleGeneration) else { return false }
        // The port may be held by a stale or foreign backend (an orphan from an
        // older build, or a process this app instance did not spawn). Evict it
        // first, otherwise the new process cannot bind.
        if await Self.killListenersOnPort(servicePort) {
            AppLogger.log(.info, category: "knowledge-agent", event: "service_stale_backend_evicted")
        }
        do {
            guard isCurrentLifecycle(lifecycleGeneration) else { return false }
            try startService()
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                guard isCurrentLifecycle(lifecycleGeneration) else { return false }
                if await hasSupportedHealth() {
                    guard isCurrentLifecycle(lifecycleGeneration) else { return false }
                    isRunning = true
                    return true
                }
            }
        } catch {
            AppLogger.log(.error, category: "knowledge-agent", event: "service_start_failed", errorCode: "RUNTIME_UNAVAILABLE")
        }
        isRunning = false
        return false
    }

    func stopService() {
        acceptsStarts = false
        lifecycleGeneration &+= 1
        startupGate.invalidate()
        process?.terminate()
        process = nil
        isRunning = false
    }

    func restartService() async {
        guard process != nil || isRunning else { return }
        lifecycleGeneration &+= 1
        startupGate.invalidate()
        isRunning = false
        let previous = process
        previous?.terminate()
        if let previous {
            await Self.waitForExit(of: previous)
        }
        if process === previous {
            process = nil
        }
        _ = await ensureServiceRunning()
    }

    nonisolated static func waitForExit(of process: Process) async {
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func hasSupportedHealth() async -> Bool {
        guard let health = try? await client.health() else { return false }
        return Self.isSupportedHealth(health)
    }

    private func startService() throws {
        onProcessLaunchAttempt?()
        let launch = try launchConfiguration()
        let configuration = resolvedConfiguration()
        let dbURL = knowledgeDatabaseURL()
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        process.environment = Self.serviceEnvironment(
            parent: ProcessInfo.processInfo.environment,
            dashScopeKey: configuration.dashScopeKey,
            llm: configuration.llm,
            databasePath: dbURL.path,
            port: servicePort,
            embeddingModel: configuration.embeddingModel,
            embeddingDimension: configuration.embeddingDimension,
            rerankModel: configuration.rerankModel,
            embeddingProvider: configuration.embeddingProvider,
            embeddingAPIKey: configuration.embeddingAPIKey,
            embeddingBaseURL: configuration.embeddingBaseURL,
            rerankProvider: configuration.rerankProvider,
            rerankAPIKey: configuration.rerankAPIKey,
            rerankBaseURL: configuration.rerankBaseURL
        )
        let stdout = SubprocessLogCapture(name: "knowledge-agent-stdout") { line in
            AppLogger.ingestKnowledgeAgentLine(line, isError: false)
        }
        let stderr = SubprocessLogCapture(name: "knowledge-agent-stderr") { line in
            AppLogger.ingestKnowledgeAgentLine(line, isError: true)
        }
        process.standardOutput = stdout.fileHandleForWriting
        process.standardError = stderr.fileHandleForWriting
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        stdout.start()
        stderr.start()
        process.terminationHandler = { _ in
            stdout.finish()
            stderr.finish()
        }
        self.process = process
        AppLogger.log(.info, category: "knowledge-agent", event: "service_started")
    }

    private func launchConfiguration() throws -> (executable: URL, arguments: [String], workingDirectory: URL) {
        if let binary = Self.bundledAgentExecutableURL,
           FileManager.default.isExecutableFile(atPath: binary.path) {
            return (binary, [], binary.deletingLastPathComponent())
        }
        #if !DEBUG
        throw KnowledgeServiceError.runtimeUnavailable
        #else
        guard let main = Self.bundledMainURL, let python = resolvedDevelopmentPython(mainURL: main) else {
            throw KnowledgeServiceError.runtimeUnavailable
        }
        return (python, [main.path], main.deletingLastPathComponent())
        #endif
    }

    private func resolvedDevelopmentPython(mainURL: URL) -> URL? {
        Self.developmentLaunchConfiguration(
            projectRoot: Self.developmentProjectRootURL,
            mainURL: mainURL,
            configuredPython: ProcessInfo.processInfo.environment["KNOWLEDGE_AGENT_PYTHON"]
        )?.executable
    }

    private func resolvedConfiguration() -> KnowledgeAgentConfiguration {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let dotenv = Self.developmentDotenvValues(
            at: Self.developmentProjectRootURL.appendingPathComponent("KnowledgeAgent/.env")
        )
        #else
        let dotenv: [String: String] = [:]
        #endif
        return Self.resolvedKnowledgeConfiguration(
            environment: environment,
            dotenv: dotenv,
            defaults: .standard,
            credentialStore: credentialStore
        )
    }

    private func knowledgeDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AIRecording/Knowledge/knowledge.sqlite")
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        acceptsStarts && generation == lifecycleGeneration && !Task.isCancelled
    }

    /// PIDs currently listening on the given TCP port, resolved via lsof.
    nonisolated static func pidsListeningOnPort(_ port: Int) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// SIGTERM every listener on the port and wait until it is released.
    /// Returns true when at least one listener was evicted. Used to evict
    /// stale or foreign backends before starting the bundled one.
    nonisolated static func killListenersOnPort(_ port: Int) async -> Bool {
        let pids = pidsListeningOnPort(port)
        guard !pids.isEmpty else { return false }
        for pid in pids {
            kill(pid, SIGTERM)
        }
        for _ in 0..<30 {
            if pidsListeningOnPort(port).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }
}

struct KnowledgeAgentConfiguration: Sendable, Equatable {
    let dashScopeKey: String
    let embeddingModel: String?
    let embeddingDimension: Int?
    let rerankModel: String?
    let embeddingProvider: String?
    let embeddingAPIKey: String?
    let embeddingBaseURL: String?
    let rerankProvider: String?
    let rerankAPIKey: String?
    let rerankBaseURL: String?
    let llm: KnowledgeLLMConfiguration
}

@MainActor
final class KnowledgeStartupGate {
    private var startup: (id: UUID, task: Task<Bool, Never>)?

    func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let startup { return await startup.task.value }
        let id = UUID()
        let task = Task { @MainActor in await operation() }
        startup = (id, task)
        let result = await task.value
        if startup?.id == id {
            startup = nil
        }
        return result
    }

    func invalidate() {
        startup?.task.cancel()
        startup = nil
    }
}

private extension String? {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
