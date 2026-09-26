import Foundation
import SwiftUI

@MainActor
class ChartServiceManager: ObservableObject {
    static let shared = ChartServiceManager()

    /// Backend build this app ships. Bump together with ChartAgent/main.py's
    /// SERVICE_VERSION so a stale backend is detected and replaced.
    nonisolated static let expectedServiceVersion = "5.0.0"

    @Published private(set) var isRunning = false
    @Published private(set) var lastHeartbeat: Date?

    private let servicePort = 8765
    private let serviceHost = "127.0.0.1"
    private var heartbeatTimer: Timer?
    private var process: Process?

    nonisolated static var bundledScriptURL: URL? {
        Bundle.module.url(forResource: "main", withExtension: "py")
    }

    /// Rotates the log file when it exceeds `maxBytes`, keeping at most `keep` files
    /// (the current log plus `keep - 1` numbered copies: `chart-agent.1.log`, ...).
    /// The oldest copy is dropped, the rest shift up, and the current log becomes `.1`.
    /// Does nothing when the file is missing or below the size limit.
    nonisolated static func rotateLogIfNeeded(
        at url: URL,
        maxBytes: Int = 5 * 1024 * 1024,
        keep: Int = 3
    ) {
        LogRotator.rotateIfNeeded(at: url, maxBytes: maxBytes, keep: keep)
    }

    /// Opens the log file for appending, creating it when missing and seeking to the
    /// end so restarts never overwrite earlier log content.
    nonisolated static func openAppendingLogHandle(at url: URL) -> FileHandle? {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = handle.seekToEndOfFile()
        return handle
    }

    nonisolated static func serviceEnvironment(
        from parentEnvironment: [String: String],
        port: Int,
        llmConfiguration: [String: String] = [:]
    ) -> [String: String] {
        var environment = parentEnvironment
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "LLM_MODEL", "OLLAMA_MODEL"] {
            if (environment[key] ?? "").isEmpty,
               let configuredValue = llmConfiguration[key],
               !configuredValue.isEmpty {
                environment[key] = configuredValue
            }
        }
        environment["PORT"] = String(port)
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// A backend is usable only when it speaks the v5 protocol AND runs the
    /// same service build this app ships; anything else is stale and must be
    /// replaced (see ensureServiceRunning).
    nonisolated static func isSupportedHealth(_ health: ChartHealthInfo) -> Bool {
        health.status == "ok"
            && health.apiVersion == "5.0"
            && health.serviceVersion == expectedServiceVersion
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
    /// Used to evict stale or foreign backends before starting the bundled one.
    nonisolated static func killListenersOnPort(_ port: Int) async {
        let pids = pidsListeningOnPort(port)
        guard !pids.isEmpty else { return }
        for pid in pids {
            kill(pid, SIGTERM)
        }
        for _ in 0..<30 {
            if pidsListeningOnPort(port).isEmpty { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private init() {
        startHeartbeatMonitoring()
    }

    // MARK: - Service Control

    func ensureServiceRunning() async -> Bool {
        // Only reuse a backend this app instance spawned and that is still
        // alive. Anything else on the port (an orphan from a previous build,
        // or a foreign process) must not be adopted: its code may predate this
        // build while reporting the same serviceVersion.
        if let process, process.isRunning, await checkHealth() {
            await MainActor.run {
                isRunning = true
            }
            return true
        }

        // The port may be held by a stale or foreign backend (an older build,
        // or a process this app instance did not spawn). Evict it first,
        // otherwise the new process cannot bind.
        await Self.killListenersOnPort(servicePort)
        process = nil

        do {
            try startService()
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await checkHealth() {
                    await MainActor.run {
                        isRunning = true
                    }
                    return true
                }
            }
        } catch {
            AppLogger.log(.error, category: "process", event: "chart_service_start_failed",
                          errorCode: String(describing: error))
        }

        await MainActor.run {
            isRunning = false
        }
        return false
    }

    func stopService() {
        process?.terminate()
        process = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        isRunning = false
    }

    // MARK: - Private

    private func startService() throws {
        guard let pythonPath = findPythonPath() else {
            throw ChartSkillError.serviceUnavailable
        }
        let scriptPath = findScriptPath()

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ChartSkillError.serviceUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()
        let defaults = UserDefaults.standard
        let savedLLMConfiguration = [
            "OPENAI_API_KEY": defaults.string(forKey: "llm.apiKey") ?? "",
            "OPENAI_BASE_URL": defaults.string(forKey: "llm.baseURL") ?? "https://api.deepseek.com/v1",
            "LLM_MODEL": defaults.string(forKey: "llm.model") ?? "deepseek-v4-flash",
            "OLLAMA_MODEL": defaults.string(forKey: "llm.ollamaModel") ?? ""
        ]
        process.environment = Self.serviceEnvironment(
            from: ProcessInfo.processInfo.environment,
            port: servicePort,
            llmConfiguration: savedLLMConfiguration
        )

        // Capture stdout/stderr through pipes so log lines flow through the
        // sanitizing writer and the file can rotate while the service runs.
        let stdoutCapture = SubprocessLogCapture(name: "chart-agent-stdout") { line in
            AppLogger.ingestChartAgentLine(line, isError: false)
        }
        let stderrCapture = SubprocessLogCapture(name: "chart-agent-stderr") { line in
            AppLogger.ingestChartAgentLine(line, isError: true)
        }
        process.standardOutput = stdoutCapture.fileHandleForWriting
        process.standardError = stderrCapture.fileHandleForWriting

        try process.run()
        // Close the parent's copies of the write ends so the reads below reach
        // EOF when the child exits; the child keeps its own duplicates.
        try? stdoutCapture.fileHandleForWriting.close()
        try? stderrCapture.fileHandleForWriting.close()
        stdoutCapture.start()
        stderrCapture.start()
        // Drain whatever remains in the pipes before the captures are dropped.
        process.terminationHandler = { _ in
            stdoutCapture.finish()
            stderrCapture.finish()
        }
        self.process = process
        AppLogger.log(.info, category: "process", event: "chart_service_started")
    }

    private func checkHealth() async -> Bool {
        guard let url = URL(string: "http://\(serviceHost):\(servicePort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard httpResponse.statusCode == 200,
                  let health = try? JSONDecoder().decode(ChartHealthInfo.self, from: data) else {
                return false
            }
            return Self.isSupportedHealth(health)
        } catch {
            return false
        }
    }

    private func startHeartbeatMonitoring() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let healthy = await self.checkHealth()
                self.isRunning = healthy
                if healthy {
                    self.lastHeartbeat = Date()
                }
                // Restart on any unhealthy state: the listener may be a stale
                // build or a process this app instance never spawned.
                if !healthy {
                    _ = await self.ensureServiceRunning()
                }
            }
        }
    }

    // MARK: - Path Resolution

    private func findPythonPath() -> String? {
        if let configured = ProcessInfo.processInfo.environment["CHART_AGENT_PYTHON"],
           isUsablePython(at: configured) {
            return configured
        }

        if let bundled = Bundle.module.url(forResource: "python3", withExtension: nil)?.path,
           isUsablePython(at: bundled) {
            return bundled
        }

        // Prioritize user-installed Python distributions that are more likely
        // to have the required dependencies (fastapi, uvicorn, langgraph, openai).
        let candidates = [
            "/opt/anaconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if isUsablePython(at: path) {
                return path
            }
        }

        // Fallback: resolve via PATH using `which`
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["python3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0,
               let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty,
               isUsablePython(at: output) {
                return output
            }
        } catch {
            AppLogger.log(.warning, category: "process", event: "python_lookup_failed",
                          metadata: ["errorType": String(describing: type(of: error))])
        }

        return nil
    }

    private func isUsablePython(at path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: path)
        probe.arguments = [
            "-c",
            "import fastapi, uvicorn, langgraph, jinja2, pydantic"
        ]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func findScriptPath() -> String {
        if let bundledURL = Self.bundledScriptURL,
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL.path
        }

        // Development fallback for running outside SwiftPM's resource bundle.
        let execPath = Bundle.main.bundlePath
        let devPath = (execPath as NSString).appendingPathComponent("../ChartAgent/main.py")
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return ""
    }
}

/// Health payload shared by ChartServiceManager and HTTPChartSkill.
struct ChartHealthInfo: Decodable {
    let status: String
    let apiVersion: String
    let serviceVersion: String
}
