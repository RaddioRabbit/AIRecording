import XCTest
import CoreData
@testable import AIRecording

final class AudioSourceIntegrationTests: XCTestCase {
    func testAudioSourceEnumValues() {
        XCTAssertEqual(AudioSource.microphone.rawValue, 0)
        XCTAssertEqual(AudioSource.systemAudio.rawValue, 1)
        XCTAssertEqual(AudioSource.mixed.rawValue, 2)
        XCTAssertEqual(AudioSource.imported.rawValue, 3)
    }

    func testAudioSourceDisplayNames() {
        XCTAssertEqual(AudioSource.microphone.displayName, "麦克风")
        XCTAssertEqual(AudioSource.systemAudio.displayName, "系统音频")
        XCTAssertEqual(AudioSource.mixed.displayName, "混合")
        XCTAssertEqual(AudioSource.imported.displayName, "导入")
    }

    func testAudioSourceIconNames() {
        XCTAssertEqual(AudioSource.microphone.iconName, "mic.fill")
        XCTAssertEqual(AudioSource.systemAudio.iconName, "speaker.wave.2.fill")
        XCTAssertEqual(AudioSource.mixed.iconName, "mic.and.signal.meter.fill")
        XCTAssertEqual(AudioSource.imported.iconName, "square.and.arrow.down")
    }

    func testRecordingSourceTypeRoundTrip() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        for source in AudioSource.allCases {
            let recording = Recording(context: context)
            recording.id = UUID()
            recording.sourceType = Int16(source.rawValue)
            recording.createdAt = Date()
            recording.status = Int16(RecordingStatus.completed.rawValue)
            recording.isDeletedValue = false
        }

        controller.saveContext()

        let request: NSFetchRequest<Recording> = Recording.fetchRequest()
        let results = try? context.fetch(request)
        XCTAssertEqual(results?.count, AudioSource.allCases.count)

        for source in AudioSource.allCases {
            let match = results?.first { $0.sourceType == Int16(source.rawValue) }
            XCTAssertNotNil(match)
            XCTAssertEqual(match?.sourceTypeEnum, source)
            XCTAssertEqual(match?.sourceDisplayName, source.displayName)
            XCTAssertEqual(match?.sourceIconName, source.iconName)
        }
    }

    func testRecordingConfigurationDefault() {
        let config = RecordingConfiguration.default
        XCTAssertEqual(config.sampleRate, 44100)
        XCTAssertEqual(config.channels, 1)
        XCTAssertEqual(config.bitDepth, 16)
        XCTAssertEqual(config.format, .caf)
    }

    func testRecordingErrorEquatable() {
        let e1 = RecordingError.permissionDenied(source: .microphone)
        let e2 = RecordingError.permissionDenied(source: .microphone)
        let e3 = RecordingError.permissionDenied(source: .systemAudio)
        XCTAssertEqual(e1, e2)
        XCTAssertNotEqual(e1, e3)

        let e4 = RecordingError.fileIOFailed(path: "/tmp/test")
        let e5 = RecordingError.fileIOFailed(path: "/tmp/test")
        let e6 = RecordingError.fileIOFailed(path: "/tmp/other")
        XCTAssertEqual(e4, e5)
        XCTAssertNotEqual(e4, e6)
    }

    func testSystemAudioErrorEquatable() {
        let e1 = SystemAudioError.permissionDenied
        let e2 = SystemAudioError.permissionDenied
        XCTAssertEqual(e1, e2)

        let e3 = SystemAudioError.notRunning
        XCTAssertNotEqual(e1, e3)
    }

    func testAudioMixErrorEquatable() {
        let e1 = AudioMixError.fileNotFound
        let e2 = AudioMixError.fileNotFound
        XCTAssertEqual(e1, e2)

        let e3 = AudioMixError.formatMismatch
        XCTAssertNotEqual(e1, e3)
    }
}
