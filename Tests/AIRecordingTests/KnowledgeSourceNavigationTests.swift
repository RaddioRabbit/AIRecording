import CoreData
import XCTest
@testable import AIRecording

@MainActor
final class KnowledgeSourceNavigationTests: XCTestCase {
    private var persistence: PersistenceController!

    override func setUpWithError() throws {
        persistence = PersistenceController(inMemory: true)
    }

    func testResolverReturnsOnlyNonDeletedRecordingForURI() throws {
        let context = persistence.container.viewContext
        let recording = makeRecording(in: context, isDeleted: false)
        try context.save()

        let navigation = KnowledgeSourceNavigation(
            recordingObjectURI: recording.objectID.uriRepresentation(),
            segmentId: nil,
            startTime: 0
        )

        XCTAssertEqual(
            KnowledgeSourceNavigationResolver.recordingObjectID(for: navigation, in: context),
            recording.objectID
        )

        recording.isDeletedValue = true
        XCTAssertNil(KnowledgeSourceNavigationResolver.recordingObjectID(for: navigation, in: context))
    }

    func testSoftDeletedSourceBecomesUnavailable() {
        let context = persistence.container.viewContext
        let recording = makeRecording(in: context, isDeleted: false)
        let source = KnowledgeSourceLink(context: context)
        source.recordingId = recording.id
        source.startTime = 10

        XCTAssertNotNil(KnowledgeSourceNavigation.make(recording: recording, source: source))

        recording.isDeletedValue = true
        XCTAssertNil(KnowledgeSourceNavigation.make(recording: recording, source: source))
    }

    func testHighlightUsesSegmentIDWhenPresent() {
        let context = persistence.container.viewContext
        let recording = makeRecording(in: context, isDeleted: false)
        let transcription = Transcription(context: context)
        transcription.recording = recording
        let segment = TranscriptionSegment(context: context)
        segment.id = UUID()
        segment.sequence = 0
        segment.startTime = 12
        segment.endTime = 18
        segment.transcription = transcription

        let target = RecordingDetailViewModel.resolveSourceTarget(
            segmentID: segment.id,
            startTime: 99,
            segments: [segment]
        )

        XCTAssertEqual(target.segmentID, segment.id)
        XCTAssertEqual(target.seekTime, segment.startTime)
    }

    func testMissingSegmentFallsBackToSourceStartTime() {
        let target = RecordingDetailViewModel.resolveSourceTarget(
            segmentID: UUID(),
            startTime: 42,
            segments: []
        )

        XCTAssertNil(target.segmentID)
        XCTAssertEqual(target.seekTime, 42)
    }

    func testMissingCitedSegmentHighlightsContainingTranscriptSegmentButKeepsSourceTime() {
        let context = persistence.container.viewContext
        let recording = makeRecording(in: context, isDeleted: false)
        let transcription = Transcription(context: context)
        transcription.recording = recording
        let earlier = makeSegment(in: context, transcription: transcription, start: 10, end: 20, text: "第一个片段")
        let nearest = makeSegment(in: context, transcription: transcription, start: 30, end: 40, text: "第二个片段")

        let target = RecordingDetailViewModel.resolveSourceTarget(
            segmentID: UUID(),
            startTime: 15,
            segments: [earlier, nearest]
        )

        XCTAssertEqual(target.segmentID, earlier.id)
        XCTAssertEqual(target.seekTime, 15)
    }

    func testMissingCitedSegmentHighlightsNearestNonemptyTranscriptSegment() {
        let context = persistence.container.viewContext
        let recording = makeRecording(in: context, isDeleted: false)
        let transcription = Transcription(context: context)
        transcription.recording = recording
        let earlier = makeSegment(in: context, transcription: transcription, start: 10, end: 20, text: "较早片段")
        let nearest = makeSegment(in: context, transcription: transcription, start: 50, end: 60, text: "最近片段")

        let target = RecordingDetailViewModel.resolveSourceTarget(
            segmentID: UUID(),
            startTime: 45,
            segments: [earlier, nearest]
        )

        XCTAssertEqual(target.segmentID, nearest.id)
        XCTAssertEqual(target.seekTime, 45)
    }

    func testOpenKnowledgeSourceNotificationDeliversTypedPayload() {
        let payload = KnowledgeSourceNavigation(
            recordingObjectURI: URL(string: "x-coredata://recording/1")!,
            segmentId: UUID(),
            startTime: 12
        )
        let expectation = expectation(description: "typed source navigation")
        let observer = NotificationCenter.default.addObserver(
            forName: .openKnowledgeSource,
            object: nil,
            queue: nil
        ) { notification in
            XCTAssertEqual(notification.object as? KnowledgeSourceNavigation, payload)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(name: .openKnowledgeSource, object: payload)
        wait(for: [expectation], timeout: 1)
    }

    private func makeRecording(in context: NSManagedObjectContext, isDeleted: Bool) -> Recording {
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.title = "测试录音"
        recording.isDeletedValue = isDeleted
        return recording
    }

    private func makeSegment(
        in context: NSManagedObjectContext,
        transcription: Transcription,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) -> TranscriptionSegment {
        let segment = TranscriptionSegment(context: context)
        segment.id = UUID()
        segment.sequence = Int32((transcription.segments as? Set<TranscriptionSegment>)?.count ?? 0)
        segment.startTime = start
        segment.endTime = end
        segment.text = text
        segment.transcription = transcription
        return segment
    }
}
