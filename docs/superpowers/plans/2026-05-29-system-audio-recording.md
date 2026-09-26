# 系统音频录制功能 Feature Ticket

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AIRecording macOS 应用中实现系统音频录制功能，支持麦克风/系统音频/混合三种录制源，录制后支持语音转文字。

**Architecture:** 复用现有 AVAudioEngine 架构，通过 SCContentSharingPicker / ScreenCaptureKit 捕获系统音频输出，与麦克风输入混合后写入同一 CAF 文件。录制源选择通过 UI Picker 和 UserDefaults 持久化。

**Tech Stack:** Swift, SwiftUI, AVFoundation, ScreenCaptureKit (macOS 13+), Core Data, Combine

---

## 目录

1. [需求澄清与范围](#1-需求澄清与范围)
2. [用户场景与核心流程](#2-用户场景与核心流程)
3. [数据模型变更](#3-数据模型变更)
4. [UI 变更点](#4-ui-变更点)
5. [技术方案](#5-技术方案)
6. [任务分解](#6-任务分解)
7. [验收标准](#7-验收标准)
8. [待确认问题](#8-待确认问题)
9. [优先级与里程碑](#9-优先级与里程碑)
10. [下游交付物](#10-下游交付物)

---

## 1. 需求澄清与范围

### 1.1 用户原始需求

1. 录制系统播放的声音（当前只能录麦克风）
2. 麦克风音频和系统音频都可以语音转文字
3. 设置中选择录制源：只录麦克风 / 只录系统 / 两者都录
4. "转成图表等等" — 需求模糊，需澄清

### 1.2 功能范围（In Scope）

| 功能 | 说明 |
|------|------|
| 系统音频录制 | 使用 ScreenCaptureKit 捕获系统音频输出 |
| 麦克风音频录制 | 现有功能，保持不变 |
| 混合录制 | 同时捕获麦克风和系统音频，混合为双声道或单声道 |
| 录制源选择 UI | NewRecordingView 中的 Picker，SettingsView 中的默认源设置 |
| 默认录制源设置 | 在设置中配置菜单栏一键录音的默认源 |
| 系统音频权限引导 | 首次使用系统音频时引导用户授权 |
| 转录兼容性 | 系统音频、混合音频录制后均可正常转录 |
| 录制列表标识 | 列表中显示每条录音的源类型（麦克风/系统/混合） |

### 1.3 非范围（Out of Scope）

| 功能 | 说明 |
|------|------|
| "转成图表等等" | **本次迭代不纳入**。现有 Chart 功能已存在于 `ChartPanelView` / `RecordingDetailView`，用户可能指此功能。待用户确认具体需求后再规划。详见 [待确认问题](#8-待确认问题)。 |
| 多文件分别存储 | 混合录制时麦克风和系统音频不分开存储为两个文件，统一混合为单个文件 |
| 实时音量独立显示 | 混合录制时不分别显示麦克风和系统音频的音量条，统一显示混合音量 |
| 扬声器回环消除 | 混合录制时不做回声消除处理 |
| 音频后处理（降噪/增益） | 保持原始 PCM 数据，不做额外处理 |
| 远程/网络音频流 | 不涉及网络音频传输 |

---

## 2. 用户场景与核心流程

### 2.1 场景 A：录制在线会议（系统音频）

用户参加 Zoom/Teams/腾讯会议，想录制会议中其他人的声音（系统音频输出）。

**流程：**
1. 用户点击菜单栏图标（或打开主窗口点击"新建录音"）
2. 在 `NewRecordingView` 中选择"系统音频"
3. 点击"开始录音"
4. 系统弹出 ScreenCaptureKit 权限请求（首次）
5. 用户选择要捕获的窗口/屏幕，确认后录音开始
6. 录音过程中波形条实时显示系统音频音量
7. 点击"停止录音"，录音保存到列表
8. 自动触发转录

### 2.2 场景 B：录制自己说话 + 会议声音（混合）

用户参加在线会议，想同时录制自己的声音（麦克风）和会议中其他人的声音（系统音频）。

**流程：**
1. 用户在 `NewRecordingView` 中选择"混合"
2. 点击"开始录音"
3. 系统同时请求麦克风权限和 ScreenCaptureKit 权限（按需）
4. 两个音频源混合后写入同一文件
5. 录音完成后自动转录

### 2.3 场景 C：菜单栏一键录音使用默认源

用户习惯通过菜单栏左键快速录音，不想每次选择源。

**流程：**
1. 用户在"设置" > "录音设置"中选择"默认录音源"
2. 菜单栏左键点击直接使用该源开始录音
3. 右键菜单中可选择临时切换源

### 2.4 场景 D：录制后转录系统音频内容

用户录制了一段视频/播放的音频，需要转录为文字。

**流程：**
1. 录音完成后自动触发转录（现有行为）
2. `TranscriptionService` 使用 SFSpeechRecognizer 处理系统音频文件
3. 转录结果与麦克风录音无差异

---

## 3. 数据模型变更

### 3.1 变更清单

**无需新增实体**，现有 `Recording` 实体的 `sourceType` 字段已支持三种值：

```swift
enum AudioSource: Int, CaseIterable {
    case microphone = 0   // 已有
    case systemAudio = 1  // 已有（当前未实现录制逻辑）
    case mixed = 2        // 已有（当前未实现录制逻辑）
}
```

**现有 `Recording.sourceType` 字段已定义，无需 Core Data 迁移。**

### 3.2 需要新增/修改的属性

| 位置 | 变更 | 说明 |
|------|------|------|
| `SettingsViewModel` | 新增 `defaultAudioSource: AudioSource` | 默认录音源，UserDefaults 持久化 |
| `RecordingConfiguration` | 无需变更 | 现有结构已足够 |
| `Recording` (Core Data) | 无需变更 | `sourceType` 已存在 |

### 3.3 新增 UserDefaults Keys

```swift
private let defaultAudioSourceKey = "recording.defaultAudioSource" // Int, rawValue of AudioSource
```

---

## 4. UI 变更点

### 4.1 NewRecordingView（已有 Picker，需增强）

**当前状态：** 已有 `Picker` 支持三种源选择，但 `AudioRecordingService` 只实现了 `.microphone`。

**变更：**
- 保持现有 Picker UI 不变
- 根据所选源显示不同的权限引导提示
- 系统音频/混合录制时显示额外提示："系统音频录制需要选择要捕获的窗口或屏幕"

### 4.2 SettingsView（新增默认源设置）

**变更：** 在"录音设置" Section 中新增：

```swift
Picker("默认录音源", selection: $viewModel.defaultAudioSource) {
    Text("麦克风").tag(AudioSource.microphone)
    Text("系统音频").tag(AudioSource.systemAudio)
    Text("混合").tag(AudioSource.mixed)
}
```

### 4.3 RecordingListView / RecordingRowView（新增源标识）

**变更：** 在录音列表行中显示源类型图标：

```swift
HStack(spacing: 8) {
    // 现有：日期、时长、转录状态
    // 新增：
    Image(systemName: recording.sourceIconName)
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

| AudioSource | 图标 | 提示 |
|-------------|------|------|
| microphone | `mic.fill` | 麦克风 |
| systemAudio | `speaker.wave.2.fill` | 系统音频 |
| mixed | `mic.and.signal.meter.fill` | 混合 |

### 4.4 RecordingDetailView（新增源标识）

**变更：** 在 Header 区域显示录音源类型标签：

```swift
Text(recording.sourceDisplayName)
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(Color.secondary.opacity(0.15))
    .cornerRadius(4)
```

### 4.5 MenuBarController（支持默认源）

**变更：**
- 左键点击使用 `SettingsViewModel.defaultAudioSource` 作为默认源
- 右键菜单中新增"选择录音源"子菜单（可选，如时间允许）

---

## 5. 技术方案

### 5.1 系统音频捕获方案（ScreenCaptureKit）

macOS 13+ 使用 `ScreenCaptureKit` 框架捕获系统音频：

```swift
import ScreenCaptureKit

// 1. 创建 SCContentSharingPicker 让用户选择要捕获的窗口/屏幕
let picker = SCContentSharingPicker.shared
picker.add(self)

// 2. 获取 SCShareableContent 后创建 SCStream
let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
let configuration = SCStreamConfiguration()
configuration.capturesAudio = true
configuration.excludesCurrentProcessAudio = true  // 不捕获自己 app 的声音

let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
try await stream.startCapture()
```

### 5.2 音频混合方案

**方案选择：AVAudioEngine + 多输入节点**

```swift
let engine = AVAudioEngine()

// 麦克风输入节点（已有）
let micInput = engine.inputNode

// 系统音频通过 ScreenCaptureKit 的 CMSampleBuffer 转换为 AVAudioPCMBuffer
// 然后写入到 AVAudioEngine 的辅助输入节点或手动混合

// 混合方案：使用 AVAudioMixerNode
let mixer = engine.mainMixerNode

// 麦克风连接到 mixer
micInput.connect(to: mixer, format: micInput.outputFormat(forBus: 0))

// 系统音频通过自定义节点或手动写入到 mixer
// 实际实现中，系统音频通过 SCStream 回调获取 CMSampleBuffer，
// 转换为 AVAudioPCMBuffer 后写入到 AVAudioFile
```

**简化方案（推荐）：**

由于 ScreenCaptureKit 和 AVAudioEngine 的集成较为复杂，采用**双源独立写入 + 后混合**方案：

1. 麦克风：通过 `AVAudioEngine.inputNode.installTap` 写入文件 A
2. 系统音频：通过 `SCStream` 回调获取 `CMSampleBuffer`，转换为 `AVAudioPCMBuffer` 写入文件 B
3. 停止录音后，使用 `AVAudioFile` + `AVAudioConverter` 将 A 和 B 混合为单个输出文件

**更简化的方案（实际推荐）：**

由于混合需要处理采样率、声道数对齐，且 Core Data 模型已支持单文件存储，采用**实时混合写入**方案：

- 创建一个 `AVAudioMixerNode` 作为输出节点
- 麦克风输入连接到 mixer
- 系统音频通过自定义 `AVAudioSourceNode` 生成，连接到 mixer
- mixer 安装 tap 写入单个文件

但 `AVAudioSourceNode` 需要实时提供音频数据，而 ScreenCaptureKit 是异步回调，集成复杂。

**最终推荐方案（ pragmatic ）：**

**方案 C：SCStream 直接写入 + 可选混合**

- 仅系统音频：SCStream 音频回调直接写入 CAF 文件
- 仅麦克风：现有逻辑不变
- 混合：同时启动麦克风和 SCStream，分别写入临时文件，停止后用 `AVAudioEngine` / `AVAudioFile` 混合为最终文件

此方案代码复杂度可控，且与现有架构兼容。

### 5.3 权限处理

| 源类型 | 所需权限 | 请求时机 |
|--------|----------|----------|
| microphone | `NSMicrophoneUsageDescription` | 首次录音时 |
| systemAudio | ScreenCaptureKit 用户选择 | 每次开始系统音频录制时 |
| mixed | 两者都需要 | 首次录音时 |

ScreenCaptureKit 的权限不是一次性授权，每次调用 `SCContentSharingPicker` 都需要用户选择捕获目标。

### 5.4 文件格式

- 所有录制源统一输出为 CAF 文件（与现有行为一致）
- 混合录制时输出为立体声（左声道麦克风，右声道系统音频）或单声道混合
- 转录前如需 WAV 转换，使用现有 `convertCAFToWAV` 方法

---

## 6. 任务分解

### 6.1 文件变更总览

**新建文件：**
- `AIRecording/Services/SystemAudioCaptureService.swift` — ScreenCaptureKit 封装
- `AIRecording/Services/AudioMixerService.swift` — 双源音频混合

**修改文件：**
- `AIRecording/Services/AudioRecordingService.swift` — 支持三种录制源
- `AIRecording/ViewModels/SettingsViewModel.swift` — 新增默认源设置
- `AIRecording/ViewModels/NewRecordingViewModel.swift` — 传递源配置
- `AIRecording/Views/SettingsView.swift` — 新增默认源 Picker
- `AIRecording/Views/RecordingListView.swift` — 源类型图标
- `AIRecording/Views/RecordingDetailView.swift` — 源类型标签
- `AIRecording/Models/Recording.swift` — 新增 display 辅助属性
- `AIRecording/App/MenuBarController.swift` — 使用默认源
- `AIRecording/Info.plist` — 新增 `NSScreenCaptureUsageDescription`

---

### Task 1: SystemAudioCaptureService — ScreenCaptureKit 封装

**Files:**
- Create: `AIRecording/Services/SystemAudioCaptureService.swift`
- Test: `Tests/AIRecordingTests/SystemAudioCaptureServiceTests.swift`

- [ ] **Step 1: 定义协议和错误类型**

```swift
import ScreenCaptureKit
import AVFoundation
import Combine

enum SystemAudioError: Error, Equatable {
    case permissionDenied
    case noContentSelected
    case streamStartFailed(underlying: Error)
    case audioConversionFailed
    case notRunning
}

protocol SystemAudioCaptureProtocol {
    var isRunning: Bool { get }
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }
    func startCapture(to fileURL: URL, sampleRate: Double, channels: Int) async throws
    func stopCapture() async throws -> URL
}
```

- [ ] **Step 2: 实现 SystemAudioCaptureService**

```swift
@MainActor
class SystemAudioCaptureService: NSObject, ObservableObject, SystemAudioCaptureProtocol {
    static let shared = SystemAudioCaptureService()

    @Published private(set) var isRunning = false
    private let audioLevelSubject = CurrentValueSubject<Float, Never>(0.0)
    var audioLevelPublisher: AnyPublisher<Float, Never> { audioLevelSubject.eraseToAnyPublisher() }

    private var stream: SCStream?
    private var outputFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?

    private override init() { super.init() }

    func startCapture(to fileURL: URL, sampleRate: Double, channels: Int) async throws {
        guard !isRunning else { return }

        // Request content via SCContentSharingPicker
        let content = try await requestShareableContent()
        guard let display = content.displays.first else {
            throw SystemAudioError.noContentSelected
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream

        // Setup audio output file
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true)!
        self.audioFormat = format
        self.outputFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
        try await stream.startCapture()

        isRunning = true
    }

    func stopCapture() async throws -> URL {
        guard let stream = stream else { throw SystemAudioError.notRunning }
        await stream.stopCapture()
        self.stream = nil
        let fileURL = outputFile?.url
        outputFile = nil
        isRunning = false
        guard let url = fileURL else { throw SystemAudioError.notRunning }
        return url
    }

    private func requestShareableContent() async throws -> SCShareableContent {
        return try await SCShareableContent.current
    }

    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.int16ChannelData?[0] {
            for i in 0..<frameLength {
                sum += abs(Float(data[i]))
            }
            let average = sum / Float(frameLength) / Float(Int16.max)
            let db = 20 * log10(max(average, 0.00001))
            return max(0, min(1, (db + 60) / 60))
        }
        return 0
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let audioBufferList = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer and write
        // This is a simplified placeholder — actual implementation needs
        // CMSampleBuffer -> AudioBufferList -> AVAudioPCMBuffer conversion
        Task { @MainActor in
            // Write to outputFile
        }
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
    }
}
```

- [ ] **Step 3: 编写测试**

```swift
import XCTest
@testable import AIRecording

final class SystemAudioCaptureServiceTests: XCTestCase {
    func testSingleton() {
        let a = SystemAudioCaptureService.shared
        let b = SystemAudioCaptureService.shared
        XCTAssertTrue(a === b)
    }

    func testInitialState() {
        let service = SystemAudioCaptureService.shared
        XCTAssertFalse(service.isRunning)
    }
}
```

- [ ] **Step 4: 运行测试**

```bash
swift test --filter SystemAudioCaptureServiceTests
```

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Services/SystemAudioCaptureService.swift Tests/AIRecordingTests/SystemAudioCaptureServiceTests.swift
git commit -m "feat: add SystemAudioCaptureService with ScreenCaptureKit"
```

---

### Task 2: AudioMixerService — 双源混合

**Files:**
- Create: `AIRecording/Services/AudioMixerService.swift`
- Test: `Tests/AIRecordingTests/AudioMixerServiceTests.swift`

- [ ] **Step 1: 实现音频混合服务**

```swift
import AVFoundation

enum AudioMixError: Error {
    case fileNotFound
    case formatMismatch
    case mixFailed(underlying: Error)
}

class AudioMixerService {
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

        // Use AVAudioEngine for mixing
        let engine = AVAudioEngine()
        let playerA = AVAudioPlayerNode()
        let playerB = AVAudioPlayerNode()
        let mixer = engine.mainMixerNode

        engine.attach(playerA)
        engine.attach(playerB)

        engine.connect(playerA, to: mixer, format: inputFileA.processingFormat)
        engine.connect(playerB, to: mixer, format: inputFileB.processingFormat)

        // Install tap on mixer to write to output
        mixer.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { buffer, _ in
            do {
                try outputFile.write(from: buffer)
            } catch {
                print("Mix write error: \(error)")
            }
        }

        try engine.start()

        playerA.scheduleFile(inputFileA, at: nil, completionHandler: nil)
        playerB.scheduleFile(inputFileB, at: nil, completionHandler: nil)

        playerA.play()
        playerB.play()

        // Wait for playback to complete
        while playerA.isPlaying || playerB.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        mixer.removeTap(onBus: 0)
        engine.stop()

        // Clean up temp files
        try? FileManager.default.removeItem(at: fileA)
        try? FileManager.default.removeItem(at: fileB)
    }
}
```

- [ ] **Step 2: 编写测试**

```swift
import XCTest
@testable import AIRecording

final class AudioMixerServiceTests: XCTestCase {
    func testSingleton() {
        XCTAssertTrue(AudioMixerService.shared === AudioMixerService.shared)
    }

    func testMixFilesMissingInput() async {
        let tempDir = FileManager.default.temporaryDirectory
        let fakeA = tempDir.appendingPathComponent("fakeA.caf")
        let fakeB = tempDir.appendingPathComponent("fakeB.caf")
        let output = tempDir.appendingPathComponent("output.caf")

        do {
            _ = try await AudioMixerService.shared.mixFiles(
                fileA: fakeA, fileB: fakeB, outputURL: output,
                sampleRate: 44100, channels: 1
            )
            XCTFail("Should throw fileNotFound")
        } catch let error as AudioMixError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 3: 运行测试**

```bash
swift test --filter AudioMixerServiceTests
```

- [ ] **Step 4: Commit**

```bash
git add AIRecording/Services/AudioMixerService.swift Tests/AIRecordingTests/AudioMixerServiceTests.swift
git commit -m "feat: add AudioMixerService for dual-source mixing"
```

---

### Task 3: AudioRecordingService — 支持三种录制源

**Files:**
- Modify: `AIRecording/Services/AudioRecordingService.swift`
- Test: `Tests/AIRecordingTests/AudioRecordingServiceTests.swift`

- [ ] **Step 1: 重构 startRecording 以支持多源**

在 `AudioRecordingService` 中新增系统音频和混合录制的分支逻辑：

```swift
// 在 AudioRecordingService 中新增：
private var systemAudioService = SystemAudioCaptureService.shared
private var tempMicFileURL: URL?
private var tempSystemFileURL: URL?

func startRecording(configuration: RecordingConfiguration, source: AudioSource) async throws -> Recording {
    guard case .idle = state else {
        throw RecordingError.alreadyRecording
    }

    switch source {
    case .microphone:
        return try await startMicrophoneRecording(configuration: configuration)
    case .systemAudio:
        return try await startSystemAudioRecording(configuration: configuration)
    case .mixed:
        return try await startMixedRecording(configuration: configuration)
    }
}

private func startSystemAudioRecording(configuration: RecordingConfiguration) async throws -> Recording {
    // 类似 startMicrophoneRecording，但调用 systemAudioService.startCapture
}

private func startMixedRecording(configuration: RecordingConfiguration) async throws -> Recording {
    // 同时启动麦克风和系统音频，分别写入临时文件
    // 停止时调用 AudioMixerService 混合
}
```

- [ ] **Step 2: 重构 stopRecording 以处理混合**

```swift
func stopRecording() async throws -> Recording {
    guard let recording = currentRecording else {
        throw RecordingError.notRecording
    }

    let source = AudioSource(rawValue: Int(recording.sourceType)) ?? .microphone

    switch source {
    case .microphone:
        return try await stopMicrophoneRecording()
    case .systemAudio:
        return try await stopSystemAudioRecording()
    case .mixed:
        return try await stopMixedRecording()
    }
}

private func stopMixedRecording() async throws -> Recording {
    // 1. 停止麦克风录制
    // 2. 停止系统音频录制
    // 3. 调用 AudioMixerService.mixFiles
    // 4. 更新 recording.filePath 为混合后的文件
    // 5. 清理临时文件
}
```

- [ ] **Step 3: 更新现有调用点**

修改 `NewRecordingViewModel.startRecording()`：

```swift
let config = RecordingConfiguration(
    sampleRate: 44100,
    channels: selectedSource == .microphone ? 1 : 2,
    bitDepth: 16,
    format: .caf
)
_ = try await recordingService.startRecording(configuration: config, source: selectedSource)
```

修改 `MenuBarController.toggleRecording()`：

```swift
let source = SettingsViewModel().defaultAudioSource
let config = RecordingConfiguration.default
_ = try await recordingService.startRecording(configuration: config, source: source)
```

- [ ] **Step 4: 运行测试**

```bash
swift test --filter AudioRecordingServiceTests
swift build
```

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Services/AudioRecordingService.swift AIRecording/ViewModels/NewRecordingViewModel.swift AIRecording/App/MenuBarController.swift
git commit -m "feat: AudioRecordingService supports microphone/system/mixed sources"
```

---

### Task 4: SettingsViewModel + SettingsView — 默认录音源

**Files:**
- Modify: `AIRecording/ViewModels/SettingsViewModel.swift`
- Modify: `AIRecording/Views/SettingsView.swift`

- [ ] **Step 1: SettingsViewModel 新增默认源**

```swift
@MainActor
class SettingsViewModel: ObservableObject {
    // ... existing properties ...

    @Published var defaultAudioSource: AudioSource = .microphone

    private let defaultAudioSourceKey = "recording.defaultAudioSource"

    func loadSettings() {
        // ... existing load ...
        if let raw = defaults.object(forKey: defaultAudioSourceKey) as? Int,
           let source = AudioSource(rawValue: raw) {
            defaultAudioSource = source
        } else {
            defaultAudioSource = .microphone
        }
    }

    func saveSettings() {
        // ... existing save ...
        defaults.set(defaultAudioSource.rawValue, forKey: defaultAudioSourceKey)
    }
}
```

- [ ] **Step 2: SettingsView 新增 Picker**

```swift
Section("录音设置") {
    // ... existing pickers ...

    Picker("默认录音源", selection: $viewModel.defaultAudioSource) {
        Text("麦克风").tag(AudioSource.microphone)
        Text("系统音频").tag(AudioSource.systemAudio)
        Text("混合").tag(AudioSource.mixed)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add AIRecording/ViewModels/SettingsViewModel.swift AIRecording/Views/SettingsView.swift
git commit -m "feat: add default audio source setting"
```

---

### Task 5: Recording 模型 + 列表/详情 UI — 源类型标识

**Files:**
- Modify: `AIRecording/Models/Recording.swift`
- Modify: `AIRecording/Views/RecordingListView.swift`
- Modify: `AIRecording/Views/RecordingDetailView.swift`

- [ ] **Step 1: Recording 新增 display 属性**

```swift
extension Recording {
    var sourceTypeEnum: AudioSource {
        return AudioSource(rawValue: Int(sourceType)) ?? .microphone
    }

    var sourceDisplayName: String {
        switch sourceTypeEnum {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统音频"
        case .mixed: return "混合"
        }
    }

    var sourceIconName: String {
        switch sourceTypeEnum {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .mixed: return "mic.and.signal.meter.fill"
        }
    }
}
```

- [ ] **Step 2: RecordingRowView 新增图标**

```swift
HStack(spacing: 8) {
    Text(recording.formattedDate)
    Text("·")
    Text(recording.formattedDuration)
    Text("·")
    Image(systemName: recording.sourceIconName)
        .font(.caption2)
        .foregroundStyle(.secondary)
    // ... transcription status ...
}
```

- [ ] **Step 3: RecordingDetailView Header 新增标签**

```swift
VStack(spacing: 4) {
    Text(recording.displayTitle)
        .font(.headline)
    HStack(spacing: 8) {
        Text("\(recording.formattedDate) · \(recording.formattedDuration)")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(recording.sourceDisplayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add AIRecording/Models/Recording.swift AIRecording/Views/RecordingListView.swift AIRecording/Views/RecordingDetailView.swift
git commit -m "feat: display audio source type in list and detail views"
```

---

### Task 6: Info.plist + 权限描述

**Files:**
- Modify: `AIRecording/Info.plist`

- [ ] **Step 1: 新增 ScreenCaptureKit 权限描述**

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>AI录音助手需要捕获系统音频以录制电脑播放的声音。</string>
```

- [ ] **Step 2: Commit**

```bash
git add AIRecording/Info.plist
git commit -m "chore: add NSScreenCaptureUsageDescription for system audio"
```

---

### Task 7: 集成测试与端到端验证

**Files:**
- Test: `Tests/AIRecordingTests/AudioSourceIntegrationTests.swift`

- [ ] **Step 1: 编写集成测试**

```swift
import XCTest
@testable import AIRecording

final class AudioSourceIntegrationTests: XCTestCase {
    func testAudioSourceEnumValues() {
        XCTAssertEqual(AudioSource.microphone.rawValue, 0)
        XCTAssertEqual(AudioSource.systemAudio.rawValue, 1)
        XCTAssertEqual(AudioSource.mixed.rawValue, 2)
    }

    func testRecordingSourceTypeRoundTrip() {
        // Verify Core Data can store and retrieve all source types
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        for source in AudioSource.allCases {
            let recording = Recording(context: context)
            recording.id = UUID()
            recording.sourceType = Int16(source.rawValue)
            recording.createdAt = Date()
            recording.status = Int16(RecordingStatus.completed.rawValue)
            recording.isDeletedValue = false
        }

        controller.saveContext()

        let request: NSFetchRequest<Recording> = Recording.fetchRequest()
        let results = try? context.fetch(request)
        XCTAssertEqual(results?.count, AudioSource.allCases.count)
    }
}
```

- [ ] **Step 2: 运行全部测试**

```bash
swift test
swift build
```

- [ ] **Step 3: Commit**

```bash
git add Tests/AIRecordingTests/AudioSourceIntegrationTests.swift
git commit -m "test: add audio source integration tests"
```

---

## 7. 验收标准

### 7.1 功能验收

| # | 验收项 | 验收方法 | 通过标准 |
|---|--------|----------|----------|
| A1 | 麦克风录制 | 选择"麦克风"开始录音，停止后播放 | 录制正常，声音清晰，转录成功 |
| A2 | 系统音频录制 | 选择"系统音频"开始录音，播放一段视频/音乐，停止后播放 | 录制到系统播放的声音，转录成功 |
| A3 | 混合录制 | 选择"混合"开始录音，同时说话和播放视频，停止后播放 | 同时包含麦克风和系统音频，转录成功 |
| A4 | 默认源设置 | 在设置中选择"系统音频"为默认，菜单栏左键录音 | 使用系统音频源直接开始录音 |
| A5 | 列表标识 | 录制三条不同源的录音，查看列表 | 每条显示正确的源图标 |
| A6 | 详情标识 | 打开任意录音详情 | Header 显示源类型标签 |
| A7 | 权限引导 | 首次使用系统音频录制 | 弹出 ScreenCaptureKit 选择器，用户可选择屏幕/窗口 |

### 7.2 技术验收

| # | 验收项 | 验收方法 | 通过标准 |
|---|--------|----------|----------|
| T1 | 编译通过 | `swift build` | 无编译错误 |
| T2 | 测试通过 | `swift test` | 全部测试通过 |
| T3 | 无第三方依赖 | 检查 `Package.swift` | 未新增任何 SPM 依赖 |
| T4 | Core Data 兼容 | 检查 `PersistenceController` | 无需迁移，现有数据不受影响 |
| T5 | macOS 13 兼容 | 检查 API 使用 | 仅使用 macOS 13+ 公开 API |

### 7.3 用户体验验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| U1 | 源切换流畅 | 录音前切换源无卡顿 |
| U2 | 错误提示清晰 | 权限被拒绝、无音频输入时有明确提示 |
| U3 | 波形显示正常 | 三种源的录音过程中波形条均正常显示 |
| U4 | 菜单栏行为一致 | 菜单栏左键/右键行为与之前一致，仅源选择变化 |

---

## 8. 待确认问题

以下问题需要用户/CEO 确认：

| # | 问题 | 建议方案 | 影响 |
|---|------|----------|------|
| Q1 | **"转成图表等等"具体指什么？** | 现有 Chart 功能已存在于 `RecordingDetailView`，用户可能指此。建议确认是否需要新增图表类型或修改现有功能。 | 如确认需新增，需单独规划 Chart 增强 Feature Ticket |
| Q2 | 混合录制时输出声道布局？ | 建议方案：单声道混合（两路音频相加平均）。备选：立体声（左=麦克风，右=系统音频）。 | 影响 `AudioMixerService` 实现 |
| Q3 | 系统音频是否排除本 App 声音？ | 建议方案：`excludesCurrentProcessAudio = true`，不录制本 App 播放的声音。 | 影响 `SCStreamConfiguration` |
| Q4 | 是否需要录制特定应用而非整个系统？ | 建议方案：Phase 1 仅支持整个系统音频（通过 SCContentSharingPicker 用户自选窗口/屏幕）。Phase 2 可支持应用级过滤。 | 影响范围边界 |
| Q5 | 混合录制时是否需要分别显示两路音量？ | 建议方案：Phase 1 仅显示混合后的单一音量条。Phase 2 可分别显示。 | 影响 UI 复杂度 |

---

## 9. 优先级与里程碑

### Phase 1: MVP（建议本次迭代完成）

| 优先级 | 任务 | 预估工时 |
|--------|------|----------|
| P0 | Task 1: SystemAudioCaptureService | 1d |
| P0 | Task 3: AudioRecordingService 多源支持 | 1d |
| P0 | Task 4: 默认源设置 | 0.5d |
| P0 | Task 5: UI 源标识 | 0.5d |
| P0 | Task 6: Info.plist 权限 | 0.25d |
| P1 | Task 2: AudioMixerService | 1d |
| P1 | Task 7: 集成测试 | 0.5d |

**Phase 1 总计：约 5 个工作日**

### Phase 2: 增强（后续迭代）

- 应用级音频过滤（只录某个 App）
- 混合录制时独立音量显示
- 立体声分离布局（左=麦克风，右=系统音频）
- 系统音频录制时自动排除通知声

### Phase 3: 图表功能（待确认后规划）

- 如 Q1 确认需新增图表功能，单独产出 Feature Ticket

---

## 10. 下游交付物

### 交给 claude-xd-lead（设计）

- **目标用户与核心场景**：在线会议录制、播客/视频录制、混合会议录制
- **功能范围**：三种录制源（麦克风/系统/混合），列表和详情页源标识，设置页默认源
- **非范围**：图表功能（待确认）、应用级过滤、独立音量显示
- **关键流程**：NewRecordingView 源选择 -> 权限请求 -> 录音 -> 列表显示 -> 详情播放
- **交互目标**：源切换流畅、权限引导清晰、列表一眼识别录音类型
- **UI 变更点**：
  - `NewRecordingView`: 保持现有 Picker，新增系统音频权限提示文案
  - `SettingsView`: 新增"默认录音源" Picker
  - `RecordingListView`: 行内新增源类型图标
  - `RecordingDetailView`: Header 新增源类型标签
- **验收标准**：见第 7 节

### 交给 claude-cp-arch（实现）

- **PRD/Feature Ticket**：本文档
- **数据与状态约束**：
  - `Recording.sourceType` 已支持 `Int16`，三种枚举值已定义
  - 无需 Core Data 迁移
  - 新增 `defaultAudioSource` UserDefaults key
- **接口边界**：
  - `AudioRecordingService.startRecording(configuration:source:)` — 新增 `source` 参数
  - `SystemAudioCaptureService` — 新建，封装 ScreenCaptureKit
  - `AudioMixerService` — 新建，双文件混合
- **外部依赖**：ScreenCaptureKit（系统框架，macOS 13+）
- **验收标准**：见第 7 节
- **里程碑**：Phase 1（5个工作日）-> 系统音频录制可用

---

*Feature Ticket 版本: 1.0*
*日期: 2026-05-29*
*作者: claude-cp-lead*
