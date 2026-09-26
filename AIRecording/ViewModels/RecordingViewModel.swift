import Foundation
import Combine

@MainActor
class RecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevels: [Float] = []

    private let recordingService = AudioRecordingService.shared
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init() {
        recordingService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)

        recordingService.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.updateAudioLevels(level)
            }
            .store(in: &cancellables)
    }

    private func handleStateChange(_ state: RecordingState) {
        switch state {
        case .recording:
            isRecording = true
            startTimer()
        case .idle, .error:
            isRecording = false
            stopTimer()
            recordingDuration = 0
            audioLevels = []
        default:
            break
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateAudioLevels(_ level: Float) {
        var levels = audioLevels
        levels.append(level)
        if levels.count > 60 {
            levels.removeFirst()
        }
        audioLevels = levels
    }
}
