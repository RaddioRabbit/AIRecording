import XCTest
import CoreData
@testable import AIRecording

/// Regression anchor for the "录音列表在转录过程中出现重复行" bug.
///
/// Root cause: `TranscriptionService.transcribe` used to resume on a
/// cooperative-pool thread after its first `await`, creating segments and
/// calling `saveContext()` on the main-queue-confined `viewContext` from a
/// background thread. Racing main-thread fetches could then return corrupted
/// results (a recording showing up twice) that never persisted to the store.
///
/// The fix isolates `transcribe` to the MainActor. These tests lock the
/// observable contract: transcription never creates extra Recording entities,
/// and a recording owns at most one Transcription at any time (retries
/// replace the failed one instead of piling up).
///
/// The tests force the FunASR engine with a dummy API key so the call fails
/// fast on the missing audio file — the xctest host has no
/// NSSpeechRecognitionUsageDescription, so touching the Apple Speech path
/// would abort the whole test process.
final class TranscriptionInvariantTests: XCTestCase {

    private static let funASRKey = "funasr.apiKey"

    @MainActor
    private func makeTestRecording() -> Recording {
        let context = PersistenceController.shared.container.viewContext
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.filePath = "/nonexistent/path/transcription-invariant-test.m4a"
        recording.fileFormat = "m4a"
        recording.title = "transcription-invariant-test"
        recording.createdAt = Date()
        recording.updatedAt = Date()
        recording.isDeletedValue = false
        PersistenceController.shared.saveContext()
        return recording
    }

    @MainActor
    private func deleteRecording(_ recording: Recording) {
        let context = PersistenceController.shared.container.viewContext
        context.delete(recording)
        PersistenceController.shared.saveContext()
    }

    /// Force the FunASR engine so `transcribe` fails on the missing file
    /// before reaching any Speech-framework or network call.
    private func withForcedFunASREngine(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let oldValue = defaults.string(forKey: Self.funASRKey)
        defaults.set("transcription-invariant-dummy-key", forKey: Self.funASRKey)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: Self.funASRKey)
            } else {
                defaults.removeObject(forKey: Self.funASRKey)
            }
        }
        try await body()
    }

    @MainActor
    func testTranscribeNeverCreatesAdditionalRecordings() async throws {
        let context = PersistenceController.shared.container.viewContext
        let recording = makeTestRecording()
        defer { deleteRecording(recording) }

        let request = Recording.fetchRequest()
        let countBefore = try context.count(for: request)

        await withForcedFunASREngine {
            // The file does not exist, so both attempts throw after recording a
            // failed transcription. What matters is the entity graph afterwards.
            _ = try? await TranscriptionService.shared.transcribe(recording: recording)
            _ = try? await TranscriptionService.shared.transcribe(recording: recording)
        }

        let countAfter = try context.count(for: request)
        XCTAssertEqual(countAfter, countBefore, "转录过程不得新增 Recording 实体")
    }

    @MainActor
    func testRetranscribeKeepsSingleTranscriptionPerRecording() async throws {
        let context = PersistenceController.shared.container.viewContext
        let recording = makeTestRecording()
        defer { deleteRecording(recording) }

        await withForcedFunASREngine {
            _ = try? await TranscriptionService.shared.transcribe(recording: recording)
            _ = try? await TranscriptionService.shared.transcribe(recording: recording)
        }

        let transcriptions = try context.fetch(Transcription.fetchRequest())
            .filter { $0.recordingId == recording.id }
        XCTAssertEqual(transcriptions.count, 1, "同一录音在任意时刻只应存在一条 Transcription（重试应替换失败记录，而非叠加）")
    }
}
