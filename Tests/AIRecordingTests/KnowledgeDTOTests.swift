import CoreData
import XCTest
@testable import AIRecording

final class KnowledgeDTOTests: XCTestCase {
    func testRecordingRequestDropsBlankSegments() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.title = "测试录音"
        recording.createdAt = Date(timeIntervalSince1970: 0)
        let transcription = Transcription(context: context)
        recording.transcription = transcription

        let blank = TranscriptionSegment(context: context)
        blank.id = UUID()
        blank.sequence = 0
        blank.text = "  \n"
        let useful = TranscriptionSegment(context: context)
        useful.id = UUID()
        useful.sequence = 1
        useful.startTime = 1
        useful.endTime = 3
        useful.text = " 张伟负责上线 "
        transcription.segments = [blank, useful]

        let request = try XCTUnwrap(KnowledgeRecordingRequest.make(recording: recording))
        XCTAssertEqual(request.segments.map(\.text), ["张伟负责上线"])
        XCTAssertEqual(request.indexVersion, 1)
        XCTAssertEqual(request.recordingId, recording.id)
    }

    func testQueryRequestCapsHistoryAtSixCompletedMessages() {
        let messages = (0..<8).map { KnowledgeHistoryMessageDTO(role: .user, content: "m\($0)") }
        let request = KnowledgeQueryRequest(
            requestId: UUID(), sessionId: UUID(), query: "问题", history: messages
        )
        XCTAssertEqual(request.history.count, 6)
        XCTAssertEqual(request.history.map(\.content), ["m2", "m3", "m4", "m5", "m6", "m7"])
    }

    func testRecordingRequestRejectsMissingPersistedRecordingOrSegmentIDs() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let recording = Recording(context: context)
        recording.createdAt = Date(timeIntervalSince1970: 0)
        XCTAssertNil(KnowledgeRecordingRequest.make(recording: recording))

        recording.id = UUID()
        let transcription = Transcription(context: context)
        recording.transcription = transcription
        let segment = TranscriptionSegment(context: context)
        segment.sequence = 0
        segment.text = "内容"
        transcription.segments = [segment]
        XCTAssertNil(KnowledgeRecordingRequest.make(recording: recording))
    }

    func testRecordingRequestIsStableAndNormalizesOuterSummaryFence() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.createdAt = Date(timeIntervalSince1970: 0)
        let transcription = Transcription(context: context)
        transcription.summary = "  ```markdown\n# 会议纪要\n\n张伟负责上线。\n```  "
        recording.transcription = transcription
        let segment = TranscriptionSegment(context: context)
        segment.id = UUID()
        segment.sequence = 0
        segment.text = "张伟负责上线。"
        transcription.segments = [segment]

        let first = try XCTUnwrap(KnowledgeRecordingRequest.make(recording: recording))
        let second = try XCTUnwrap(KnowledgeRecordingRequest.make(recording: recording))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.summaryMarkdown, "# 会议纪要\n\n张伟负责上线。")
        XCTAssertEqual(first.summaryHash, second.summaryHash)
    }
}
