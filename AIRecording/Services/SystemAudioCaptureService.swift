@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import Combine
import CoreGraphics

enum SystemAudioError: Error, Equatable, LocalizedError {
    case permissionDenied
    case noContentSelected
    case streamStartFailed(underlying: Error)
    case audioConversionFailed
    case notRunning
    case screenCaptureAccessDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "屏幕录制权限被拒绝。请在系统设置 > 隐私与安全性 > 屏幕录制中开启权限。"
        case .noContentSelected:
            return "未找到可捕获的系统音频源。请确保已选择要录制的屏幕或窗口。"
        case .streamStartFailed(let underlying):
            return "音频流启动失败: \(underlying.localizedDescription)"
        case .audioConversionFailed:
            return "音频格式转换失败。"
        case .notRunning:
            return "系统音频捕获未运行。"
        case .screenCaptureAccessDenied:
            return "无法访问屏幕录制。请在系统设置 > 隐私与安全性 > 屏幕录制中允许本应用，然后完全退出应用（Cmd+Q）并重新打开。"
        }
    }

    var localizedDescription: String {
        errorDescription ?? "系统音频录制发生未知错误。"
    }

    static func == (lhs: SystemAudioError, rhs: SystemAudioError) -> Bool {
        switch (lhs, rhs) {
        case (.permissionDenied, .permissionDenied): return true
        case (.noContentSelected, .noContentSelected): return true
        case (.streamStartFailed(let a), .streamStartFailed(let b)): return a.localizedDescription == b.localizedDescription
        case (.audioConversionFailed, .audioConversionFailed): return true
        case (.notRunning, .notRunning): return true
        case (.screenCaptureAccessDenied, .screenCaptureAccessDenied): return true
        default: return false
        }
    }
}

protocol SystemAudioCaptureProtocol: AnyObject {
    var isRunning: Bool { get }
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }
    func startCapture(to fileURL: URL) async throws
    func stopCapture() async throws -> URL
}

// MARK: - Thread-safe file handle for audio writes

/// Isolates the AVAudioFile behind an NSLock so that the SCStream
/// capture callback (captureQueue) and the writeQueue can safely
/// access the file without data races.
///
/// Output format is Float32 interleaved — matches SCStream's native
/// format to eliminate Int16 quantization noise.
private final class AudioFileHandle: @unchecked Sendable {
    private var outputFile: AVAudioFile?
    private var fileURL: URL?
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.airecording.filewrite", qos: .userInitiated)

    /// Store the URL for deferred file creation.
    func setURL(_ url: URL) {
        lock.lock()
        fileURL = url
        lock.unlock()
    }

    /// Create the output file on first buffer. Float32 interleaved.
    /// Must hold no external locks when calling this (it acquires lock internally).
    func createFileIfNeeded(sampleRate: Double, channels: Int) throws {
        lock.lock()
        guard outputFile == nil, let url = fileURL else {
            lock.unlock()
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: true)
        outputFile = file
        lock.unlock()
    }

    /// Convert non-interleaved Float32 to interleaved if needed, then write.
    func write(buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = outputFile
        lock.unlock()

        guard let audioFile = file else { return }

        var bufferToWrite = buffer
        if !buffer.format.isInterleaved, let floatData = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            guard let interleavedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                         sampleRate: buffer.format.sampleRate,
                                                         channels: buffer.format.channelCount,
                                                         interleaved: true),
                  let interleavedBuffer = AVAudioPCMBuffer(pcmFormat: interleavedFormat,
                                                            frameCapacity: buffer.frameCapacity),
                  let dest = interleavedBuffer.floatChannelData else { return }
            interleavedBuffer.frameLength = buffer.frameLength
            for frame in 0..<frames {
                for ch in 0..<channels {
                    dest[0][frame * channels + ch] = floatData[ch][frame]
                }
            }
            bufferToWrite = interleavedBuffer
        }

        writeQueue.async { [bufferToWrite] in
            do {
                try audioFile.write(from: bufferToWrite)
            } catch {
                AppLogger.log(.warning, category: "recording", event: "system_audio_write_failed",
                              metadata: ["errorType": String(describing: type(of: error))])
            }
        }
    }

    var url: URL? {
        lock.lock()
        let u = outputFile?.url ?? fileURL
        lock.unlock()
        return u
    }

    func clearFile() {
        lock.lock()
        outputFile = nil
        fileURL = nil
        lock.unlock()
    }
}

// MARK: - SystemAudioCaptureService

@MainActor
final class SystemAudioCaptureService: NSObject, ObservableObject, SystemAudioCaptureProtocol {
    static let shared = SystemAudioCaptureService()

    @Published private(set) var isRunning = false
    var audioLevelPublisher: AnyPublisher<Float, Never> { audioLevelSubject.eraseToAnyPublisher() }

    private var stream: SCStream?
    private let fileHandle = AudioFileHandle()
    nonisolated(unsafe) private let audioLevelSubject = CurrentValueSubject<Float, Never>(0.0)
    private let captureQueue = DispatchQueue(label: "com.airecording.systemaudio", qos: .userInitiated)

    private override init() { super.init() }

    func startCapture(to fileURL: URL) async throws {
        guard !isRunning else { return }

        // Pre-check screen capture access using the native API (macOS 10.15+)
        if !CGPreflightScreenCaptureAccess() {
            throw SystemAudioError.screenCaptureAccessDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch let error as NSError {
            let isAccessDenied = (error.domain == "com.apple.ScreenCaptureKit" && error.code == -1)
            if isAccessDenied {
                throw SystemAudioError.screenCaptureAccessDenied
            }
            throw SystemAudioError.streamStartFailed(underlying: error)
        }

        guard let display = content.displays.first else {
            throw SystemAudioError.noContentSelected
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream

        // Defer file creation — we don't know SCStream's actual sample rate yet.
        // The file will be created on the first audio callback using the real format.
        fileHandle.setURL(fileURL)

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()

        isRunning = true
    }

    func stopCapture() async throws -> URL {
        guard let stream = stream else { throw SystemAudioError.notRunning }
        try await stream.stopCapture()
        self.stream = nil
        let fileURL = fileHandle.url
        fileHandle.clearFile()
        isRunning = false
        guard let url = fileURL else { throw SystemAudioError.notRunning }
        return url
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        guard let sourceFormat = AVAudioFormat(streamDescription: asbd) else { return }

        let frameLength = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameLength > 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let dataLength = CMBlockBufferGetDataLength(blockBuffer)
        guard dataLength > 0 else { return }

        // Create PCM buffer in source format and copy raw bytes
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                   frameCapacity: AVAudioFrameCount(frameLength)) else { return }
        sourceBuffer.frameLength = AVAudioFrameCount(frameLength)

        let copyLength: Int
        if sourceFormat.isInterleaved {
            copyLength = min(dataLength,
                             Int(frameLength) * Int(sourceFormat.streamDescription.pointee.mBytesPerFrame))
        } else {
            // Non-interleaved: total bytes across all channels
            copyLength = min(dataLength,
                             Int(frameLength) * Int(sourceFormat.streamDescription.pointee.mBytesPerFrame))
        }

        let dest: UnsafeMutableRawPointer
        if let int16Data = sourceBuffer.int16ChannelData {
            dest = UnsafeMutableRawPointer(int16Data[0])
        } else if let floatData = sourceBuffer.floatChannelData {
            dest = UnsafeMutableRawPointer(floatData[0])
        } else { return }

        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                                 dataLength: copyLength, destination: dest)
        guard status == noErr else { return }

        // Lazily create output file on first buffer (Float32 interleaved, lossless)
        do {
            try fileHandle.createFileIfNeeded(
                sampleRate: sourceFormat.sampleRate,
                channels: Int(sourceFormat.channelCount)
            )
        } catch {
            AppLogger.log(.error, category: "recording", event: "system_audio_output_file_failed",
                          metadata: ["errorType": String(describing: Swift.type(of: error))])
            return
        }

        // Calculate and publish audio level directly (CurrentValueSubject is thread-safe)
        let level = Self.calculateAudioLevel(from: sourceBuffer)
        audioLevelSubject.send(level)

        // Write — AudioFileHandle converts non-interleaved to interleaved internally
        fileHandle.write(buffer: sourceBuffer)
    }

    private nonisolated static func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let floatData = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(floatData[i])
            }
            let average = sum / Float(frameLength)
            let db = 20 * log10(max(average, 0.00001))
            return max(0, min(1, (db + 60) / 60))
        } else if let int16Data = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(Float(int16Data[i]))
            }
            let average = sum / Float(frameLength) / Float(Int16.max)
            let db = 20 * log10(max(average, 0.00001))
            return max(0, min(1, (db + 60) / 60))
        }
        return 0
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.isRunning = false
        }
    }
}
