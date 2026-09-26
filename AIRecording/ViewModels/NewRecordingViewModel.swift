import Foundation
import Combine
import AppKit

@MainActor
class NewRecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPreparing = false
    @Published var selectedSource: AudioSource = .microphone
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevels: [Float] = []
    @Published var errorMessage: String?

    var formattedDuration: String {
        let totalSeconds = Int(recordingDuration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private let recordingService = AudioRecordingService.shared
    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?

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

    func startRecording() async {
        guard !isRecording else { return }

        isPreparing = true
        errorMessage = nil

        do {
            let defaults = UserDefaults.standard
            let sampleRate = defaults.double(forKey: "recording.sampleRate")
            let channels = selectedSource == .microphone ? 1 : max(1, defaults.integer(forKey: "recording.channels"))
            let formatString = defaults.string(forKey: "recording.format") ?? "caf"
            let format = RecordingFormat(rawValue: formatString) ?? .caf

            let config = RecordingConfiguration(
                sampleRate: sampleRate > 0 ? sampleRate : 44100,
                channels: channels,
                bitDepth: 16,
                format: format
            )
            _ = try await recordingService.startRecording(configuration: config, source: selectedSource)
            isPreparing = false
        } catch {
            isPreparing = false
            var message = "开始录音失败: \(error.localizedDescription)"
            if let systemError = error as? SystemAudioError,
               systemError == .screenCaptureAccessDenied {
                message += "\n\n已自动打开系统设置，请开启权限后完全退出应用（Cmd+Q）并重新打开。"
                // macOS 15+ merged Screen Recording and System Audio into
                // "录屏与系统录音". Try the new pane first, fallback to the old one.
                let urls = [
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_RecordScreen",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                ]
                for urlString in urls {
                    if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                        break
                    }
                }
            }
            errorMessage = message
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        do {
            _ = try await recordingService.stopRecording()
        } catch {
            errorMessage = "停止录音失败: \(error.localizedDescription)"
        }
    }

    private func handleStateChange(_ state: RecordingState) {
        switch state {
        case .preparing:
            isPreparing = true
        case .recording:
            isRecording = true
            isPreparing = false
            startDurationTimer()
        case .stopping:
            isPreparing = false
        case .idle:
            isRecording = false
            isPreparing = false
            stopDurationTimer()
            recordingDuration = 0
            audioLevels = []
        case .error(let error):
            isRecording = false
            isPreparing = false
            stopDurationTimer()
            errorMessage = "录音错误: \(error)"
        default:
            break
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingDuration += 1
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
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
