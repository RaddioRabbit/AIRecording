import Foundation
import AVFoundation
import CoreData

enum AudioImportError: Error, LocalizedError {
    case fileNotFound(url: URL)
    case invalidFormat(url: URL)
    case diskSpaceInsufficient(needed: Int64, available: Int64)
    case copyFailed(url: URL, underlying: Error)
    case metadataReadFailed(url: URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "文件未找到: \(url.lastPathComponent)"
        case .invalidFormat(let url):
            return "不支持的格式: \(url.lastPathComponent)"
        case .diskSpaceInsufficient:
            return "磁盘空间不足"
        case .copyFailed(let url, _):
            return "复制文件失败: \(url.lastPathComponent)"
        case .metadataReadFailed(let url):
            return "无法读取音频元数据: \(url.lastPathComponent)"
        }
    }
}

struct AudioImportResult {
    let sourceURL: URL
    let recording: Recording?
    let error: AudioImportError?
}

@MainActor
final class AudioImportService: ObservableObject {
    static let shared = AudioImportService()
    nonisolated static let supportedFileExtensions = ["wav", "mp3", "m4a"]

    @Published private(set) var isImporting = false

    private let persistence = PersistenceController.shared

    private init() {}

    /// Import one or more audio files. Automatically triggers transcription for each success.
    func importFiles(urls: [URL]) async -> [AudioImportResult] {
        guard !urls.isEmpty else { return [] }

        isImporting = true
        defer { isImporting = false }

        var results: [AudioImportResult] = []

        for url in urls.prefix(10) {
            let result = await importSingleFile(url: url)
            results.append(result)

            if let recording = result.recording {
                do {
                    _ = try await TranscriptionService.shared.transcribe(recording: recording)
                } catch {
                    AppLogger.log(.error, category: "import", event: "import_transcription_failed",
                                  recordingId: recording.id?.uuidString,
                                  metadata: ["errorType": String(describing: type(of: error))])
                }
            }
        }

        return results
    }

    private func importSingleFile(url: URL) async -> AudioImportResult {
        let sourceURL = url.resolvingSymlinksInPath()

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            AppLogger.log(.warning, category: "import", event: "import_file_not_found",
                          metadata: ["fileExtension": sourceURL.pathExtension.lowercased()])
            return AudioImportResult(sourceURL: sourceURL, recording: nil, error: .fileNotFound(url: sourceURL))
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedFileExtensions.contains(ext) else {
            AppLogger.log(.warning, category: "import", event: "import_invalid_format",
                          metadata: ["fileExtension": ext])
            return AudioImportResult(sourceURL: sourceURL, recording: nil, error: .invalidFormat(url: sourceURL))
        }

        let targetURL: URL
        do {
            targetURL = try generateImportURL(originalURL: sourceURL)
        } catch {
            AppLogger.log(.error, category: "import", event: "import_target_url_failed",
                          metadata: ["errorType": String(describing: type(of: error))])
            return AudioImportResult(sourceURL: sourceURL, recording: nil, error: .copyFailed(url: sourceURL, underlying: error))
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        } catch {
            let nsError = error as NSError
            AppLogger.log(.error, category: "import", event: "import_copy_failed",
                          metadata: ["errorDomain": nsError.domain, "errorCode": nsError.code])
            return AudioImportResult(sourceURL: sourceURL, recording: nil, error: .copyFailed(url: sourceURL, underlying: error))
        }

        let metadata = await readAudioMetadata(url: targetURL)

        let recording = createRecordingEntity(
            fileURL: targetURL,
            sourceURL: sourceURL,
            metadata: metadata
        )

        return AudioImportResult(sourceURL: sourceURL, recording: recording, error: nil)
    }

    private func generateImportURL(originalURL: URL) throws -> URL {
        let baseURL: URL
        if let customPath = UserDefaults.standard.string(forKey: "storage.location"), !customPath.isEmpty {
            baseURL = URL(fileURLWithPath: customPath)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseURL = appSupport.appendingPathComponent("AIRecording/Recordings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let datePrefix = dateFormatter.string(from: Date())

        let sanitizedName = sanitizeFilename(originalURL.deletingPathExtension().lastPathComponent)
        let ext = originalURL.pathExtension.lowercased()
        let baseFilename = "imported_\(datePrefix)_\(sanitizedName).\(ext)"

        var targetURL = baseURL.appendingPathComponent(baseFilename)
        var counter = 1
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let newFilename = "imported_\(datePrefix)_\(sanitizedName)-\(counter).\(ext)"
            targetURL = baseURL.appendingPathComponent(newFilename)
            counter += 1
        }

        return targetURL
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func readAudioMetadata(url: URL) async -> (duration: Double, sampleRate: Double, channels: Int, bitDepth: Int)? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let duration = Double(audioFile.length) / format.sampleRate
            let sampleRate = format.sampleRate
            let channels = Int(format.channelCount)

            var bitDepth = 0
            let asbd = format.streamDescription.pointee
            bitDepth = Int(asbd.mBitsPerChannel)
            if bitDepth == 0 {
                switch format.commonFormat {
                case .pcmFormatInt16: bitDepth = 16
                case .pcmFormatInt32: bitDepth = 32
                case .pcmFormatFloat32: bitDepth = 32
                case .pcmFormatFloat64: bitDepth = 64
                case .otherFormat: bitDepth = 0
                @unknown default: bitDepth = 0
                }
            }

            return (duration, sampleRate, channels, bitDepth)
        } catch {
            AppLogger.log(.warning, category: "import", event: "import_metadata_read_failed",
                          metadata: ["errorType": String(describing: type(of: error))])
        }

        let asset = AVAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            AppLogger.log(.warning, category: "import", event: "import_no_audio_track",
                          metadata: ["fileExtension": url.pathExtension.lowercased()])
            return nil
        }

        let duration = try? await asset.load(.duration)
        let durationSeconds = duration.map { CMTimeGetSeconds($0) } ?? 0
        let desc = try? await audioTrack.load(.formatDescriptions).first
        var sampleRate: Double = 0
        var channels: Int = 0
        var bitDepth: Int = 0

        if let cmDesc = desc {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmDesc)
            if let asbd = asbd {
                sampleRate = asbd.pointee.mSampleRate
                channels = Int(asbd.pointee.mChannelsPerFrame)
                bitDepth = Int(asbd.pointee.mBitsPerChannel)
            }
        }

        if durationSeconds.isFinite && durationSeconds > 0 {
            return (durationSeconds, sampleRate > 0 ? sampleRate : 44100, channels > 0 ? channels : 1, bitDepth)
        }

        return nil
    }

    private func createRecordingEntity(
        fileURL: URL,
        sourceURL: URL,
        metadata: (duration: Double, sampleRate: Double, channels: Int, bitDepth: Int)?
    ) -> Recording {
        let context = persistence.container.viewContext
        let recording = Recording(context: context)

        let now = Date()
        let fileCreatedAt: Date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
           let creationDate = attrs[.creationDate] as? Date {
            fileCreatedAt = creationDate
        } else {
            fileCreatedAt = now
        }

        let fileSize: Double
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            fileSize = size.doubleValue
        } else {
            fileSize = 0
        }

        let originalName = sourceURL.deletingPathExtension().lastPathComponent

        let storageLocation = UserDefaults.standard.string(forKey: "storage.location") ?? "default"

        recording.id = UUID()
        recording.filePath = fileURL.path
        recording.fileFormat = fileURL.pathExtension.lowercased()
        recording.duration = Int32(metadata?.duration ?? 0)
        recording.sampleRate = Int32(metadata?.sampleRate ?? 44100)
        recording.channels = Int32(metadata?.channels ?? 1)
        recording.bitDepth = Int32(metadata?.bitDepth ?? 0)
        recording.fileSize = fileSize
        recording.sourceType = Int16(AudioSource.imported.rawValue)
        recording.status = Int16(RecordingStatus.completed.rawValue)
        recording.title = "导入录音 \(formatDate(now))"
        recording.customTitle = originalName
        recording.createdAt = fileCreatedAt
        recording.updatedAt = now
        recording.isDeletedValue = false
        recording.isFavorite = false
        recording.isEncrypted = false
        recording.storageLocation = storageLocation.isEmpty ? "default" : storageLocation

        persistence.saveContext()
        return recording
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
