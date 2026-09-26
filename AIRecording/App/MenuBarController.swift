import AppKit
import SwiftUI
import Combine

@MainActor
class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recentRecordings: [Recording] = []

    private var durationTimer: Timer?
    private let recordingService = AudioRecordingService.shared
    private let persistence = PersistenceController.shared

    override init() {
        super.init()
        setupStatusItem()
        bindRecordingService()
        loadRecentRecordings()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "AI Recording")
            button.image?.size = NSSize(width: 18, height: 18)
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func bindRecordingService() {
        recordingService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleRecordingStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleRecordingStateChange(_ state: RecordingState) {
        switch state {
        case .recording:
            isRecording = true
            startDurationTimer()
            updateMenuBarIcon(recording: true)
        case .idle, .error:
            isRecording = false
            stopDurationTimer()
            recordingDuration = 0
            updateMenuBarIcon(recording: false)
            loadRecentRecordings()
        default:
            break
        }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingDuration += 1
                self?.updateMenuBarTitle()
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem.button else { return }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        let timeString = formatter.string(from: recordingDuration) ?? "00:00"
        button.title = isRecording ? " \(timeString)" : ""
    }

    private func updateMenuBarIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = recording ? "record.circle.fill" : "mic.circle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AI Recording")
        button.image?.size = NSSize(width: 18, height: 18)
        if recording {
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
        updateMenuBarTitle()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleRecording()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        // Recording toggle item
        let recordItem = NSMenuItem(
            title: isRecording ? "停止录音" : "开始录音",
            action: #selector(toggleRecordingFromMenu),
            keyEquivalent: ""
        )
        recordItem.target = self
        menu.addItem(recordItem)

        if isRecording {
            let durationItem = NSMenuItem(
                title: "录音时长: \(formatDuration(recordingDuration))",
                action: nil,
                keyEquivalent: ""
            )
            durationItem.isEnabled = false
            menu.addItem(durationItem)
        } else {
            // Audio source submenu
            let sourceMenu = NSMenu()
            let defaultSource = SettingsViewModel().defaultAudioSource

            for source in AudioSource.allCases {
                let item = NSMenuItem(
                    title: source.displayName,
                    action: #selector(selectSourceFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = source.rawValue
                if source == defaultSource {
                    item.state = .on
                }
                sourceMenu.addItem(item)
            }

            let sourceItem = NSMenuItem(title: "录音源", action: nil, keyEquivalent: "")
            sourceItem.submenu = sourceMenu
            menu.addItem(sourceItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Recent recordings
        menu.addItem(NSMenuItem(title: "最近录音", action: nil, keyEquivalent: ""))

        if recentRecordings.isEmpty {
            let emptyItem = NSMenuItem(title: "暂无录音", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for recording in recentRecordings.prefix(5) {
                let title = recording.customTitle ?? recording.title ?? "未命名录音"
                let dateStr = formatDate(recording.createdAt)
                let item = NSMenuItem(title: "\(title) (\(dateStr))", action: #selector(openRecording(_:)), keyEquivalent: "")
                item.representedObject = recording
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Open main window
        let openItem = NSMenuItem(title: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        // Settings
        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRecordingFromMenu(_ sender: NSMenuItem) {
        toggleRecording()
    }

    private var selectedMenuSource: AudioSource?

    @objc private func selectSourceFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let source = AudioSource(rawValue: rawValue) else { return }
        selectedMenuSource = source
    }

    private func toggleRecording() {
        Task {
            do {
                if isRecording {
                    try await recordingService.stopRecording()
                } else {
                    let source = selectedMenuSource ?? SettingsViewModel().defaultAudioSource
                    let config = RecordingConfiguration.default
                    _ = try await recordingService.startRecording(configuration: config, source: source)
                    selectedMenuSource = nil
                }
            } catch {
                AppLogger.log(.error, category: "recording", event: "recording_toggle_failed",
                              metadata: ["errorType": String(describing: type(of: error))])
            }
        }
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let recording = sender.representedObject as? Recording else { return }
        openMainWindow()
        // Post notification to open specific recording
        NotificationCenter.default.post(name: .openRecordingDetail, object: recording.objectID)
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.isVisible || !$0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        openMainWindow()
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func loadRecentRecordings() {
        let context = persistence.container.viewContext
        let request: NSFetchRequest<Recording> = Recording.fetchRequest()
        request.predicate = NSPredicate(format: "isDeletedValue == false")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = 10

        do {
            recentRecordings = try context.fetch(request)
        } catch {
            recentRecordings = []
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00:00"
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension Notification.Name {
    static let openRecordingDetail = Notification.Name("openRecordingDetail")
    static let openSettings = Notification.Name("openSettings")
}
