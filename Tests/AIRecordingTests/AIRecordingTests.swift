import XCTest
import AVFoundation
@testable import AIRecording

final class AIRecordingTests: XCTestCase {

    func testRecordingConfigurationDefault() {
        let config = RecordingConfiguration.default
        XCTAssertEqual(config.sampleRate, 44100)
        XCTAssertEqual(config.channels, 1)
        XCTAssertEqual(config.bitDepth, 16)
        XCTAssertEqual(config.format, .caf)
    }

    func testAudioSourceEnum() {
        XCTAssertEqual(AudioSource.microphone.rawValue, 0)
        XCTAssertEqual(AudioSource.systemAudio.rawValue, 1)
        XCTAssertEqual(AudioSource.mixed.rawValue, 2)
    }

    func testRecordingFormatRawValue() {
        XCTAssertEqual(RecordingFormat.wav.rawValue, "wav")
        XCTAssertEqual(RecordingFormat.caf.rawValue, "caf")
        XCTAssertEqual(RecordingFormat.flac.rawValue, "flac")
    }

    func testAudioImportSupportsM4A() {
        XCTAssertTrue(AudioImportService.supportedFileExtensions.contains("wav"))
        XCTAssertTrue(AudioImportService.supportedFileExtensions.contains("mp3"))
        XCTAssertTrue(AudioImportService.supportedFileExtensions.contains("m4a"))
    }

    func testAppleSpeechConvertsM4AToRecognitionWAV() {
        let service = TranscriptionService.shared
        XCTAssertFalse(service.shouldConvertForAppleSpeech(fileExtension: "wav"))
        XCTAssertFalse(service.shouldConvertForAppleSpeech(fileExtension: "mp3"))
        XCTAssertTrue(service.shouldConvertForAppleSpeech(fileExtension: "m4a"))
        XCTAssertTrue(service.shouldConvertForAppleSpeech(fileExtension: "caf"))
    }

    func testPermissionStatus() {
        let granted = PermissionStatus.granted
        let denied = PermissionStatus.denied
        let notDetermined = PermissionStatus.notDetermined

        XCTAssertNotEqual(granted, denied)
        XCTAssertNotEqual(granted, notDetermined)
        XCTAssertNotEqual(denied, notDetermined)
    }

    func testFormattersDuration() {
        let result1 = Formatters.formatDuration(125)
        XCTAssertEqual(result1, "02:05")

        let result2 = Formatters.formatDuration(3665)
        XCTAssertEqual(result2, "1:01:05")

        let result3 = Formatters.formatDuration(0)
        XCTAssertEqual(result3, "00:00")
    }

    func testAudioFormatConstants() {
        let settings = AudioFormatConstants.settings(sampleRate: 48000, channels: 2, bitDepth: 24)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 24)
    }

    func testRetryableHTTPStatuses() {
        let service = TranscriptionService.shared
        let retryableStatuses = [403, 408, 429, 500, 502, 503, 504]
        for status in retryableStatuses {
            XCTAssertTrue(service.isRetryableHTTPStatus(status), "Status \(status) should be retryable")
        }
    }

    func testNonRetryableHTTPStatuses() {
        let service = TranscriptionService.shared
        let nonRetryableStatuses = [200, 201, 400, 401, 404, 422]
        for status in nonRetryableStatuses {
            XCTAssertFalse(service.isRetryableHTTPStatus(status), "Status \(status) should not be retryable")
        }
    }
}
