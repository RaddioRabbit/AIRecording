import CryptoKit
import Foundation
import OSLog

/// The five log levels, ordered by severity. Debug builds write all of them;
/// Release builds start at `info` (design §6.3).
enum LogLevel: String, CaseIterable, Comparable {
    case debug, info, warning, error, critical

    private var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .critical: return 4
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// Log file targets. Each process writes only its own file (design §4).
enum LogTarget: String {
    case app = "app.log"
    case chartAgent = "chart-agent.log"
    case knowledgeAgent = "knowledge-agent.log"

    var processName: String {
        switch self {
        case .app: return "app"
        case .chartAgent: return "chart-agent"
        case .knowledgeAgent: return "knowledge-agent"
        }
    }
}

/// The single logging entry point for Swift production code. Builds the common
/// JSON record, hashes raw recording ids, runs the sanitizer, and hands the
/// line to a `FileLogWriter` asynchronously. File logging failures degrade to
/// Unified Logging and are never thrown to business code.
enum AppLogger {

    // MARK: - Configuration

    #if DEBUG
    static let defaultMinimumLevel: LogLevel = .debug
    #else
    static let defaultMinimumLevel: LogLevel = .info
    #endif

    /// Pure level filter, kept separate so the Release rule is testable on its own.
    static func shouldLog(_ level: LogLevel, minimumLevel: LogLevel) -> Bool {
        level >= minimumLevel
    }

    /// Separate Unified Logging logger used only to report internal logging
    /// failures — deliberately not routed back through AppLogger.
    private static let fallbackLogger = Logger(subsystem: "com.airecording.app", category: "logging")

    /// Mutable state lives behind a lock so AppLogger can be called from any
    /// thread (including the audio real-time path) without blocking it.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        var writers: [LogTarget: FileLogWriter] = [:]
        var directoryOverride: URL?
        var minimumLevel: LogLevel = AppLogger.defaultMinimumLevel
        var reportedDegradations = Set<LogTarget>()

        func withLock<T>(_ body: (Registry) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }
    private static let registry = Registry()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var logDirectory: URL {
        if let override = registry.withLock({ $0.directoryOverride }) {
            return override
        }
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/AIRecording")
    }

    // MARK: - Public API

    static func log(
        _ level: LogLevel,
        category: String,
        event: String,
        correlationId: String? = nil,
        recordingId: String? = nil,
        message: String? = nil,
        durationMs: Double? = nil,
        errorCode: String? = nil,
        metadata: [String: Any]? = nil,
        process: LogTarget = .app
    ) {
        let minimumLevel = registry.withLock { $0.minimumLevel }
        guard shouldLog(level, minimumLevel: minimumLevel) else { return }

        var record: [String: Any] = [
            "ts": timestampFormatter.string(from: Date()),
            "level": level.rawValue,
            "process": process.processName,
            "category": category,
            "event": event,
        ]
        if let correlationId { record["correlationId"] = correlationId }
        if let recordingId { record["recording"] = recordingHash(recordingId) }
        if let message { record["message"] = LogSanitizer.sanitizeMessage(message) }
        if let durationMs { record["durationMs"] = durationMs }
        if let errorCode { record["errorCode"] = errorCode }
        if let metadata {
            let sanitized = LogSanitizer.sanitizeMetadata(metadata)
            if !sanitized.isEmpty { record["metadata"] = sanitized }
        }

        writeRecord(record, to: process)
    }

    /// Ingests one line of chart-agent subprocess output. Lines that already
    /// carry the common JSON structure are sanitized a second time and written
    /// as-is; anything else is wrapped into a `process_output` / `process_error`
    /// event. Never fails — file errors still allow the caller to keep draining
    /// the pipe so the Python process cannot block on a full buffer.
    nonisolated static func ingestChartAgentLine(_ line: String, isError: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           parsed["ts"] != nil, parsed["level"] != nil, parsed["event"] != nil {
            let level = (parsed["level"] as? String).flatMap { LogLevel(rawValue: $0) } ?? .info
            let minimumLevel = registry.withLock { $0.minimumLevel }
            guard shouldLog(level, minimumLevel: minimumLevel) else { return }
            writeRecord(LogSanitizer.sanitizeRecord(parsed), to: .chartAgent)
            return
        }

        log(
            isError ? .error : .info,
            category: "process",
            event: isError ? "process_error" : "process_output",
            message: trimmed,
            process: .chartAgent
        )
    }

    /// Accepts only the KnowledgeAgent's fixed structured observability schema.
    /// Raw subprocess lines are deliberately never persisted because they can
    /// contain transcript text, prompts, answers, or credentials.
    nonisolated static func ingestKnowledgeAgentLine(_ line: String, isError: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEvent = parsed["event"] as? String,
              rawEvent.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil else {
            log(
                isError ? .error : .warning,
                category: "knowledge-agent",
                event: "process_unstructured_output",
                errorCode: "UNSTRUCTURED_OUTPUT",
                process: .knowledgeAgent
            )
            return
        }
        let level = (parsed["level"] as? String).flatMap(LogLevel.init(rawValue:)) ?? (isError ? .error : .info)
        let minimumLevel = registry.withLock { $0.minimumLevel }
        guard shouldLog(level, minimumLevel: minimumLevel) else { return }

        var record: [String: Any] = [
            "ts": timestampFormatter.string(from: Date()),
            "level": level.rawValue,
            "process": LogTarget.knowledgeAgent.processName,
            "category": "knowledge-agent",
            "event": rawEvent,
        ]
        if let correlationId = parsed["correlationId"] as? String,
           correlationId.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil {
            record["correlationId"] = correlationId
        }
        if let errorCode = parsed["errorCode"] as? String,
           errorCode.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil {
            record["errorCode"] = errorCode
        }
        if let duration = parsed["durationMs"] as? NSNumber { record["durationMs"] = duration }
        if let metadata = parsed["metadata"] as? [String: Any] {
            let allowed = Set(["model", "candidateCount", "sourceCount", "statusCode"])
            let safe = LogSanitizer.sanitizeMetadata(metadata).filter { allowed.contains($0.key) }
            if !safe.isEmpty { record["metadata"] = safe }
        }
        writeRecord(record, to: .knowledgeAgent)
    }

    /// sha256 prefix of a raw recording id; the raw id is never logged.
    static func recordingHash(_ recordingId: String) -> String {
        let digest = SHA256.hash(data: Data(recordingId.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    // MARK: - Testing hooks

    /// Redirects all writers to a temporary directory. Test-only.
    static func useLogDirectoryForTesting(_ url: URL, minimumLevel: LogLevel = .debug) {
        registry.withLock {
            $0.directoryOverride = url
            $0.writers = [:]
            $0.minimumLevel = minimumLevel
            $0.reportedDegradations = []
        }
    }

    static func synchronizeForTesting() {
        registry.withLock { Array($0.writers.values) }.forEach { $0.synchronize() }
    }

    // MARK: - Private

    private static func writeRecord(_ record: [String: Any], to target: LogTarget) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            reportDegradation("encode", target: target)
            return
        }
        writer(for: target).write(line)
    }

    private static func writer(for target: LogTarget) -> FileLogWriter {
        let directory = logDirectory
        return registry.withLock {
            if let writer = $0.writers[target] { return writer }
            let writer = FileLogWriter(directory: directory, fileName: target.rawValue)
            writer.onFailure = { kind in
                reportDegradation(kind, target: target)
            }
            $0.writers[target] = writer
            return writer
        }
    }

    private static func reportDegradation(_ kind: String, target: LogTarget) {
        let shouldReport = registry.withLock { $0.reportedDegradations.insert(target).inserted }
        guard shouldReport else { return }
        fallbackLogger.error("File logging degraded for \(target.rawValue, privacy: .public): \(kind, privacy: .public)")
    }
}
