import XCTest
@testable import AIRecording

@MainActor
final class SystemAudioCaptureServiceTests: XCTestCase {
    func testSingleton() {
        let a = SystemAudioCaptureService.shared
        let b = SystemAudioCaptureService.shared
        XCTAssertTrue(a === b)
    }

    func testInitialState() {
        let service = SystemAudioCaptureService.shared
        XCTAssertFalse(service.isRunning)
    }
}
