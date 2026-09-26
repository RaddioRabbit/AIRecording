import Foundation
import XCTest
@testable import AIRecording

final class KnowledgeServiceManagerTests: XCTestCase {
    func testServiceEnvironmentUsesOnlyWhitelistedSecrets() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: ["UNRELATED_SECRET": "no", "PATH": "/usr/bin"],
            dashScopeKey: "dash",
            llm: .init(baseURL: "https://api.deepseek.com/v1", apiKey: "llm", model: "deepseek-chat"),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766
        )

        XCTAssertNil(environment["UNRELATED_SECRET"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["DASHSCOPE_API_KEY"], "dash")
        XCTAssertEqual(environment["OPENAI_API_KEY"], "llm")
        XCTAssertEqual(environment["OPENAI_BASE_URL"], "https://api.deepseek.com/v1")
        XCTAssertEqual(environment["LLM_MODEL"], "deepseek-chat")
        XCTAssertEqual(environment["KNOWLEDGE_DB_PATH"], "/tmp/knowledge.sqlite")
        XCTAssertEqual(environment["PORT"], "8766")
    }

    func testServiceEnvironmentInjectsModelOverridesIncludingDimension() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: [:],
            dashScopeKey: "dash",
            llm: .init(baseURL: "https://api.deepseek.com/v1", apiKey: "llm", model: "deepseek-chat"),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766,
            embeddingModel: "text-embedding-v4",
            embeddingDimension: 1536,
            rerankModel: "gte-rerank-v2"
        )

        XCTAssertEqual(environment["EMBEDDING_MODEL"], "text-embedding-v4")
        XCTAssertEqual(environment["EMBEDDING_DIMENSION"], "1536")
        XCTAssertEqual(environment["RERANK_MODEL"], "gte-rerank-v2")
    }

    func testServiceEnvironmentOmitsEmptyModelOverridesAndDimension() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: [:],
            dashScopeKey: "",
            llm: .init(baseURL: "", apiKey: "", model: ""),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766
        )

        XCTAssertNil(environment["EMBEDDING_MODEL"])
        XCTAssertNil(environment["EMBEDDING_DIMENSION"])
        XCTAssertNil(environment["RERANK_MODEL"])

        XCTAssertNil(
            KnowledgeServiceManager.serviceEnvironment(
                parent: [:],
                dashScopeKey: "",
                llm: .init(baseURL: "", apiKey: "", model: ""),
                databasePath: "/tmp/knowledge.sqlite",
                port: 8766,
                embeddingDimension: 0
            )["EMBEDDING_DIMENSION"]
        )
        XCTAssertNil(
            KnowledgeServiceManager.serviceEnvironment(
                parent: [:],
                dashScopeKey: "",
                llm: .init(baseURL: "", apiKey: "", model: ""),
                databasePath: "/tmp/knowledge.sqlite",
                port: 8766,
                embeddingDimension: -1
            )["EMBEDDING_DIMENSION"]
        )
    }

    func testServiceEnvironmentInjectsProviderSettingsKeysAndBaseURLs() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: [:],
            dashScopeKey: "",
            llm: .init(baseURL: "", apiKey: "", model: ""),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766,
            embeddingProvider: "openai",
            embeddingAPIKey: "embed-key",
            embeddingBaseURL: "https://api.siliconflow.cn/v1",
            rerankProvider: "dashscope",
            rerankAPIKey: "rerank-key",
            rerankBaseURL: "https://rerank.example.com/v1"
        )

        XCTAssertEqual(environment["EMBEDDING_PROVIDER"], "openai")
        XCTAssertEqual(environment["EMBEDDING_API_KEY"], "embed-key")
        XCTAssertEqual(environment["EMBEDDING_BASE_URL"], "https://api.siliconflow.cn/v1")
        XCTAssertEqual(environment["RERANK_PROVIDER"], "dashscope")
        XCTAssertEqual(environment["RERANK_API_KEY"], "rerank-key")
        XCTAssertEqual(environment["RERANK_BASE_URL"], "https://rerank.example.com/v1")
    }

    func testServiceEnvironmentOmitsProviderSettingsWhenAbsentOrEmpty() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: [:],
            dashScopeKey: "",
            llm: .init(baseURL: "", apiKey: "", model: ""),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766,
            embeddingProvider: "",
            embeddingAPIKey: "",
            embeddingBaseURL: "",
            rerankProvider: nil,
            rerankAPIKey: nil,
            rerankBaseURL: nil
        )

        XCTAssertNil(environment["EMBEDDING_PROVIDER"])
        XCTAssertNil(environment["EMBEDDING_API_KEY"])
        XCTAssertNil(environment["EMBEDDING_BASE_URL"])
        XCTAssertNil(environment["RERANK_PROVIDER"])
        XCTAssertNil(environment["RERANK_API_KEY"])
        XCTAssertNil(environment["RERANK_BASE_URL"])
    }

    func testDotenvParserOnlyAcceptsKnowledgeKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "DASHSCOPE_API_KEY=dash\nUNRELATED=no\nEMBEDDING_MODEL=embed\nEMBEDDING_DIMENSION=1536\nEMBEDDING_PROVIDER=openai\nRERANK_PROVIDER=dashscope\nEMBEDDING_API_KEY=ek\nRERANK_API_KEY=rk\nEMBEDDING_BASE_URL=https://api.siliconflow.cn/v1\nRERANK_BASE_URL=\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let values = KnowledgeServiceManager.developmentDotenvValues(at: url)
        XCTAssertEqual(values["DASHSCOPE_API_KEY"], "dash")
        XCTAssertEqual(values["EMBEDDING_MODEL"], "embed")
        XCTAssertEqual(values["EMBEDDING_DIMENSION"], "1536")
        XCTAssertEqual(values["EMBEDDING_PROVIDER"], "openai")
        XCTAssertEqual(values["RERANK_PROVIDER"], "dashscope")
        XCTAssertEqual(values["EMBEDDING_API_KEY"], "ek")
        XCTAssertEqual(values["RERANK_API_KEY"], "rk")
        XCTAssertEqual(values["EMBEDDING_BASE_URL"], "https://api.siliconflow.cn/v1")
        XCTAssertEqual(values["RERANK_BASE_URL"], "")
        XCTAssertNil(values["UNRELATED"])
    }

    func testDashScopeResolutionPrecedenceIsEnvironmentThenDotenvThenKeychain() {
        XCTAssertEqual(
            KnowledgeServiceManager.resolveDashScopeAPIKey(
                environment: ["DASHSCOPE_API_KEY": "environment"], dotenv: ["DASHSCOPE_API_KEY": "dotenv"], keychainValue: "keychain"
            ),
            "environment"
        )
        XCTAssertEqual(
            KnowledgeServiceManager.resolveDashScopeAPIKey(
                environment: [:], dotenv: ["DASHSCOPE_API_KEY": "dotenv"], keychainValue: "keychain"
            ),
            "dotenv"
        )
        XCTAssertEqual(
            KnowledgeServiceManager.resolveDashScopeAPIKey(environment: [:], dotenv: [:], keychainValue: "keychain"),
            "keychain"
        )
    }

    // MARK: - resolvedKnowledgeConfiguration

    func testResolvedConfigurationSelectsKeysByProvider() {
        let defaults = makeIsolatedDefaults()
        var store = StubKnowledgeCredentialStore(
            dashScope: "legacy",
            embedding: "legacy-embed",
            rerank: "legacy-rerank"
        )

        // 缺省 provider(nil)→ dashscope 语义:回退版读取可见旧账户 Key
        var config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: store
        )
        XCTAssertNil(config.embeddingProvider)
        XCTAssertNil(config.rerankProvider)
        XCTAssertEqual(config.embeddingAPIKey, "legacy-embed")
        XCTAssertEqual(config.rerankAPIKey, "legacy-rerank")

        // openai 供应商→严格读取,旧 Key 不注入
        defaults.set("openai", forKey: "knowledge.embeddingProvider")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: store
        )
        XCTAssertEqual(config.embeddingProvider, "openai")
        XCTAssertEqual(config.embeddingAPIKey, "")
        XCTAssertEqual(config.rerankAPIKey, "legacy-rerank")

        defaults.set("openai", forKey: "knowledge.rerankProvider")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: store
        )
        XCTAssertEqual(config.rerankAPIKey, "")

        // 配置了新账户 Key 时 openai 使用新 Key
        store.strictEmbedding = "new-embed"
        store.strictRerank = "new-rerank"
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: store
        )
        XCTAssertEqual(config.embeddingAPIKey, "new-embed")
        XCTAssertEqual(config.rerankAPIKey, "new-rerank")
    }

    func testResolvedConfigurationNormalizesProviderCaseInsensitivelyWithEnvironmentPrecedence() {
        let defaults = makeIsolatedDefaults()
        defaults.set("dashscope", forKey: "knowledge.embeddingProvider")

        var config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: ["EMBEDDING_PROVIDER": "OpenAI"], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingProvider, "openai")

        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: ["EMBEDDING_PROVIDER": "Azure"], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingProvider, "dashscope")
    }

    func testResolvedConfigurationDimensionGuardOpenAIPassesThroughWithoutCatalog() {
        let defaults = makeIsolatedDefaults()
        defaults.set("openai", forKey: "knowledge.embeddingProvider")
        defaults.set("custom-openai-model", forKey: "knowledge.embeddingModel")

        defaults.set(1536, forKey: "knowledge.embeddingDimension")
        var config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingDimension, 1536)

        defaults.set(0, forKey: "knowledge.embeddingDimension")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)

        defaults.removeObject(forKey: "knowledge.embeddingDimension")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)
    }

    func testResolvedConfigurationDimensionGuardDashScopeRequiresCatalogDimension() {
        let defaults = makeIsolatedDefaults()
        defaults.set("dashscope", forKey: "knowledge.embeddingProvider")
        defaults.set("text-embedding-v4", forKey: "knowledge.embeddingModel")

        defaults.set(999, forKey: "knowledge.embeddingDimension")
        var config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)

        defaults.set(1536, forKey: "knowledge.embeddingDimension")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingDimension, 1536)

        // 缺省 provider(升级老配置)行为保持:目录内维度仍注入
        defaults.removeObject(forKey: "knowledge.embeddingProvider")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingProvider)
        XCTAssertEqual(config.embeddingDimension, 1536)
    }

    func testResolvedConfigurationDimensionGuardDashScopeCustomModelPassesPositiveDimensionThrough() {
        let defaults = makeIsolatedDefaults()
        defaults.set("dashscope", forKey: "knowledge.embeddingProvider")
        defaults.set("my-custom-embedding", forKey: "knowledge.embeddingModel")

        defaults.set(512, forKey: "knowledge.embeddingDimension")
        var config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingDimension, 512)

        defaults.set(0, forKey: "knowledge.embeddingDimension")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)

        defaults.set(-1, forKey: "knowledge.embeddingDimension")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)

        defaults.removeObject(forKey: "knowledge.embeddingDimension")
        config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)
    }

    func testResolvedConfigurationDimensionGuardKeepsLegacyDropWhenModelMissing() {
        // 模型缺省时 Python 端按默认预设模型运行:保持升级前行为,不注入维度。
        let defaults = makeIsolatedDefaults()
        defaults.set("dashscope", forKey: "knowledge.embeddingProvider")
        defaults.set(1536, forKey: "knowledge.embeddingDimension")

        let config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertNil(config.embeddingDimension)
    }

    func testResolvedConfigurationDimensionGuardOpenAIIgnoresCatalogEvenForPresetNames() {
        let defaults = makeIsolatedDefaults()
        defaults.set("openai", forKey: "knowledge.embeddingProvider")
        defaults.set("text-embedding-v4", forKey: "knowledge.embeddingModel")
        defaults.set(999, forKey: "knowledge.embeddingDimension")

        let config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: [:], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingDimension, 999)
    }

    func testResolvedConfigurationEnvironmentDimensionOverridesUserDefaults() {
        let defaults = makeIsolatedDefaults()
        defaults.set("openai", forKey: "knowledge.embeddingProvider")
        defaults.set(1536, forKey: "knowledge.embeddingDimension")

        let config = KnowledgeServiceManager.resolvedKnowledgeConfiguration(
            environment: ["EMBEDDING_DIMENSION": "256"], dotenv: [:], defaults: defaults, credentialStore: StubKnowledgeCredentialStore()
        )
        XCTAssertEqual(config.embeddingDimension, 256)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "KnowledgeServiceManagerTests.\(UUID().uuidString)")!
    }

    func testSupportedHealthRequiresExpectedVersions() {
        XCTAssertTrue(KnowledgeServiceManager.isSupportedHealth(
            .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1)
        ))
        XCTAssertFalse(KnowledgeServiceManager.isSupportedHealth(
            .init(status: "ok", apiVersion: "1.0", serviceVersion: "0.9.0", indexVersion: 1)
        ))
    }

    func testKnowledgeAgentMainIsResolvedFromDependencyResourceBundle() {
        let main = KnowledgeServiceManager.bundledMainURL
        XCTAssertNotNil(main)
        XCTAssertTrue(FileManager.default.fileExists(atPath: main?.path ?? ""))
    }

    func testReleaseRuntimeResolvesPackagedExecutableAtFixedResourcePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("KnowledgeAgent/knowledge-agent")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(KnowledgeServiceManager.releaseExecutableURL(resourceRoot: root), executable)
    }

    func testDevelopmentLaunchUsesBundledMainAndConfiguredPython() throws {
        let root = KnowledgeServiceManager.developmentProjectRootURL
        let bundledMain = try XCTUnwrap(KnowledgeServiceManager.bundledMainURL)
        let launch = KnowledgeServiceManager.developmentLaunchConfiguration(
            projectRoot: root,
            mainURL: bundledMain,
            configuredPython: "/bin/echo"
        )
        XCTAssertEqual(launch?.executable.path, "/bin/echo")
        XCTAssertEqual(launch?.arguments, [bundledMain.path])
    }

    @MainActor
    func testStartupGateCoalescesConcurrentCalls() async {
        let gate = KnowledgeStartupGate()
        var starts = 0
        async let first = gate.run {
            starts += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }
        async let second = gate.run {
            starts += 1
            return true
        }
        let results = await (first, second)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testInvalidatedStartupCannotClearNewerStartupTask() async {
        let gate = KnowledgeStartupGate()
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        var starts = 0
        var firstContinuation: CheckedContinuation<Bool, Never>?
        var secondContinuation: CheckedContinuation<Bool, Never>?

        let first = Task {
            await gate.run {
                starts += 1
                firstStarted.fulfill()
                return await withCheckedContinuation { firstContinuation = $0 }
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        gate.invalidate()

        let second = Task {
            await gate.run {
                starts += 1
                secondStarted.fulfill()
                return await withCheckedContinuation { secondContinuation = $0 }
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)

        firstContinuation?.resume(returning: true)
        _ = await first.value
        let third = Task {
            await gate.run {
                starts += 1
                return true
            }
        }
        await Task.yield()
        XCTAssertEqual(starts, 2)

        secondContinuation?.resume(returning: true)
        let secondResult = await second.value
        let thirdResult = await third.value
        XCTAssertTrue(secondResult)
        XCTAssertTrue(thirdResult)
        XCTAssertEqual(starts, 2)
    }

    @MainActor
    func testStopInvalidatesSuspendedStartupBeforeItCanLaunchAgain() async throws {
        let healthCalled = expectation(description: "health called")
        let client = SuspendedKnowledgeClient { healthCalled.fulfill() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        var launchAttempts = 0
        let manager = KnowledgeServiceManager(
            client: client,
            ownedProcess: process,
            onProcessLaunchAttempt: { launchAttempts += 1 }
        )
        let startup = Task { await manager.ensureServiceRunning() }
        await fulfillment(of: [healthCalled], timeout: 1)

        manager.stopService()
        client.resumeHealthy()
        let result = await startup.value

        XCTAssertFalse(result)
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(launchAttempts, 0)
    }

    @MainActor
    func testStopPermanentlyRejectsFutureStartRequests() async {
        var launchAttempts = 0
        let manager = KnowledgeServiceManager(onProcessLaunchAttempt: { launchAttempts += 1 })

        manager.stopService()
        let result = await manager.ensureServiceRunning()

        XCTAssertFalse(result)
        XCTAssertEqual(launchAttempts, 0)
    }

    @MainActor
    func testRestartServiceWithoutRunningProcessMakesNoStartAttempt() async {
        var launchAttempts = 0
        let manager = KnowledgeServiceManager(onProcessLaunchAttempt: { launchAttempts += 1 })

        await manager.restartService()

        XCTAssertEqual(launchAttempts, 0)
        XCTAssertFalse(manager.isRunning)
    }

    @MainActor
    func testWaitForExitReturnsAfterTerminatedProcessExits() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        process.terminate()
        await KnowledgeServiceManager.waitForExit(of: process)
        XCTAssertFalse(process.isRunning)
    }

    // MARK: - Stale backend eviction

    /// 外部进程占用端口时,killListenersOnPort 必须将其逐出并释放端口,
    /// 之后新的服务进程才能绑定同一端口启动。
    func testKillListenersOnPortEvictsExternalListenerAndFreesThePort() async throws {
        guard let python = Self.listenerPythonPath() else {
            throw XCTSkip("python3 is required to simulate a foreign listener")
        }
        let port = Self.freeListenerPort()
        let occupier = try Self.startHTTPListener(python: python, on: port)
        defer { if occupier.isRunning { occupier.terminate() } }

        let appeared = await Self.waitForListener(on: port)
        XCTAssertTrue(appeared, "external listener failed to start; cannot exercise eviction")
        XCTAssertFalse(KnowledgeServiceManager.pidsListeningOnPort(port).isEmpty)

        let evicted = await KnowledgeServiceManager.killListenersOnPort(port)
        XCTAssertTrue(evicted)
        XCTAssertTrue(KnowledgeServiceManager.pidsListeningOnPort(port).isEmpty, "port should be released after eviction")
        await KnowledgeServiceManager.waitForExit(of: occupier)
        XCTAssertFalse(occupier.isRunning, "external listener should be terminated by SIGTERM")

        // 端口已释放:新的进程能立即绑定同一端口(等价于 app 自己的服务能启动)。
        let replacement = try Self.startHTTPListener(python: python, on: port)
        defer { if replacement.isRunning { replacement.terminate() } }
        let rebound = await Self.waitForListener(on: port)
        XCTAssertTrue(rebound, "a service must be able to bind the port after eviction")
    }

    func testKillListenersOnPortIsNoOpWhenPortIsFree() async {
        let port = Self.freeListenerPort()
        XCTAssertTrue(KnowledgeServiceManager.pidsListeningOnPort(port).isEmpty)

        let evicted = await KnowledgeServiceManager.killListenersOnPort(port)

        XCTAssertFalse(evicted, "no eviction (and no eviction log) should happen on a free port")
    }

    /// 本实例拉起的健康子进程必须走复用路径:不重新启动、不逐出、进程不被误杀。
    @MainActor
    func testHealthyOwnedProcessIsReusedInsteadOfEvicted() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        var launchAttempts = 0
        let manager = KnowledgeServiceManager(
            client: HealthyKnowledgeClient(),
            ownedProcess: process,
            onProcessLaunchAttempt: { launchAttempts += 1 }
        )

        let result = await manager.ensureServiceRunning()

        XCTAssertTrue(result)
        XCTAssertTrue(manager.isRunning)
        XCTAssertEqual(launchAttempts, 0, "healthy owned process must be reused, not restarted")
        XCTAssertTrue(process.isRunning, "healthy owned process must not be killed")
    }

    private static func listenerPythonPath() -> String? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: candidate)
            probe.arguments = ["--version"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            guard (try? probe.run()) != nil else { continue }
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return candidate }
        }
        return nil
    }

    private static func freeListenerPort() -> Int {
        for _ in 0..<50 {
            let port = Int.random(in: 30_000...60_000)
            if KnowledgeServiceManager.pidsListeningOnPort(port).isEmpty {
                return port
            }
        }
        return 59_187
    }

    private static func startHTTPListener(python: String, on port: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func waitForListener(on port: Int) async -> Bool {
        for _ in 0..<50 {
            if !KnowledgeServiceManager.pidsListeningOnPort(port).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

private struct StubKnowledgeCredentialStore: KnowledgeCredentialLoading {
    var dashScope = ""
    var embedding = ""
    var rerank = ""
    var strictEmbedding = ""
    var strictRerank = ""

    func dashScopeAPIKey() -> String { dashScope }
    func embeddingAPIKey() -> String { embedding }
    func rerankAPIKey() -> String { rerank }
    func strictEmbeddingAPIKey() -> String { strictEmbedding }
    func strictRerankAPIKey() -> String { strictRerank }
}

/// 健康桩:health 返回本构建期望的版本,驱动 ensureServiceRunning 走复用路径。
private struct HealthyKnowledgeClient: KnowledgeClientProtocol {
    func health() async throws -> KnowledgeHealthDTO {
        .init(
            status: "ok",
            apiVersion: "1.0",
            serviceVersion: KnowledgeServiceManager.expectedServiceVersion,
            indexVersion: 1
        )
    }

    func status() async throws -> KnowledgeStatusDTO { throw KnowledgeClientError.network }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { throw KnowledgeClientError.network }
    func delete(recordingId _: UUID) async throws { throw KnowledgeClientError.network }
    func query(_: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: KnowledgeClientError.network) }
    }
    func retryFailed() async throws { throw KnowledgeClientError.network }
    func resetIndex() async throws { throw KnowledgeClientError.network }
}

private final class SuspendedKnowledgeClient: KnowledgeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let onHealthCalled: @Sendable () -> Void
    private var healthContinuation: CheckedContinuation<KnowledgeHealthDTO, Never>?

    init(onHealthCalled: @escaping @Sendable () -> Void) {
        self.onHealthCalled = onHealthCalled
    }

    func health() async throws -> KnowledgeHealthDTO {
        onHealthCalled()
        return await withCheckedContinuation { continuation in
            lock.lock()
            healthContinuation = continuation
            lock.unlock()
        }
    }

    func resumeHealthy() {
        lock.lock()
        let continuation = healthContinuation
        healthContinuation = nil
        lock.unlock()
        continuation?.resume(returning: .init(status: "ok", apiVersion: "1.0", serviceVersion: KnowledgeServiceManager.expectedServiceVersion, indexVersion: 1))
    }

    func status() async throws -> KnowledgeStatusDTO { throw KnowledgeClientError.network }
    func upsert(_: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse { throw KnowledgeClientError.network }
    func delete(recordingId _: UUID) async throws { throw KnowledgeClientError.network }
    func query(_: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: KnowledgeClientError.network) }
    }
    func retryFailed() async throws { throw KnowledgeClientError.network }
    func resetIndex() async throws { throw KnowledgeClientError.network }
}
