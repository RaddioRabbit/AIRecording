import AVFoundation
import Combine

enum PlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case finished
    case error(AudioPlayerError)
}

enum AudioPlayerError: Error, Equatable {
    case fileNotFound
    case decodeFailed
    case playbackFailed

    static func == (lhs: AudioPlayerError, rhs: AudioPlayerError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound, .fileNotFound),
             (.decodeFailed, .decodeFailed),
             (.playbackFailed, .playbackFailed):
            return true
        default:
            return false
        }
    }
}

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published private(set) var state: PlayerState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private init() {}

    // MARK: - Playback Control

    func load(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlayerError.fileNotFound
        }

        await MainActor.run {
            state = .loading
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()

            self.player = player

            await MainActor.run {
                duration = player.duration
                currentTime = 0
                state = .idle
            }
        } catch {
            await MainActor.run {
                state = .error(.decodeFailed)
            }
            throw AudioPlayerError.decodeFailed
        }
    }

    func play() {
        guard let player = player else { return }

        if player.play() {
            state = .playing
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        state = .paused
        stopTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        state = .idle
        currentTime = 0
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        player.currentTime = max(0, min(time, duration))
        currentTime = player.currentTime
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.5, min(2.0, rate))
        player?.rate = playbackRate
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if !player.isPlaying {
                self.state = .finished
                self.stopTimer()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
