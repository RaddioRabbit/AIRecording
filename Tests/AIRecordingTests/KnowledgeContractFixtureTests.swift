import CoreData
import XCTest
@testable import AIRecording

@MainActor
final class KnowledgeContractFixtureTests: XCTestCase {
    func testSharedFixtureDecodesSourceResponseAndBuildsNavigationPayload() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.recordings.count, 2)
        XCTAssertEqual(fixture.query, "最终由谁负责上线协调？")

        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let recordingFixture = try XCTUnwrap(fixture.recordings.first {
            $0.recordingId == fixture.sourceResponse.recordingId
        })
        let recording = Recording(context: context)
        recording.id = recordingFixture.recordingId
        recording.isDeletedValue = false
        let transcription = Transcription(context: context)
        transcription.recording = recording
        let citedSegment = TranscriptionSegment(context: context)
        citedSegment.id = fixture.sourceResponse.segmentIds.first
        citedSegment.startTime = fixture.sourceResponse.startTime
        citedSegment.endTime = fixture.sourceResponse.endTime
        citedSegment.text = recordingFixture.segments.first?.text
        citedSegment.transcription = transcription
        try context.save()

        let source = KnowledgeSourceLink(context: context)
        source.sourceId = fixture.sourceResponse.sourceId
        source.recordingId = fixture.sourceResponse.recordingId
        source.segmentId = fixture.sourceResponse.segmentIds.first
        source.startTime = fixture.sourceResponse.startTime
        source.endTime = fixture.sourceResponse.endTime

        let navigation = try XCTUnwrap(KnowledgeSourceNavigation.make(recording: recording, source: source))
        XCTAssertEqual(navigation.recordingObjectURI, recording.objectID.uriRepresentation())
        XCTAssertEqual(navigation.segmentId, fixture.sourceResponse.segmentIds.first)
        XCTAssertEqual(navigation.startTime, fixture.sourceResponse.startTime)
    }

    private func loadFixture() throws -> Fixture {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("KnowledgeAgent/tests/fixtures/two_recordings.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Fixture.self, from: Data(contentsOf: path))
    }
}

private struct Fixture: Decodable {
    let query: String
    let recordings: [FixtureRecording]
    let sourceResponse: KnowledgeSourceDTO
}

private struct FixtureRecording: Decodable {
    let recordingId: UUID
    let segments: [FixtureSegment]
}

private struct FixtureSegment: Decodable {
    let id: UUID
    let text: String
}
