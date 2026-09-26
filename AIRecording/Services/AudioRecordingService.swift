import AVFoundation
import Combine
import CoreData

enum RecordingState: Equatable {
    case idle
    case preparing
    case recording(startTime: Date, source: AudioSource)
    case paused(startTime: Date, pausedDuration: TimeInterval, source: AudioSource)
    case stopping
    case error(RecordingError)
}

enum RecordingError: Error, Equatable {
    case permissionDenied(source: AudioSource)
    case deviceUnavailable(source: AudioSource)
    case diskSpaceInsufficient(needed: Int64, available: Int64)
    case encodingFailed
    case fileIOFailed(path: String)
    case alreadyRecording
    case notRecording
    case invalidConfiguration

    static func == (lhs: RecordingError, rhs: RecordingError) -> Bool {
        switch (lhs, rhs) {
        case (.permissionDenied(let a), .permissionDenied(let b)): return a == b
        case (.deviceUnavailable(let a), .deviceUnavailable(let b)): return a == b
        case (.diskSpaceInsufficient(let na, let aa), .diskSpaceInsufficient(let nb, let ab)): return na == nb && aa == ab
        case (.encodingFailed, .encodingFailed): return true
        case (.fileIOFailed(let a), .fileIOFailed(let b)): return a == b
        case (.alreadyRecording, .alreadyRecording): return true
        case (.notRecording, .notRecording): return true
        case (.invalidConfiguration, .invalidConfiguration): return true
        default: return false
        }
    }
}

enum AudioSource: Int, CaseIterable {
    case microphone = 0
    case systemAudio = 1
    case mixed = 2
    case imported = 3
}

extension AudioSource {
    var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统音频"
        case .mixed: return "混合"
        case .imported: return "导入"
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .mixed: return "mic.and.signal.meter.fill"
        case .imported: return "square.and.arrow.down"
        }
    }
}

struct RecordingConfiguration {
    var sampleRate: Double = 44100
    var channels: Int = 1
    var bitDepth: Int = 16
    var format: RecordingFormat = .caf
    var storageLocation: URL?

    static var `default`: RecordingConfiguration {
        RecordingConfiguration()
    }
}

enum RecordingFormat: String {
    case wav = "wav"
    case caf = "caf"
    case flac = "flac"
}

@MainActor
class AudioRecordingService: ObservableObject {
    static let shared = AudioRecordingService()

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var audioLevel: Float = 0.0

    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
    private var outputFile: AVAudioFile?
    private var currentRecording: Recording?
    private var startTime: Date?
    private var timer: Timer?

    private var currentSource: AudioSource = .microphone
    private var tempMicFileURL: URL?
    private var tempSystemFileURL: URL?
    private var systemAudioCancellable: AnyCancellable?

    private let persistence = PersistenceController.shared
    private let systemAudioService = SystemAudioCaptureService.shared
    private let audioMixerService = AudioMixerService.shared

    private init() {}

    // MARK: - Permissions

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func checkPermission() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    // MARK: - Recording Control

    func startRecording(configuration: RecordingConfiguration, source: AudioSource = .microphone) async throws -> Recording {
        guard case .idle = state else {
            throw RecordingError.alreadyRecording
        }

        currentSource = source

        switch source {
        case .microphone:
            return try await startMicrophoneRecording(configuration: configuration)
        case .systemAudio:
            return try await startSystemAudioRecording(configuration: configuration)
        case .mixed:
            return try await startMixedRecording(configuration: configuration)
        case .imported:
            throw RecordingError.invalidConfiguration
        }
    }

    private func startMicrophoneRecording(configuration: RecordingConfiguration) async throws -> Recording {
        let hasPermission = await requestPermission()
        guard hasPermission else {
            throw RecordingError.permissionDenied(source: .microphone)
        }

        state = .preparing

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: hardwareFormat.sampleRate,
            AVNumberOfChannelsKey: hardwareFormat.channelCount,
            AVLinearPCMBitDepthKey: configuration.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let fileURL = generateRecordingURL(configuration: configuration)

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            self.outputFile = outputFile
        } catch {
            cleanup()
            throw RecordingError.fileIOFailed(path: fileURL.path)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: outputFile.processingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            do {
                try self.outputFile?.write(from: buffer)
            } catch {
                AppLogger.log(.warning, category: "recording", event: "recording_write_failed",
                              metadata: ["errorType": String(describing: type(of: error))])
            }

            let level = self.calculateAudioLevel(buffer: buffer)
            DispatchQueue.main.async {
                self.audioLevel = level
            }
        }

        do {
            try audioEngine.start()
        } catch {
            cleanup()
            throw RecordingError.encodingFailed
        }

        let now = Date()
        self.startTime = now

        let recording = createRecordingEntity(fileURL: fileURL, configuration: configuration, source: .microphone, hardwareFormat: hardwareFormat, now: now)

        state = .recording(startTime: now, source: .microphone)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let duration = Date().timeIntervalSince(start)
            self.currentRecording?.duration = Int32(duration)
            self.currentRecording?.updatedAt = Date()
            self.persistence.saveContext()
        }

        return recording
    }

    private func startSystemAudioRecording(configuration: RecordingConfiguration) async throws -> Recording {
        state = .preparing

        let fileURL = generateRecordingURL(configuration: configuration)

        do {
            try await systemAudioService.startCapture(to: fileURL)
        } catch let error as SystemAudioError {
            cleanup()
            throw error
        } catch {
            cleanup()
            throw RecordingError.deviceUnavailable(source: .systemAudio)
        }

        systemAudioCancellable = systemAudioService.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }

        let now = Date()
        self.startTime = now

        let recording = createRecordingEntity(fileURL: fileURL, configuration: configuration, source: .systemAudio, hardwareFormat: nil, now: now)

        state = .recording(startTime: now, source: .systemAudio)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let duration = Date().timeIntervalSince(start)
            self.currentRecording?.duration = Int32(duration)
            self.currentRecording?.updatedAt = Date()
            self.persistence.saveContext()
        }

        return recording
    }

    private func startMixedRecording(configuration: RecordingConfiguration) async throws -> Recording {
        let hasMicPermission = await requestPermission()
        guard hasMicPermission else {
            throw RecordingError.permissionDenied(source: .mixed)
        }

        state = .preparing

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AIRecording", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let micFileURL = tempDir.appendingPathComponent("mic_\(UUID().uuidString).caf")
        let sysFileURL = tempDir.appendingPathComponent("sys_\(UUID().uuidString).caf")
        self.tempMicFileURL = micFileURL
        self.tempSystemFileURL = sysFileURL

        let finalFileURL = generateRecordingURL(configuration: configuration)

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        let micSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: hardwareFormat.sampleRate,
            AVNumberOfChannelsKey: hardwareFormat.channelCount,
            AVLinearPCMBitDepthKey: configuration.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let micOutputFile: AVAudioFile
        do {
            micOutputFile = try AVAudioFile(forWriting: micFileURL, settings: micSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            cleanup()
            throw RecordingError.fileIOFailed(path: micFileURL.path)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micOutputFile.processingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            do {
                try micOutputFile.write(from: buffer)
            } catch {
                AppLogger.log(.warning, category: "recording", event: "mic_temp_write_failed",
                              metadata: ["errorType": String(describing: type(of: error))])
            }
        }

        do {
            try audioEngine.start()
        } catch {
            cleanup()
            throw RecordingError.encodingFailed
        }

        do {
            try await systemAudioService.startCapture(to: sysFileURL)
        } catch let error as SystemAudioError {
            cleanup()
            throw error
        } catch {
            cleanup()
            throw RecordingError.deviceUnavailable(source: .mixed)
        }

        systemAudioCancellable = systemAudioService.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }

        let now = Date()
        self.startTime = now

        let recording = createRecordingEntity(fileURL: finalFileURL, configuration: configuration, source: .mixed, hardwareFormat: hardwareFormat, now: now)

        state = .recording(startTime: now, source: .mixed)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let duration = Date().timeIntervalSince(start)
            self.currentRecording?.duration = Int32(duration)
            self.currentRecording?.updatedAt = Date()
            self.persistence.saveContext()
        }

        return recording
    }

    func stopRecording() async throws -> Recording {
        guard let recording = currentRecording else {
            throw RecordingError.notRecording
        }

        state = .stopping

        timer?.invalidate()
        timer = nil

        switch currentSource {
        case .microphone:
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            await finalizeRecording(recording)
        case .systemAudio:
            systemAudioCancellable?.cancel()
            systemAudioCancellable = nil
            _ = try? await systemAudioService.stopCapture()
            await finalizeRecording(recording)
        case .mixed:
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            systemAudioCancellable?.cancel()
            systemAudioCancellable = nil
            _ = try? await systemAudioService.stopCapture()
            try await finalizeMixedRecording(recording)
        case .imported:
            // Imported files have no active recording session to stop
            break
        }

        let finalRecording = recording
        cleanup()
        state = .idle

        return finalRecording
    }

    private func finalizeRecording(_ recording: Recording) async {
        if let path = recording.filePath {
            let fileURL = URL(fileURLWithPath: path)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                recording.fileSize = (attributes[FileAttributeKey.size] as? NSNumber)?.doubleValue ?? 0
            }
        }

        recording.status = Int16(RecordingStatus.completed.rawValue)
        recording.updatedAt = Date()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        recording.title = "录音 \(formatter.string(from: recording.createdAt ?? Date()))"

        persistence.saveContext()
    }

    private func finalizeMixedRecording(_ recording: Recording) async throws {
        guard let micURL = tempMicFileURL, let sysURL = tempSystemFileURL else {
            throw RecordingError.encodingFailed
        }

        guard let finalPath = recording.filePath else {
            throw RecordingError.fileIOFailed(path: "")
        }
        let finalURL = URL(fileURLWithPath: finalPath)

        do {
            try await audioMixerService.mixFiles(
                fileA: micURL,
                fileB: sysURL,
                outputURL: finalURL,
                sampleRate: Double(recording.sampleRate),
                channels: Int(recording.channels)
            )
        } catch {
            throw RecordingError.encodingFailed
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: finalURL.path) {
            recording.fileSize = (attributes[FileAttributeKey.size] as? NSNumber)?.doubleValue ?? 0
        }

        recording.status = Int16(RecordingStatus.completed.rawValue)
        recording.updatedAt = Date()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        recording.title = "录音 \(formatter.string(from: recording.createdAt ?? Date()))"

        persistence.saveContext()
    }

    // MARK: - Helpers

    private func createRecordingEntity(fileURL: URL, configuration: RecordingConfiguration, source: AudioSource, hardwareFormat: AVAudioFormat?, now: Date) -> Recording {
        let context = persistence.container.viewContext
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.filePath = fileURL.path
        recording.fileFormat = configuration.format.rawValue
        let sampleRate = hardwareFormat?.sampleRate ?? configuration.sampleRate
        let channelCount = hardwareFormat?.channelCount ?? AVAudioChannelCount(configuration.channels)
        recording.sampleRate = Int32(sampleRate)
        recording.channels = Int32(channelCount)
        recording.bitDepth = Int32(configuration.bitDepth)
        recording.sourceType = Int16(source.rawValue)
        recording.status = Int16(RecordingStatus.recording.rawValue)
        recording.createdAt = now
        recording.updatedAt = now
        recording.isDeletedValue = false
        recording.isFavorite = false
        recording.isEncrypted = false
        recording.storageLocation = configuration.storageLocation?.path ?? "default"
        recording.duration = 0
        recording.fileSize = 0

        persistence.saveContext()
        self.currentRecording = recording
        return recording
    }

    private func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var average: Float = 0

        if let int16Data = buffer.int16ChannelData?[0] {
            var sum: Int32 = 0
            for i in 0..<frameLength {
                sum += abs(Int32(int16Data[i]))
            }
            average = Float(sum) / Float(frameLength) / Float(Int16.max)
        } else if let floatData = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(floatData[i])
            }
            average = sum / Float(frameLength)
        } else {
            return 0
        }

        let db = 20 * log10(max(average, 0.00001))
        return max(0, min(1, (db + 60) / 60))
    }

    private func generateRecordingURL(configuration: RecordingConfiguration) -> URL {
        let baseURL: URL
        if let customLocation = configuration.storageLocation {
            baseURL = customLocation
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseURL = appSupport.appendingPathComponent("AIRecording/Recordings", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "recording_\(dateFormatter.string(from: Date())).\(configuration.format.rawValue)"
        return baseURL.appendingPathComponent(filename)
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        audioEngine = nil
        outputFile = nil
        currentRecording = nil
        startTime = nil
        systemAudioCancellable?.cancel()
        systemAudioCancellable = nil
        tempMicFileURL = nil
        tempSystemFileURL = nil
        currentSource = .microphone
        audioLevel = 0.0
        state = .idle
    }
}

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

enum RecordingStatus: Int {
    case recording = 0
    case completed = 1
    case processing = 2
    case error = 3
}
