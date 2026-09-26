import Speech
import AVFoundation
import CoreData

enum TranscriptionError: Error, LocalizedError {
    case audioFileNotFound(path: String)
    case audioFileCorrupted(path: String)
    case engineNotAvailable
    case recognitionFailed(underlying: Error)
    case languageNotSupported(language: String)
    case timeout(duration: TimeInterval)
    case cancelled
    case invalidAudioFormat
    case permissionDenied
    case siriDisabled

    var errorDescription: String? {
        switch self {
        case .audioFileNotFound(let path):
            return "音频文件未找到: \(path)"
        case .audioFileCorrupted(let path):
            return "音频文件损坏: \(path)"
        case .engineNotAvailable:
            return "语音识别引擎不可用"
        case .recognitionFailed(let underlying):
            return TranscriptionService.localizedErrorDescription(for: underlying)
        case .languageNotSupported(let language):
            return "不支持的语言: \(language)"
        case .timeout(let duration):
            return "识别超时（\(Int(duration)) 秒）"
        case .cancelled:
            return "识别已取消"
        case .invalidAudioFormat:
            return "音频格式不兼容"
        case .permissionDenied:
            return "语音识别权限被拒绝，请在系统设置中开启"
        case .siriDisabled:
            return "Siri 和听写功能已关闭。请前往 系统设置 > Apple Intelligence 与 Siri > 打开 Siri，或在设置中切换到 Fun-ASR 引擎（支持说话人分割，无需 Siri）。"
        }
    }
}

enum TranscriptionEngine: Int {
    case appleSpeech = 0
    case funASR = 1
}

enum TranscriptionStatus: Int {
    case notStarted = 0
    case processing = 1
    case completed = 2
    case failed = 3
}

class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published var transcriptionProgress: Double = 0

    private var recognitionTask: SFSpeechRecognitionTask?
    private let persistence = PersistenceController.shared

    private init() {}

    // MARK: - Permissions

    func requestPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func checkPermission() -> PermissionStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
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

    // MARK: - Transcription

    // Core Data viewContext is main-queue confined. Keep this method on the
    // MainActor so that the post-await continuation (segment creation and
    // saveContext) cannot resume on a cooperative-pool thread and race
    // main-thread fetches — that race can corrupt fetch results (e.g. a
    // recording briefly appearing twice in the list during transcription).
    @MainActor
    func transcribe(recording: Recording, language: String? = nil) async throws -> Transcription {
        AppLogger.log(.debug, category: "transcription", event: "transcribe_called", recordingId: recording.id?.uuidString, metadata: ["fileExtension": recording.filePath.map { ($0 as NSString).pathExtension } ?? ""])

        let engine = selectedEngine()
        let context = persistence.container.viewContext

        // Guard against duplicate transcription
        if let existing = recording.transcription {
            if existing.isProcessing {
                return existing
            }
            context.delete(existing)
        }

        // Create transcription entity
        let transcription = Transcription(context: context)
        transcription.id = UUID()
        transcription.recordingId = recording.id
        transcription.recording = recording
        transcription.status = Int16(TranscriptionStatus.processing.rawValue)
        transcription.engine = Int16(engine.rawValue)
        transcription.language = language ?? "auto"
        transcription.startedAt = Date()
        transcription.createdAt = Date()
        transcription.updatedAt = Date()
        transcription.retryCount = 0

        persistence.saveContext()

        do {
            let segments: [TranscriptionSegmentDTO]
            let actualEngine: TranscriptionEngine
            switch engine {
            case .appleSpeech:
                segments = try await transcribeWithAppleSpeech(recording: recording, language: language)
                actualEngine = .appleSpeech
            case .funASR:
                do {
                    segments = try await transcribeWithFunASR(recording: recording, language: language)
                    actualEngine = .funASR
                } catch {
                    // Only fall back to Apple Speech if the error is retryable / transient.
                    // Do NOT mask configuration or permission errors with a silent fallback.
                    let shouldFallback = await shouldFallbackToAppleSpeech(after: error)
                    if shouldFallback {
                        AppLogger.log(.warning, category: "transcription", event: "funasr_fallback_to_apple_speech", recordingId: recording.id?.uuidString, metadata: ["errorType": String(describing: type(of: error))])
                        segments = try await transcribeWithAppleSpeech(recording: recording, language: language)
                        actualEngine = .appleSpeech
                    } else {
                        throw error
                    }
                }
            }

            // Update engine to reflect what actually processed the audio (e.g. fallback)
            transcription.engine = Int16(actualEngine.rawValue)

            self.transcriptionProgress = 0

            guard !segments.isEmpty else {
                throw TranscriptionError.invalidAudioFormat
            }

            // Save segments
            for (index, segment) in segments.enumerated() {
                let seg = AIRecording.TranscriptionSegment(context: context)
                seg.id = UUID()
                seg.transcriptionId = transcription.id
                seg.transcription = transcription
                seg.startTime = segment.startTime
                seg.endTime = segment.endTime
                seg.text = segment.text
                seg.confidence = segment.confidence ?? 0
                seg.sequence = Int32(index)
                seg.speakerId = segment.speakerId
            }

            transcription.status = Int16(TranscriptionStatus.completed.rawValue)
            transcription.completedAt = Date()
            transcription.updatedAt = Date()

            // Calculate average confidence
            let confidences = segments.compactMap { $0.confidence }
            if !confidences.isEmpty {
                transcription.confidence = Double(confidences.reduce(0, +)) / Double(confidences.count)
            }

            persistence.saveContext()

            return transcription
        } catch {
            self.transcriptionProgress = 0

            transcription.status = Int16(TranscriptionStatus.failed.rawValue)
            transcription.errorMessage = error.localizedDescription
            transcription.updatedAt = Date()
            do {
                try context.save()
            } catch {
                AppLogger.log(.error, category: "transcription", event: "transcription_failure_state_save_failed", metadata: ["errorType": String(describing: type(of: error))])
            }
            throw error
        }
    }

    private func selectedEngine() -> TranscriptionEngine {
        let raw = UserDefaults.standard.integer(forKey: "transcription.engine")
        let preferred = TranscriptionEngine(rawValue: raw) ?? .appleSpeech

        // If FunASR API key is configured, prefer it over Apple Speech because:
        // - It supports speaker diarization
        // - It does not depend on Siri / Dictation system settings
        if !funASRAPIKey.isEmpty {
            return .funASR
        }

        return preferred
    }

    private func transcribeWithAppleSpeech(recording: Recording, language: String?) async throws -> [TranscriptionSegmentDTO] {
        let hasPermission = await requestPermission()
        guard hasPermission else {
            AppLogger.log(.error, category: "transcription", event: "speech_permission_denied")
            throw TranscriptionError.permissionDenied
        }
        AppLogger.log(.info, category: "transcription", event: "speech_permission_granted")

        let totalDuration = TimeInterval(recording.duration)
        return try await performRecognition(recording: recording, language: language, totalDuration: totalDuration)
    }

    private func performRecognition(recording: Recording, language: String?, totalDuration: TimeInterval) async throws -> [TranscriptionSegmentDTO] {
        guard let path = recording.filePath else {
            AppLogger.log(.error, category: "transcription", event: "audio_filepath_missing")
            throw TranscriptionError.audioFileNotFound(path: "")
        }
        let fileURL = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLogger.log(.error, category: "transcription", event: "audio_file_not_found", metadata: ["fileExtension": fileURL.pathExtension])
            throw TranscriptionError.audioFileNotFound(path: fileURL.path)
        }

        AppLogger.log(.info, category: "transcription", event: "audio_file_validated", metadata: ["fileExtension": fileURL.pathExtension, "durationSeconds": totalDuration])

        // SFSpeechRecognizer is most reliable with WAV/MP3; normalize CAF/M4A first.
        let requestURL: URL
        if shouldConvertForAppleSpeech(fileExtension: fileURL.pathExtension) {
            AppLogger.log(.info, category: "transcription", event: "wav_conversion_started", metadata: ["fileExtension": fileURL.pathExtension])
            requestURL = try await convertToRecognitionWAV(inputURL: fileURL)
            AppLogger.log(.debug, category: "transcription", event: "wav_conversion_ready", metadata: ["fileExtension": requestURL.pathExtension])

            // Validate WAV file is non-trivial
            if let attrs = try? FileManager.default.attributesOfItem(atPath: requestURL.path),
               let fileSize = attrs[.size] as? UInt64 {
                AppLogger.log(.debug, category: "transcription", event: "wav_file_size", metadata: ["sizeBytes": Int(fileSize)])
                if fileSize < 1024 {
                    AppLogger.log(.warning, category: "transcription", event: "wav_file_suspiciously_small", metadata: ["sizeBytes": Int(fileSize)])
                    throw TranscriptionError.invalidAudioFormat
                }
            }
        } else {
            requestURL = fileURL
        }

        let recognizer: SFSpeechRecognizer
        if let lang = language, lang != "auto" {
            guard let locale = Locale(identifier: lang) as Locale?,
                  let r = SFSpeechRecognizer(locale: locale) else {
                AppLogger.log(.error, category: "transcription", event: "language_not_supported", metadata: ["language": lang])
                throw TranscriptionError.languageNotSupported(language: lang)
            }
            recognizer = r
        } else {
            // Default to Chinese or English based on system locale
            let preferredLocale = Locale(identifier: "zh-CN")
            recognizer = SFSpeechRecognizer(locale: preferredLocale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        }

        AppLogger.log(.debug, category: "transcription", event: "recognizer_configured", metadata: ["locale": recognizer.locale.identifier, "isAvailable": recognizer.isAvailable])

        guard recognizer.isAvailable else {
            AppLogger.log(.error, category: "transcription", event: "recognizer_unavailable")
            throw TranscriptionError.engineNotAvailable
        }

        // Retry logic: try on-device first, fall back to cloud.
        // Error 1107 (kAFAssistantErrorDomain) is a known transient failure — retry with delay.
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            let useOnDevice = (attempt == 1) // First attempt: on-device (more reliable)
            AppLogger.log(.debug, category: "transcription", event: "recognition_attempt", metadata: ["attempt": attempt, "maxAttempts": maxAttempts, "onDevice": useOnDevice])

            let request = SFSpeechURLRecognitionRequest(url: requestURL)
            request.requiresOnDeviceRecognition = useOnDevice
            request.shouldReportPartialResults = true

            do {
                let segments = try await runRecognitionTask(recognizer: recognizer, request: request, totalDuration: totalDuration)
                return segments
            } catch {
                lastError = error

                // Unwrap the underlying NSError from TranscriptionError.recognitionFailed
                let underlyingError: NSError
                if let te = error as? TranscriptionError,
                   case .recognitionFailed(let inner) = te {
                    underlyingError = inner as NSError
                } else {
                    underlyingError = error as NSError
                }
                AppLogger.log(.warning, category: "transcription", event: "recognition_attempt_failed", metadata: ["attempt": attempt, "errorDomain": underlyingError.domain, "nsCode": underlyingError.code])

                // Check if it's a retryable error (1107 or similar transient)
                let isRetryable = underlyingError.code == 1107
                    || underlyingError.code == 1101
                    || underlyingError.code == 203
                let isSiriDisabled = isSiriDisabledError(underlyingError)

                if isSiriDisabled {
                    throw TranscriptionError.siriDisabled
                }

                if attempt < maxAttempts && isRetryable {
                    let delay = UInt64(attempt * 2) * 1_000_000_000 // 2s, 4s
                    AppLogger.log(.warning, category: "transcription", event: "recognition_retry", metadata: ["attempt": attempt, "delaySeconds": attempt * 2])
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    throw error
                }
            }
        }

        throw lastError ?? TranscriptionError.recognitionFailed(underlying: NSError(domain: "Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: "All retry attempts failed"]))
    }

    func shouldConvertForAppleSpeech(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return ext != "wav" && ext != "mp3"
    }

    private func runRecognitionTask(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest, totalDuration: TimeInterval) async throws -> [TranscriptionSegmentDTO] {
        return try await withCheckedThrowingContinuation { continuation in
            var segments: [TranscriptionSegmentDTO] = []
            var hasResumed = false

            // Timeout guard: if the recognizer produces no final result or error,
            // force-cancel and resume with a timeout error.
            let timeoutSeconds: TimeInterval = max(totalDuration * 3, 60)
            let timeoutWork = DispatchWorkItem {
                guard !hasResumed else { return }
                hasResumed = true
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
                DispatchQueue.main.async {
                    self.transcriptionProgress = 0
                }
                AppLogger.log(.error, category: "transcription", event: "recognition_timeout", metadata: ["timeoutSeconds": timeoutSeconds])
                continuation.resume(throwing: TranscriptionError.timeout(duration: timeoutSeconds))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                timeoutWork.cancel()
                guard !hasResumed else { return }

                if let error = error {
                    AppLogger.log(.error, category: "transcription", event: "recognition_failed", metadata: ["errorType": String(describing: type(of: error)), "errorDomain": (error as NSError).domain, "nsCode": (error as NSError).code])
                    hasResumed = true
                    DispatchQueue.main.async {
                        self.transcriptionProgress = 0
                    }
                    if self.isSiriDisabledError(error) {
                        continuation.resume(throwing: TranscriptionError.siriDisabled)
                    } else {
                        continuation.resume(throwing: TranscriptionError.recognitionFailed(underlying: error))
                    }
                    return
                }

                guard let result = result else {
                    // Intermediate state — recognizer hasn't produced a result yet.
                    // Don't resume; wait for the next callback.
                    AppLogger.log(.debug, category: "transcription", event: "recognition_intermediate_callback")
                    return
                }

                // Accumulate segments from partial results as well
                if !result.isFinal {
                    segments = result.bestTranscription.segments.map { segment in
                        TranscriptionSegmentDTO(
                            startTime: segment.timestamp,
                            endTime: segment.timestamp + segment.duration,
                            text: segment.substring,
                            confidence: segment.confidence,
                            speakerId: nil
                        )
                    }
                    if totalDuration > 0 {
                        let lastSegment = result.bestTranscription.segments.last
                        let currentTime = (lastSegment?.timestamp ?? 0) + (lastSegment?.duration ?? 0)
                        let progress = min(currentTime / totalDuration, 1.0)
                        DispatchQueue.main.async {
                            self.transcriptionProgress = progress
                        }
                    }
                    AppLogger.log(.debug, category: "transcription", event: "recognition_partial_result", metadata: ["segmentCount": segments.count])
                    return
                }

                // Final result
                hasResumed = true
                DispatchQueue.main.async {
                    self.transcriptionProgress = 0
                }
                segments = result.bestTranscription.segments.map { segment in
                    TranscriptionSegmentDTO(
                        startTime: segment.timestamp,
                        endTime: segment.timestamp + segment.duration,
                        text: segment.substring,
                        confidence: segment.confidence,
                        speakerId: nil
                    )
                }
                AppLogger.log(.info, category: "transcription", event: "recognition_completed", metadata: ["segmentCount": segments.count])
                continuation.resume(returning: segments)
            }
        }
    }

    private func convertToRecognitionWAV(inputURL: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AIRecording/transcoding", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let wavURL = tempDir.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + "_16k.wav")

        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            AppLogger.log(.error, category: "transcription", event: "audio_file_read_failed", metadata: ["errorType": String(describing: type(of: error)), "fileExtension": inputURL.pathExtension])
            throw TranscriptionError.audioFileCorrupted(path: inputURL.path)
        }
        let inputFormat = inputFile.processingFormat
        AppLogger.log(.debug, category: "transcription", event: "wav_conversion_input_format", metadata: ["sampleRate": inputFormat.sampleRate, "channels": Int(inputFormat.channelCount)])

        // SFSpeechRecognizer and Fun-ASR both work best with 16000 Hz mono Int16.
        // High-resolution WAVs (e.g. 48000 Hz stereo) are huge; downsampling locally
        // avoids uploading multiple gigabytes over the network.
        let targetSampleRate: Double = 16000
        let targetChannels = 1

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: true
        ) else {
            AppLogger.log(.error, category: "transcription", event: "wav_output_format_create_failed")
            throw TranscriptionError.invalidAudioFormat
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: wavURL,
                settings: outputSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            AppLogger.log(.error, category: "transcription", event: "wav_file_create_failed", metadata: ["errorType": String(describing: type(of: error))])
            throw TranscriptionError.invalidAudioFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            AppLogger.log(.error, category: "transcription", event: "wav_converter_create_failed", metadata: ["inputSampleRate": inputFormat.sampleRate, "inputChannels": Int(inputFormat.channelCount), "outputSampleRate": outputFormat.sampleRate, "outputChannels": Int(outputFormat.channelCount)])
            throw TranscriptionError.invalidAudioFormat
        }

        let inputBufferSize: AVAudioFrameCount = 4096
        var totalOutputFrames: AVAudioFrameCount = 0

        while true {
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputBufferSize) else {
                AppLogger.log(.error, category: "transcription", event: "wav_input_buffer_alloc_failed")
                break
            }

            do {
                try inputFile.read(into: inputBuffer)
            } catch {
                AppLogger.log(.error, category: "transcription", event: "wav_read_failed", metadata: ["errorType": String(describing: type(of: error))])
                break
            }

            guard inputBuffer.frameLength > 0 else { break }

            // Allocate output buffer with capacity scaled for sample-rate conversion
            let outputCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * (targetSampleRate / inputFormat.sampleRate) + 10
            )
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                AppLogger.log(.error, category: "transcription", event: "wav_output_buffer_alloc_failed")
                break
            }

            // Proper AVAudioConverter input block: track whether we have provided
            // the buffer for this conversion call. The converter may invoke the
            // block multiple times; after the first call we must return nil and
            // set status to .noDataNow.
            var hasProvidedInput = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if hasProvidedInput {
                    status.pointee = .noDataNow
                    return nil
                }
                hasProvidedInput = true
                status.pointee = .haveData
                return inputBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let conversionError = conversionError {
                AppLogger.log(.error, category: "transcription", event: "wav_conversion_failed", metadata: ["errorDomain": conversionError.domain, "nsCode": conversionError.code])
                throw TranscriptionError.recognitionFailed(underlying: conversionError)
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
                totalOutputFrames += outputBuffer.frameLength
            }

            if status == .endOfStream {
                break
            }
        }

        AppLogger.log(.info, category: "transcription", event: "wav_conversion_completed", metadata: ["outputFrames": Int(totalOutputFrames), "sampleRate": targetSampleRate, "channels": targetChannels, "fileExtension": wavURL.pathExtension])
        return wavURL
    }

    func cancelTranscription() {
        recognitionTask?.cancel()
        recognitionTask = nil
        transcriptionProgress = 0
    }

    // MARK: - Fallback Policy

    /// Determines whether a FunASR failure should trigger an automatic fallback to Apple Speech.
    /// We avoid fallback for configuration errors (bad API key, upload failures) so the user
    /// sees the real error instead of a confusing secondary failure.
    private func shouldFallbackToAppleSpeech(after error: Error) async -> Bool {
        // If Apple Speech itself is unavailable (no Siri / Dictation), don't bother.
        let appleAvailable = SFSpeechRecognizer.authorizationStatus() == .authorized
            && SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.isAvailable == true
        guard appleAvailable else { return false }

        // Unwrap underlying error
        let underlying: NSError
        if let te = error as? TranscriptionError,
           case .recognitionFailed(let inner) = te {
            underlying = inner as NSError
        } else {
            underlying = error as NSError
        }

        // Do NOT fallback for known configuration / client errors
        let nonRetryableCodes = [401, 403, 404, 422]
        let isClientError = underlying.domain == "FunASR"
            && nonRetryableCodes.contains(underlying.code)

        let isUploadFailure = underlying.localizedDescription.contains("文件上传失败")
            || underlying.localizedDescription.contains("无法解析文件上传响应")

        if isClientError || isUploadFailure {
            AppLogger.log(.info, category: "transcription", event: "funasr_fallback_skipped", metadata: ["errorDomain": underlying.domain, "nsCode": underlying.code])
            return false
        }

        return true
    }

    // MARK: - Siri Disabled Error Detection

    /// Checks whether an Apple Speech error is caused by Siri / Dictation being disabled.
    /// Maps common underlying errors to user-friendly Chinese descriptions.
    static func localizedErrorDescription(for error: Error) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription.lowercased()

        if message.contains("app transport security") || message.contains("secure connection") || message.contains("ats") {
            return "网络连接被安全策略阻止，请检查网络设置后重试。"
        }

        if message.contains("siri and dictation are disabled") || message.contains("dictation is disabled") {
            return "Siri 和听写功能已关闭。请前往 系统设置 > Apple Intelligence 与 Siri > 打开 Siri，或在设置中切换到 Fun-ASR 引擎（支持说话人分割，无需 Siri）。"
        }

        if message.contains("no speech detected") || message.contains("no speech") {
            return "未检测到语音内容，请确认录音包含有效音频。"
        }

        if message.contains("network") || message.contains("internet") || message.contains("connection") {
            return "网络连接异常，请检查网络后重试。"
        }

        return "语音识别失败：\(nsError.localizedDescription)"
    }

    private func isSiriDisabledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let message = nsError.localizedDescription.lowercased()
        // Be precise: match the exact known error or domain-specific failures
        return message.contains("siri and dictation are disabled")
            || message.contains("dictation is disabled")
            || nsError.domain == "SiriAuth"
    }
}

struct TranscriptionSegmentDTO {
    let startTime: Double
    let endTime: Double
    let text: String
    let confidence: Float?
    let speakerId: String?
}

// MARK: - Fun-ASR Support

extension TranscriptionService {

    private var funASRAPIKey: String {
        UserDefaults.standard.string(forKey: "funasr.apiKey") ?? ""
    }

    private func transcribeWithFunASR(recording: Recording, language: String?) async throws -> [TranscriptionSegmentDTO] {
        guard !funASRAPIKey.isEmpty else {
            throw TranscriptionError.engineNotAvailable
        }

        guard let path = recording.filePath else {
            throw TranscriptionError.audioFileNotFound(path: "")
        }
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.audioFileNotFound(path: fileURL.path)
        }

        // Ensure WAV format for transcription. For MP3 we keep the original
        // compressed file to avoid inflating upload size; for CAF/WAV we
        // normalize to 16 kHz mono, which dramatically reduces upload size
        // for high-resolution WAVs and is what both engines prefer.
        let wavURL: URL
        let ext = fileURL.pathExtension.lowercased()
        if ext == "mp3" {
            wavURL = fileURL
        } else {
            wavURL = try await convertToRecognitionWAV(inputURL: fileURL)
        }

        // Load OSS config
        let ossConfig = OSSConfig(
            accessKeyId: UserDefaults.standard.string(forKey: "oss.accessKeyId") ?? "",
            accessKeySecret: UserDefaults.standard.string(forKey: "oss.accessKeySecret") ?? "",
            bucket: UserDefaults.standard.string(forKey: "oss.bucket") ?? "",
            endpoint: UserDefaults.standard.string(forKey: "oss.endpoint") ?? ""
        )
        guard ossConfig.isValid else {
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "OSS", code: -1, userInfo: [NSLocalizedDescriptionKey: "OSS 未配置，请在设置中填写 AccessKey、Bucket 和 Endpoint"]))
        }

        let presigner = OSSPresigner(config: ossConfig)
        let objectKey = "recordings/\(recording.id?.uuidString ?? UUID().uuidString)-\(Int(Date().timeIntervalSince1970)).wav"
        var uploadedToOSS = false

        do {
            // Step 1: Upload file to OSS
            await MainActor.run { self.transcriptionProgress = 0.10 }
            try await uploadToOSS(fileURL: wavURL, objectKey: objectKey, presigner: presigner)
            uploadedToOSS = true

            // Step 2: Generate GET presigned URL for FunASR to download
            await MainActor.run { self.transcriptionProgress = 0.25 }
            guard let getURL = presigner.presignedURL(objectKey: objectKey, method: "GET", expiration: 3600) else {
                throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "OSS", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成 OSS 下载 URL 失败"]))
            }

            // Step 3: Submit transcription task using the OSS URL
            let taskID = try await submitTranscriptionTask(fileURL: getURL.absoluteString, language: language)

            // Step 4: Poll for results
            let segments = try await pollTaskResult(taskID: taskID, recordingDuration: TimeInterval(recording.duration))

            // Step 5: Clean up OSS object
            try? await deleteOSSObject(objectKey: objectKey, presigner: presigner)

            return segments
        } catch {
            if uploadedToOSS {
                try? await deleteOSSObject(objectKey: objectKey, presigner: presigner)
            }
            throw error
        }
    }

    /// Uploads a file to OSS using a presigned PUT URL with retry logic and file-based streaming.
    /// Retries up to 2 attempts on retryable HTTP errors (403, 5xx, timeouts) by regenerating the presigned URL each time.
    private func uploadToOSS(fileURL: URL, objectKey: String, presigner: OSSPresigner) async throws {
        let maxAttempts = 2
        var lastError: Error?

        for attempt in 1...maxAttempts {
            guard let putURL = presigner.presignedURL(objectKey: objectKey, method: "PUT", contentType: "audio/wav") else {
                throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "OSS", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成 OSS 上传 URL 失败"]))
            }

            var uploadRequest = URLRequest(url: putURL)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

            do {
                // Use uploadTask(fromFile:) to stream from disk instead of loading into memory
                let (responseData, uploadResponse) = try await URLSession.shared.upload(for: uploadRequest, fromFile: fileURL)
                guard let httpResponse = uploadResponse as? HTTPURLResponse else {
                    throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "OSS", code: -1, userInfo: [NSLocalizedDescriptionKey: "OSS 上传无响应"]))
                }
                if httpResponse.statusCode == 200 {
                    AppLogger.log(.info, category: "transcription", event: "funasr_oss_upload_completed")
                    return
                }

                // Determine if this status code is retryable
                let isRetryable = isRetryableHTTPStatus(httpResponse.statusCode)
                let status = httpResponse.statusCode
                let responseBody = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
                let error = TranscriptionError.recognitionFailed(underlying: NSError(domain: "OSS", code: status, userInfo: [NSLocalizedDescriptionKey: "OSS 文件上传失败 (HTTP \(status))"]))

                if attempt < maxAttempts && isRetryable {
                    AppLogger.log(.warning, category: "transcription", event: "funasr_oss_upload_retry", metadata: ["attempt": attempt, "maxAttempts": maxAttempts, "httpStatus": status])
                    lastError = error
                    // Small delay before retry to allow transient auth issues to settle
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                } else {
                    AppLogger.log(.error, category: "transcription", event: "oss_upload_failed",
                                  message: responseBody,
                                  metadata: ["attempt": attempt, "httpStatus": status, "maxAttempts": maxAttempts,
                                             "isRetryable": isRetryable])
                    throw error
                }
            } catch let urlError as URLError {
                // Network-level errors are generally retryable
                if attempt < maxAttempts {
                    AppLogger.log(.warning, category: "transcription", event: "funasr_oss_upload_network_retry", metadata: ["attempt": attempt, "maxAttempts": maxAttempts, "errorType": String(describing: type(of: urlError)), "nsCode": urlError.errorCode])
                    lastError = urlError
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                } else {
                    throw TranscriptionError.recognitionFailed(underlying: urlError)
                }
            } catch {
                // Non-retryable errors (e.g., file not found) should not be retried
                throw error
            }
        }

        AppLogger.log(.error, category: "transcription", event: "oss_upload_all_retries_exhausted",
                      metadata: ["maxAttempts": maxAttempts])
        throw lastError ?? TranscriptionError.recognitionFailed(underlying: NSError(domain: "OSS", code: -1, userInfo: [NSLocalizedDescriptionKey: "OSS 上传全部重试失败"]))
    }

    internal func isRetryableHTTPStatus(_ status: Int) -> Bool {
        // 403 can be transient signature/auth issues; 5xx are server-side; 408/429/502/503/504 are retryable
        switch status {
        case 403, 408, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    private func deleteOSSObject(objectKey: String, presigner: OSSPresigner) async {
        guard let deleteURL = presigner.presignedURL(objectKey: objectKey, method: "DELETE") else { return }
        var deleteRequest = URLRequest(url: deleteURL)
        deleteRequest.httpMethod = "DELETE"
        do {
            let (_, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
            if let httpResponse = deleteResponse as? HTTPURLResponse {
                AppLogger.log(.info, category: "transcription", event: "funasr_oss_delete_completed", metadata: ["httpStatus": httpResponse.statusCode])
            }
        } catch {
            AppLogger.log(.warning, category: "transcription", event: "funasr_oss_delete_failed", metadata: ["errorType": String(describing: type(of: error))])
        }
    }

    // MARK: Step 1: Upload

    private func uploadFileToDashScope(fileURL: URL) async throws -> String {
        // Early validation: API key must be non-empty
        let apiKey = funASRAPIKey
        guard !apiKey.isEmpty else {
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "API Key 未配置，请在设置中填写 DashScope API Key"]))
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/files")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = createMultipartBody(boundary: boundary, fileURL: fileURL)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 data>"
        AppLogger.log(.debug, category: "transcription", event: "funasr_file_upload_response", metadata: ["httpStatus": (response as? HTTPURLResponse)?.statusCode ?? 0])

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(rawBody.prefix(500))
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: status, userInfo: [NSLocalizedDescriptionKey: "文件上传失败 (HTTP \(status)): \(snippet)"]))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(rawBody.prefix(500))
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件上传响应不是有效 JSON: \(snippet)"]))
        }

        // Hardened parsing: try multiple known DashScope response shapes
        let urlString = extractUploadedFileURL(from: json)
        guard let url = urlString else {
            let snippet = String(rawBody.prefix(500))
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析文件上传响应，原始响应: \(snippet)"]))
        }

        return url
    }

    /// Attempts to extract the uploaded file URL from various known DashScope response shapes.
    private func extractUploadedFileURL(from json: [String: Any]) -> String? {
        // Shape 1: output.uploaded_files[0].url
        if let output = json["output"] as? [String: Any],
           let uploadedFiles = output["uploaded_files"] as? [[String: Any]],
           let firstFile = uploadedFiles.first,
           let url = firstFile["url"] as? String {
            return url
        }
        // Shape 2: output.uploaded_files[0].file_url
        if let output = json["output"] as? [String: Any],
           let uploadedFiles = output["uploaded_files"] as? [[String: Any]],
           let firstFile = uploadedFiles.first,
           let url = firstFile["file_url"] as? String {
            return url
        }
        // Shape 3: data.url
        if let data = json["data"] as? [String: Any],
           let url = data["url"] as? String {
            return url
        }
        // Shape 4: data.file_url
        if let data = json["data"] as? [String: Any],
           let url = data["file_url"] as? String {
            return url
        }
        // Shape 5: output.url
        if let output = json["output"] as? [String: Any],
           let url = output["url"] as? String {
            return url
        }
        // Shape 6: output.file_id (used as URL substitute in some APIs)
        if let output = json["output"] as? [String: Any],
           let fileID = output["file_id"] as? String {
            return fileID
        }
        // Shape 7: data.uploaded_files[0].file_id (observed DashScope response)
        if let data = json["data"] as? [String: Any],
           let uploadedFiles = data["uploaded_files"] as? [[String: Any]],
           let firstFile = uploadedFiles.first,
           let fileID = firstFile["file_id"] as? String {
            return fileID
        }
        return nil
    }

    private func createMultipartBody(boundary: String, fileURL: URL) -> Data {
        var body = Data()
        let filename = fileURL.lastPathComponent
        let mimeType = "audio/wav"

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)

        if let fileData = try? Data(contentsOf: fileURL) {
            body.append(fileData)
        }

        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    // MARK: Step 2: Submit Task

    private func submitTranscriptionTask(fileURL: String, language: String?) async throws -> String {
        let apiKey = funASRAPIKey
        guard !apiKey.isEmpty else {
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "API Key 未配置，请在设置中填写 DashScope API Key"]))
        }

        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")

        let lang = language ?? "auto"
        var parameters: [String: Any] = [
            "language": lang == "auto" ? "zh" : lang,
            "diarization_enabled": true,
            "enable_punctuation": true
        ]
        let speakerCount = UserDefaults.standard.integer(forKey: "transcription.speakerCount")
        if speakerCount > 0 {
            parameters["speaker_count"] = speakerCount
        }
        let body: [String: Any] = [
            "model": "fun-asr",
            "input": [
                "file_urls": [fileURL]
            ],
            "parameters": parameters
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 data>"
        AppLogger.log(.debug, category: "transcription", event: "funasr_task_submit_response", metadata: ["httpStatus": (response as? HTTPURLResponse)?.statusCode ?? 0])

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(rawBody.prefix(500))
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: status, userInfo: [NSLocalizedDescriptionKey: "提交转写任务失败 (HTTP \(status)): \(snippet)"]))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(rawBody.prefix(500))
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "任务提交响应不是有效 JSON: \(snippet)"]))
        }

        let taskID = extractTaskID(from: json)
        guard let id = taskID else {
            let snippet = String(rawBody.prefix(500))
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析任务提交响应，原始响应: \(snippet)"]))
        }

        return id
    }

    /// Attempts to extract the task ID from various known DashScope response shapes.
    private func extractTaskID(from json: [String: Any]) -> String? {
        // Shape 1: output.task_id
        if let output = json["output"] as? [String: Any],
           let taskID = output["task_id"] as? String {
            return taskID
        }
        // Shape 2: data.task_id
        if let data = json["data"] as? [String: Any],
           let taskID = data["task_id"] as? String {
            return taskID
        }
        // Shape 3: output.id
        if let output = json["output"] as? [String: Any],
           let id = output["id"] as? String {
            return id
        }
        // Shape 4: data.id
        if let data = json["data"] as? [String: Any],
           let id = data["id"] as? String {
            return id
        }
        return nil
    }

    // MARK: Step 3: Poll Result

    private func pollTaskResult(taskID: String, recordingDuration: TimeInterval) async throws -> [TranscriptionSegmentDTO] {
        let apiKey = funASRAPIKey
        guard !apiKey.isEmpty else {
            throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "API Key 未配置，请在设置中填写 DashScope API Key"]))
        }

        let pollURL = URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(taskID)")!
        let startTime = Date()
        let timeout: TimeInterval = 300 // 5 minutes
        let interval: TimeInterval = 2

        while Date().timeIntervalSince(startTime) < timeout {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            var request = URLRequest(url: pollURL)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")

            let (data, response) = try await URLSession.shared.data(for: request)

            let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 data>"
            AppLogger.log(.debug, category: "transcription", event: "funasr_task_poll_response", metadata: ["httpStatus": (response as? HTTPURLResponse)?.statusCode ?? 0])

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let snippet = String(rawBody.prefix(500))
                throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: status, userInfo: [NSLocalizedDescriptionKey: "查询任务失败 (HTTP \(status)): \(snippet)"]))
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let snippet = String(rawBody.prefix(500))
                throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "任务状态响应不是有效 JSON: \(snippet)"]))
            }

            // Update progress based on elapsed time vs estimated duration
            let elapsed = Date().timeIntervalSince(startTime)
            let estimated = max(recordingDuration * 2, 10)
            let progress = min(0.20 + (elapsed / estimated) * 0.70, 0.90)
            await MainActor.run { self.transcriptionProgress = progress }

            // Check task status with hardened parsing
            let taskStatus = extractTaskStatus(from: json)
            if let status = taskStatus {
                if status == "SUCCEEDED" {
                    await MainActor.run { self.transcriptionProgress = 1.0 }
                    // FunASR returns transcription_url(s) in the task result; download them first
                    let transcriptionURLs = extractTranscriptionURLs(from: json)
                    guard !transcriptionURLs.isEmpty else {
                        throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "转写成功但未找到结果 URL"]))
                    }
                    var allSegments: [TranscriptionSegmentDTO] = []
                    for urlString in transcriptionURLs {
                        guard let url = URL(string: urlString) else { continue }
                        let (transcriptionData, _) = try await URLSession.shared.data(from: url)
                        guard let transcriptionJson = try? JSONSerialization.jsonObject(with: transcriptionData) as? [String: Any] else {
                            AppLogger.log(.warning, category: "transcription", event: "funasr_result_parse_failed")
                            continue
                        }
                        let segments = parseFunASRResult(json: transcriptionJson)
                        allSegments.append(contentsOf: segments)
                    }
                    return allSegments
                } else if status == "FAILED" {
                    let message = extractTaskErrorMessage(from: json) ?? "转写任务失败"
                    throw TranscriptionError.recognitionFailed(underlying: NSError(domain: "FunASR", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
                }
                // PENDING or RUNNING: continue polling
            }
        }

        throw TranscriptionError.timeout(duration: timeout)
    }

    /// Extracts transcription URLs from FunASR task result.
    /// DashScope FunASR returns results with `transcription_url` fields.
    private func extractTranscriptionURLs(from json: [String: Any]) -> [String] {
        var urls: [String] = []
        // Shape 1: output.results[].transcription_url
        if let output = json["output"] as? [String: Any],
           let results = output["results"] as? [[String: Any]] {
            for result in results {
                if let url = result["transcription_url"] as? String {
                    urls.append(url)
                }
            }
        }
        // Shape 2: data.results[].transcription_url
        if urls.isEmpty, let data = json["data"] as? [String: Any],
           let results = data["results"] as? [[String: Any]] {
            for result in results {
                if let url = result["transcription_url"] as? String {
                    urls.append(url)
                }
            }
        }
        // Shape 3: output.result.transcription_url (Qwen-ASR single result)
        if urls.isEmpty, let output = json["output"] as? [String: Any],
           let result = output["result"] as? [String: Any],
           let url = result["transcription_url"] as? String {
            urls.append(url)
        }
        // Shape 4: output.transcription_url (direct)
        if urls.isEmpty, let output = json["output"] as? [String: Any],
           let url = output["transcription_url"] as? String {
            urls.append(url)
        }
        return urls
    }

    /// Attempts to extract the task status from various known DashScope response shapes.
    private func extractTaskStatus(from json: [String: Any]) -> String? {
        // Shape 1: output.task_status
        if let output = json["output"] as? [String: Any],
           let status = output["task_status"] as? String {
            return status
        }
        // Shape 2: data.task_status
        if let data = json["data"] as? [String: Any],
           let status = data["task_status"] as? String {
            return status
        }
        // Shape 3: output.status
        if let output = json["output"] as? [String: Any],
           let status = output["status"] as? String {
            return status
        }
        // Shape 4: data.status
        if let data = json["data"] as? [String: Any],
           let status = data["status"] as? String {
            return status
        }
        return nil
    }

    /// Attempts to extract an error message from various known DashScope response shapes.
    private func extractTaskErrorMessage(from json: [String: Any]) -> String? {
        // Shape 1: output.message
        if let output = json["output"] as? [String: Any],
           let message = output["message"] as? String {
            return message
        }
        // Shape 2: data.message
        if let data = json["data"] as? [String: Any],
           let message = data["message"] as? String {
            return message
        }
        // Shape 3: error.message
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    private func parseFunASRResult(json: [String: Any]) -> [TranscriptionSegmentDTO] {
        // FunASR transcription content structure:
        // { "transcripts": [{ "sentences": [{ "begin_time", "end_time", "text", "speaker_id" }] }] }
        guard let transcripts = json["transcripts"] as? [[String: Any]] else {
            AppLogger.log(.warning, category: "transcription", event: "funasr_result_transcripts_missing", metadata: ["jsonKeyCount": json.keys.count])
            return []
        }

        var segments: [TranscriptionSegmentDTO] = []
        var sequence = 0

        for transcript in transcripts {
            guard let sentences = transcript["sentences"] as? [[String: Any]] else { continue }
            for sentence in sentences {
                guard let text = sentence["text"] as? String else { continue }
                let beginTime = (sentence["begin_time"] as? Double) ?? 0
                let endTime = (sentence["end_time"] as? Double) ?? 0
                let speakerID = sentence["speaker_id"] as? Int ?? sentence["speakerId"] as? Int

                segments.append(TranscriptionSegmentDTO(
                    startTime: beginTime / 1000.0,
                    endTime: endTime / 1000.0,
                    text: text,
                    confidence: nil,
                    speakerId: speakerID.map { "Speaker \($0)" }
                ))
                sequence += 1
            }
        }

        return segments
    }
}
