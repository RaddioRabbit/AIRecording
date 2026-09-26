import XCTest
@testable import AIRecording

final class AppLoggerTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempDirectories.append(directory)
        return directory
    }

    private func parsedLogLines(at url: URL) throws -> [[String: Any]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content
            .split(whereSeparator: \.isNewline)
            .map { line in
                let data = Data(line.utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
    }

    // MARK: - File creation, appending, permissions

    func testFirstWriteCreatesDirectoryAndFileWithTightPermissions() throws {
        let directory = try makeTempDirectory().appendingPathComponent("Logs/AIRecording")
        let writer = FileLogWriter(directory: directory, fileName: "app.log")
        writer.write(#"{"hello":"world"}"#)
        writer.synchronize()

        let logURL = directory.appendingPathComponent("app.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o700)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o600)

        let lines = try parsedLogLines(at: logURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["hello"] as? String, "world")
    }

    func testSecondWriterAppendsInsteadOfOverwriting() throws {
        let directory = try makeTempDirectory()
        let logURL = directory.appendingPathComponent("app.log")

        let first = FileLogWriter(directory: directory, fileName: "app.log")
        first.write(#"{"run":1}"#)
        first.synchronize()

        // Simulates an app restart: a brand new writer over the same file.
        let second = FileLogWriter(directory: directory, fileName: "app.log")
        second.write(#"{"run":2}"#)
        second.synchronize()

        let lines = try parsedLogLines(at: logURL)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["run"] as? Int, 1)
        XCTAssertEqual(lines[1]["run"] as? Int, 2)
    }

    func testExistingWidePermissionsAreTightened() throws {
        let directory = try makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path)

        _ = FileLogWriter(directory: directory, fileName: "app.log")

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o600)
    }

    // MARK: - Concurrent writes

    func testConcurrentWritesProduceCompleteJSONLines() throws {
        let directory = try makeTempDirectory()
        let logURL = directory.appendingPathComponent("app.log")
        let writer = FileLogWriter(directory: directory, fileName: "app.log")

        let writeCount = 200
        DispatchQueue.concurrentPerform(iterations: writeCount) { index in
            writer.write("{\"index\":\(index)}")
        }
        writer.synchronize()

        let lines = try parsedLogLines(at: logURL)
        XCTAssertEqual(lines.count, writeCount)
        let indices = Set(lines.compactMap { $0["index"] as? Int })
        XCTAssertEqual(indices.count, writeCount)
    }

    // MARK: - Levels

    func testAllFiveLevelsEncode() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)

        for level in LogLevel.allCases {
            AppLogger.log(level, category: "test", event: "level_\(level.rawValue)")
        }
        AppLogger.synchronizeForTesting()

        let lines = try parsedLogLines(at: directory.appendingPathComponent("app.log"))
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(
            lines.compactMap { $0["level"] as? String }.sorted(),
            ["critical", "debug", "error", "info", "warning"]
        )
        for line in lines {
            XCTAssertEqual(line["process"] as? String, "app")
            XCTAssertEqual(line["category"] as? String, "test")
            XCTAssertNotNil(line["ts"])
            XCTAssertNotNil(line["event"])
        }
    }

    func testLevelFilteringRule() {
        // Release default: info and above only.
        XCTAssertFalse(AppLogger.shouldLog(.debug, minimumLevel: .info))
        XCTAssertTrue(AppLogger.shouldLog(.info, minimumLevel: .info))
        XCTAssertTrue(AppLogger.shouldLog(.critical, minimumLevel: .info))
        // Debug default: everything.
        XCTAssertTrue(AppLogger.shouldLog(.debug, minimumLevel: .debug))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempDirectories.append(directory)
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .info)
        AppLogger.log(.debug, category: "test", event: "debug_only")
        AppLogger.log(.info, category: "test", event: "info_event")
        AppLogger.synchronizeForTesting()

        let lines = (try? parsedLogLines(at: directory.appendingPathComponent("app.log"))) ?? []
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["event"] as? String, "info_event")
    }

    // MARK: - Rotation

    func testRotationHappensBeforeExceedingTheCap() throws {
        let directory = try makeTempDirectory()
        let logURL = directory.appendingPathComponent("app.log")
        let writer = FileLogWriter(directory: directory, fileName: "app.log", maxFileSize: 100)

        // 60 bytes each; the second write would exceed 100 and must rotate first.
        let line = String(repeating: "a", count: 59)
        writer.write(line)
        writer.write(line)
        writer.synchronize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("app.1.log").path))
        let current = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(current, line + "\n")
    }

    func testRepeatedRotationsKeepBoundedCopiesInOrder() throws {
        let directory = try makeTempDirectory()
        let logURL = directory.appendingPathComponent("app.log")
        let writer = FileLogWriter(directory: directory, fileName: "app.log", maxFileSize: 10)

        for marker in ["one", "two", "three", "four"] {
            writer.write("\"\(marker)\"")
            writer.synchronize()
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["app.1.log", "app.2.log", "app.log"])
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "\"four\"\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("app.1.log"), encoding: .utf8), "\"three\"\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("app.2.log"), encoding: .utf8), "\"two\"\n")
    }

    func testAppAndChartAgentRotationAreIndependent() throws {
        let directory = try makeTempDirectory()
        let appWriter = FileLogWriter(directory: directory, fileName: "app.log", maxFileSize: 10)
        let chartWriter = FileLogWriter(directory: directory, fileName: "chart-agent.log", maxFileSize: 10 * 1024 * 1024)

        appWriter.write(String(repeating: "a", count: 20))
        appWriter.write(String(repeating: "b", count: 20))
        appWriter.synchronize()
        chartWriter.write(#"{"chart":1}"#)
        chartWriter.synchronize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("app.1.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chart-agent.1.log").path))
        let chartLines = try parsedLogLines(at: directory.appendingPathComponent("chart-agent.log"))
        XCTAssertEqual(chartLines.count, 1)
    }

    // MARK: - Sanitizer

    func testSanitizerRedactsCredentialsAndTruncates() {
        let message = "failed Bearer abc.def.ghi sk-1234567890abcdef api_key=supersecret https://oss.example.com/f.wav?Signature=deadbeef&Expires=9999"
        let sanitized = LogSanitizer.sanitizeMessage(message)
        XCTAssertFalse(sanitized.contains("abc.def.ghi"))
        XCTAssertFalse(sanitized.contains("sk-1234567890abcdef"))
        XCTAssertFalse(sanitized.contains("supersecret"))
        XCTAssertFalse(sanitized.contains("deadbeef"))

        let providerKey = LogSanitizer.sanitizeMessage("DASHSCOPE_API_KEY=dash-secret OPENAI_API_KEY=openai-secret")
        XCTAssertFalse(providerKey.contains("dash-secret"))
        XCTAssertFalse(providerKey.contains("openai-secret"))

        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(LogSanitizer.sanitizeMessage(long).count, 200)
    }

    func testSanitizerKeepsOnlyScalarMetadata() {
        let sanitized = LogSanitizer.sanitizeMetadata([
            "count": 3,
            "ratio": 0.5,
            "ok": true,
            "name": "value",
            "nested": ["a": 1],
            "date": Date(),
        ])
        XCTAssertEqual(sanitized.count, 4)
        XCTAssertNil(sanitized["nested"])
        XCTAssertNil(sanitized["date"])
    }

    func testSanitizerRedactsKnowledgeQueryLikeFieldsAndFixtureSecrets() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)
        let question = "最终由谁负责上线协调？"
        let answer = "最终由张伟负责上线协调，后续会议已确认。"
        let title = "产品发布协调会"
        let speaker = "张伟"
        let segment = "本次发布由张伟负责上线协调。"
        let dashSecret = "dashscope-fixture-secret"
        let openAISecret = "openai-fixture-secret"

        AppLogger.log(
            .info,
            category: "knowledge",
            event: "fixture_privacy",
            message: "query=\(question) answer=\(answer) title=\(title) speaker=\(speaker) segment=\(segment) DASHSCOPE_API_KEY=\(dashSecret) OPENAI_API_KEY=\(openAISecret)",
            metadata: ["query": question, "answer": answer, "title": title, "speakerName": speaker, "segmentText": segment]
        )
        AppLogger.synchronizeForTesting()

        let raw = try String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8)
        for privateValue in [question, answer, title, speaker, segment, dashSecret, openAISecret] {
            XCTAssertFalse(raw.contains(privateValue))
        }
    }

    func testKnowledgeAgentIngestionNeverPersistsUnstructuredOutput() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)
        AppLogger.ingestKnowledgeAgentLine("用户转写内容和 dash-secret", isError: true)
        AppLogger.synchronizeForTesting()

        let lines = try parsedLogLines(at: directory.appendingPathComponent("knowledge-agent.log"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["event"] as? String, "process_unstructured_output")
        XCTAssertNil(lines[0]["message"])
    }

    func testAppLoggerNeverWritesRawRecordingIdOrSecrets() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)

        let rawId = "550e8400-e29b-41d4-a716-446655440000"
        AppLogger.log(.info, category: "transcription", event: "transcription_started",
                      correlationId: "corr-1", recordingId: rawId,
                      message: "开始转录 Bearer abc.def.ghi", durationMs: 12.5,
                      metadata: ["segmentCount": 7])
        AppLogger.synchronizeForTesting()

        let logURL = directory.appendingPathComponent("app.log")
        let raw = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(rawId))
        XCTAssertFalse(raw.contains("abc.def.ghi"))

        let lines = try parsedLogLines(at: logURL)
        let record = try XCTUnwrap(lines.first)
        XCTAssertEqual(record["recording"] as? String, AppLogger.recordingHash(rawId))
        XCTAssertEqual(record["correlationId"] as? String, "corr-1")
        XCTAssertEqual(record["durationMs"] as? Double, 12.5)
        XCTAssertEqual((record["metadata"] as? [String: Any])?["segmentCount"] as? Int, 7)
    }

    // MARK: - Failure resilience

    func testUnwritableTargetDoesNotFailCaller() throws {
        // Point the writer at a path whose parent is a regular file, so
        // directory creation must fail.
        let blockingFile = try makeTempDirectory().appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: blockingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blockingFile)
        let directory = blockingFile.appendingPathComponent("Logs")

        let writer = FileLogWriter(directory: directory, fileName: "app.log")
        // Writes must no-op instead of throwing or crashing the caller.
        writer.write(#"{"after":"failure"}"#)
        writer.synchronize()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("app.log").path))
    }

    // MARK: - Subprocess output ingestion

    func testNonJSONSubprocessOutputIsWrapped() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)

        AppLogger.ingestChartAgentLine("just a plain stdout line", isError: false)
        AppLogger.ingestChartAgentLine("Traceback (most recent call last)", isError: true)
        AppLogger.synchronizeForTesting()

        let lines = try parsedLogLines(at: directory.appendingPathComponent("chart-agent.log"))
        XCTAssertEqual(lines.count, 2)

        let output = lines[0]
        XCTAssertEqual(output["event"] as? String, "process_output")
        XCTAssertEqual(output["level"] as? String, "info")
        XCTAssertEqual(output["process"] as? String, "chart-agent")
        XCTAssertEqual(output["category"] as? String, "process")
        XCTAssertEqual(output["message"] as? String, "just a plain stdout line")

        let error = lines[1]
        XCTAssertEqual(error["event"] as? String, "process_error")
        XCTAssertEqual(error["level"] as? String, "error")
    }

    func testStructuredSubprocessOutputPassesThroughWithSecondSanitize() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)

        let pythonLine = #"{"ts":"2026-07-18T10:30:25.123Z","level":"info","process":"chart-agent","category":"chart","event":"request_finished","correlationId":"req-7","message":"done sk-1234567890abcdef"}"#
        AppLogger.ingestChartAgentLine(pythonLine, isError: false)
        AppLogger.synchronizeForTesting()

        let logURL = directory.appendingPathComponent("chart-agent.log")
        let raw = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-1234567890abcdef"))

        let lines = try parsedLogLines(at: logURL)
        let record = try XCTUnwrap(lines.first)
        XCTAssertEqual(record["event"] as? String, "request_finished")
        XCTAssertEqual(record["correlationId"] as? String, "req-7")
        XCTAssertEqual(record["process"] as? String, "chart-agent")
    }

    func testSameCorrelationIdCanBeTracedAcrossBothFiles() throws {
        let directory = try makeTempDirectory()
        AppLogger.useLogDirectoryForTesting(directory, minimumLevel: .debug)

        AppLogger.log(.info, category: "chart", event: "chart_generate_requested", correlationId: "req-42")
        AppLogger.ingestChartAgentLine(
            #"{"ts":"2026-07-18T10:30:25.123Z","level":"info","process":"chart-agent","category":"chart","event":"request_received","correlationId":"req-42"}"#,
            isError: false
        )
        AppLogger.synchronizeForTesting()

        let appLines = try parsedLogLines(at: directory.appendingPathComponent("app.log"))
        let chartLines = try parsedLogLines(at: directory.appendingPathComponent("chart-agent.log"))
        XCTAssertEqual(appLines.first?["correlationId"] as? String, "req-42")
        XCTAssertEqual(chartLines.first?["correlationId"] as? String, "req-42")
    }
}
