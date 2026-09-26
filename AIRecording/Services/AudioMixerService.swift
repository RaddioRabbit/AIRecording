import AVFoundation

enum AudioMixError: Error, Equatable {
    case fileNotFound
    case formatMismatch
    case mixFailed(underlying: Error)

    static func == (lhs: AudioMixError, rhs: AudioMixError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound, .fileNotFound): return true
        case (.formatMismatch, .formatMismatch): return true
        case (.mixFailed(let a), .mixFailed(let b)): return a.localizedDescription == b.localizedDescription
        default: return false
        }
    }
}

@MainActor
final class AudioMixerService {
    static let shared = AudioMixerService()

    private init() {}

    /// Mix two audio files into a single output file.
    /// - Parameters:
    ///   - fileA: First input file URL (e.g., microphone)
    ///   - fileB: Second input file URL (e.g., system audio)
    ///   - outputURL: Output file URL
    ///   - sampleRate: Target sample rate
    ///   - channels: Target channel count (1 = mixed mono, 2 = stereo with A=left, B=right)
    func mixFiles(fileA: URL, fileB: URL, outputURL: URL, sampleRate: Double, channels: Int) async throws {
        guard FileManager.default.fileExists(atPath: fileA.path),
              FileManager.default.fileExists(atPath: fileB.path) else {
            throw AudioMixError.fileNotFound
        }

        let inputFileA = try AVAudioFile(forReading: fileA)
        let inputFileB = try AVAudioFile(forReading: fileB)

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: true)!

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ], commonFormat: .pcmFormatInt16, interleaved: true)

        let engine = AVAudioEngine()
        let playerA = AVAudioPlayerNode()
        let playerB = AVAudioPlayerNode()
        let mixer = engine.mainMixerNode

        engine.attach(playerA)
        engine.attach(playerB)

        engine.connect(playerA, to: mixer, format: inputFileA.processingFormat)
        engine.connect(playerB, to: mixer, format: inputFileB.processingFormat)

        mixer.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { buffer, _ in
            do {
                try outputFile.write(from: buffer)
            } catch {
                AppLogger.log(.warning, category: "recording", event: "mix_write_failed",
                              metadata: ["errorType": String(describing: type(of: error))])
            }
        }

        try engine.start()

        playerA.scheduleFile(inputFileA, at: nil, completionHandler: nil)
        playerB.scheduleFile(inputFileB, at: nil, completionHandler: nil)

        playerA.play()
        playerB.play()

        while playerA.isPlaying || playerB.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        mixer.removeTap(onBus: 0)
        engine.stop()
    }
}
