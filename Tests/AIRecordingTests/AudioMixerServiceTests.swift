import XCTest
@testable import AIRecording

@MainActor
final class AudioMixerServiceTests: XCTestCase {
    func testSingleton() {
        XCTAssertTrue(AudioMixerService.shared === AudioMixerService.shared)
    }

    func testMixFilesMissingInput() async {
        let tempDir = FileManager.default.temporaryDirectory
        let fakeA = tempDir.appendingPathComponent("fakeA.caf")
        let fakeB = tempDir.appendingPathComponent("fakeB.caf")
        let output = tempDir.appendingPathComponent("output.caf")

        do {
            _ = try await AudioMixerService.shared.mixFiles(
                fileA: fakeA, fileB: fakeB, outputURL: output,
                sampleRate: 44100, channels: 1
            )
            XCTFail("Should throw fileNotFound")
        } catch let error as AudioMixError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
