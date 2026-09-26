# Feature Ticket: Audio Import (音频导入)

## 1. 目标用户与核心场景

### 目标用户
- **现有用户**：已使用 AIRecording 进行麦克风/系统音频录制，但需要从外部来源（如会议录音、采访录音、语音备忘录导出等）补充历史音频到同一工作流。
- **新用户**：已有大量本地音频文件（.wav / .mp3），希望利用 AIRecording 的转录、AI 纪要、智能图表能力进行分析，而不必重新录制。

### 核心场景
1. **会议录音归档**：用户收到第三方会议软件导出的 .wav/.mp3，导入后自动转录并生成纪要/图表。
2. **批量历史整理**：用户从语音备忘录或录音笔导出多个文件，逐个导入到 AIRecording 统一管理。
3. **跨设备协作**：同事发送音频文件，用户导入后使用 AI 纪要提取行动项和决策。

---

## 2. 功能范围 (In Scope)

| 编号 | 功能项 | 说明 |
|------|--------|------|
| F-1 | 导入入口 | 在 `RecordingListView` 工具栏新增"导入音频"按钮，与"新建录音"并列。 |
| F-2 | 文件选择 | 使用 `NSOpenPanel` 选择文件，允许多选（上限 10 个），过滤 `.wav` / `.mp3`。 |
| F-3 | 文件复制到 App Storage | 将选中文件复制到 `~/Library/Application Support/AIRecording/Recordings/`（与现有录音统一目录），重命名规则：`imported_YYYYMMDD_HHmmss_{originalName}.{ext}`。 |
| F-4 | 元数据提取 | 使用 `AVAudioFile` / `AVAsset` 读取 duration、sampleRate、channels、bitDepth（如可用）、fileSize。 |
| F-5 | 创建 Recording 实体 | 在 Core Data 中创建 `Recording`，字段填充规则见第 4 节。 |
| F-6 | 自动触发转录 | 导入完成后，自动调用 `TranscriptionService.shared.transcribe(recording:)`，无需用户手动点击"开始转录"。 |
| F-7 | 列表状态展示 | `RecordingRowView` 显示导入来源图标（`square.and.arrow.down`）和转录状态（与现有录音一致）。 |
| F-8 | 错误处理与反馈 | 导入失败（文件损坏、格式不兼容、磁盘空间不足）在列表顶部或 Toast 提示；转录失败保留现有错误 UI。 |
| F-9 | 详情页复用 | 导入的录音进入 `RecordingDetailView` 后，转录、AI 纪要、智能图表功能与现有录音完全一致，无需额外适配。 |

## 3. 非功能范围 (Out of Scope)

| 编号 | 功能项 | 说明 |
|------|--------|------|
| O-1 | 引用模式（不复制文件） | 本期一律复制文件到 App Storage，避免原文件被删除或移动后失效。 |
| O-2 | 文件夹/拖拽导入 | 仅支持 `NSOpenPanel` 文件选择，不支持拖拽到 Dock/窗口或监控文件夹。 |
| O-3 | 格式转换 | 不将 .mp3 转换为 .wav；转录服务已原生支持 WAV/MP3/CAF，无需额外转换。 |
| O-4 | 批量并发转录 | 多个导入文件按顺序逐个转录，不并发（避免 SFSpeechRecognizer 资源冲突）。 |
| O-5 | 修改 AI 纪要/图表模块 | 仅保证导入后的录音能在现有详情页正常触发 AI 纪要和图表生成；不重构这两个模块。 |
| O-6 | 导入进度条 | 单文件导入瞬时完成，无需进度条；多文件导入在列表行内显示"导入中..."即可。 |
| O-7 | 元数据编辑（导入时） | 导入时不弹窗要求用户填写标题，使用默认标题（见第 4 节），用户可在详情页编辑 `customTitle`。 |

---

## 4. 关键流程

### 4.1 用户点击导入 → 文件选择 → 复制 → 创建 Recording → 自动转录

```
[用户点击"导入音频"按钮]
    ↓
[NSOpenPanel 弹出，过滤 .wav/.mp3，允许多选 ≤10]
    ↓
[用户确认选择]
    ↓
[AudioImportService.importFiles(urls:) 遍历处理]
    对每个文件：
        a. 校验：文件存在、扩展名合法、非空文件
        b. 生成目标路径：AppSupport/AIRecording/Recordings/imported_YYYYMMDD_HHmmss_{sanitizedName}.{ext}
        c. 复制文件（FileManager.copyItem）
        d. 使用 AVAudioFile/AVAsset 读取元数据（duration, sampleRate, channels, bitDepth）
        e. 创建 Recording Core Data 实体（字段填充见 4.2）
        f. 保存 Core Data context
        g. 自动触发 TranscriptionService.shared.transcribe(recording:)
    ↓
[RecordingListView 通过 NSManagedObjectContextObjectsDidChange 自动刷新]
    ↓
[列表行显示导入来源图标 + 转录状态]
```

### 4.2 Recording 字段填充规则

| 字段 | 填充值 | 说明 |
|------|--------|------|
| `id` | `UUID()` | 新唯一标识 |
| `filePath` | 复制后的目标路径 | 绝对路径字符串 |
| `fileFormat` | `"wav"` / `"mp3"` | 小写扩展名 |
| `duration` | `AVAsset.duration.seconds`（或 `AVAudioFile` 计算） | 秒，转 `Int32` |
| `sampleRate` | `AVAudioFormat.sampleRate` | 转 `Int32`；若无法读取，默认 `44100` |
| `channels` | `AVAudioFormat.channelCount` | 转 `Int32`；默认 `1` |
| `bitDepth` | `AVAudioFormat` 推导或 `0` | 对 MP3 可能为 `0`（无损信息不可用） |
| `fileSize` | `FileManager.attributesOfItem` 读取 | `Double`（字节数） |
| `sourceType` | **新增 `AudioSource.imported = 3`** | 见 4.3 |
| `status` | `RecordingStatus.completed` (`1`) | 导入即视为已完成录制 |
| `title` | `"导入录音 YYYY-MM-DD HH:mm"` | 默认标题，与现有录音格式区分 |
| `customTitle` | `nil` | 用户可后续编辑 |
| `createdAt` | 文件创建时间（优先）或当前时间 | 保留原始文件时间戳 |
| `updatedAt` | 当前时间 | |
| `isDeletedValue` | `false` | |
| `isFavorite` | `false` | |
| `isEncrypted` | `false` | |
| `storageLocation` | `"default"` | 与现有录音一致 |

### 4.3 AudioSource 枚举扩展

在 `AudioRecordingService.swift`（或 `Recording.swift`）中扩展 `AudioSource`：

```swift
enum AudioSource: Int, CaseIterable {
    case microphone = 0
    case systemAudio = 1
    case mixed = 2
    case imported = 3   // ← 新增
}

extension AudioSource {
    var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统音频"
        case .mixed: return "混合"
        case .imported: return "导入"   // ← 新增
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .mixed: return "mic.and.signal.meter.fill"
        case .imported: return "square.and.arrow.down"   // ← 新增
        }
    }
}
```

### 4.4 失败状态与重试

| 失败场景 | 行为 | 用户可见反馈 |
|----------|------|------------|
| 文件不存在或不可读 | 跳过该文件，记录错误 | 列表顶部显示 Toast：`"X 个文件无法读取，已跳过"` |
| 扩展名不合法（非 wav/mp3） | 过滤面板已阻止，理论上不会到达 | — |
| 磁盘空间不足 | 中断导入，已复制的部分保留 | Alert：`"磁盘空间不足，仅导入了 X 个文件"` |
| 复制失败（IO 错误） | 跳过该文件 | Toast 提示 |
| 元数据读取失败（损坏文件） | 仍创建 Recording，duration=0，其他字段默认值 | 列表行显示 `"时长未知"`，转录时由 `TranscriptionService` 处理 |
| 转录失败 | 保持现有行为：`TranscriptionStatus.failed`，`errorMessage` 记录 | 详情页显示错误 UI + 重试按钮 |

---

## 5. UI/UX 要点

### 5.1 按钮位置

在 `RecordingListView` 工具栏（`HStack` 中"新建录音"按钮旁边）新增：

```swift
Button(action: { showImportPanel = true }) {
    Label("导入音频", systemImage: "square.and.arrow.down")
}
.buttonStyle(.bordered)
```

布局：
```
[录音列表]                    [导入音频] [新建录音]
```

### 5.2 导入面板配置

```swift
let panel = NSOpenPanel()
panel.allowsMultipleSelection = true
panel.canChooseDirectories = false
panel.canChooseFiles = true
panel.allowedContentTypes = [.wav, .mp3]  // UTType
panel.message = "选择要导入的音频文件（支持 .wav 和 .mp3）"
panel.prompt = "导入"
```

### 5.3 列表行状态

`RecordingRowView` 已使用 `recording.sourceIconName`，扩展 `AudioSource.imported` 后自动显示 `square.and.arrow.down`。

转录状态复用现有逻辑：
- 转录中：`Label("转录中", systemImage: "ellipsis.circle")`（橙色）
- 已转录：`Label("已转录", systemImage: "checkmark.circle")`（绿色）
- 转录失败：不显示标签，详情页内处理

### 5.4 错误提示

- **Toast 风格**：使用 SwiftUI `overlay` + `animation` 实现临时提示，3 秒后自动消失。
- **Alert**：仅用于磁盘空间不足等需要用户确认的严重错误。

---

## 6. 数据与状态约束

### 6.1 Core Data 兼容性

- `Recording.sourceType` 为 `Int16`，新增 `imported = 3` 不会影响现有数据（现有值为 0/1/2）。
- `Recording.status` 导入时固定为 `1`（completed），转录状态由关联的 `Transcription` 实体管理。
- 不需要修改 `.xcdatamodeld` 结构，仅新增枚举值。

### 6.2 文件系统约束

- 复制目标目录与现有录音一致：`~/Library/Application Support/AIRecording/Recordings/`
- 文件名冲突处理：若目标文件名已存在，追加 `-1`、`-2` 等后缀。
- 文件权限：复制后保留用户读写权限，不加密。

### 6.3 转录服务约束

- `TranscriptionService` 已支持 WAV/MP3/CAF 输入，导入的 WAV/MP3 无需格式转换即可直接送入 `SFSpeechURLRecognitionRequest`。
- 导入的 MP3 若采样率/声道与 `SFSpeechRecognizer` 偏好不符，由 `TranscriptionService` 内部处理（现有逻辑已包含 CAF→WAV 重采样，可复用）。

---

## 7. 验收标准（可检查、可测试）

### 7.1 功能验收

| 编号 | 验收项 | 检查方法 |
|------|--------|----------|
| AC-1 | 点击"导入音频"弹出文件选择面板，仅可选 .wav/.mp3 | 手动测试 |
| AC-2 | 选择 1 个合法 .wav 文件后，列表新增一行，来源图标为 `square.and.arrow.down` | 手动测试 |
| AC-3 | 导入后自动开始转录，列表行显示"转录中..." | 手动测试 |
| AC-4 | 转录完成后，列表行显示"已转录"，进入详情页可看到分段文本 | 手动测试 |
| AC-5 | 详情页中"生成 AI 纪要"和"生成图表"按钮可用，功能与现有录音一致 | 手动测试 |
| AC-6 | 选择 3 个合法文件，全部导入成功且各自自动转录 | 手动测试 |
| AC-7 | 选择一个损坏的 .wav 文件，导入成功但 duration=0，转录失败并显示错误 UI | 手动测试 |
| AC-8 | 导入时磁盘空间不足，弹出 Alert 且已导入部分保留 | 模拟测试（可用大文件+小分区） |

### 7.2 单元测试建议（供 QA/开发补充）

| 编号 | 测试项 | 测试方法 |
|------|--------|----------|
| UT-1 | `AudioImportService.importFile(url:)` 成功创建 Recording | 使用临时目录注入测试 |
| UT-2 | 文件名冲突时正确追加后缀 | 文件系统模拟 |
| UT-3 | 元数据读取失败时填充默认值 | Mock AVAudioFile |
| UT-4 | `AudioSource.imported` rawValue = 3，displayName/iconName 正确 | 断言枚举属性 |
| UT-5 | 导入后自动触发转录的调用链验证 | Mock TranscriptionService |

### 7.3 回归验收

| 编号 | 验收项 |
|------|--------|
| RC-1 | 现有麦克风录音流程不受影响（开始/停止/转录/纪要/图表） |
| RC-2 | 现有系统音频录音流程不受影响 |
| RC-3 | 现有混合录音流程不受影响 |
| RC-4 | 现有搜索、删除、软删除功能对导入录音同样有效 |

---

## 8. 风险与待确认项

### 8.1 已知风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| MP3 元数据读取（sampleRate/bitDepth）可能不准确 | 低 | 使用 `AVAsset` 回退读取，字段填 `0` 不影响转录 |
| 大文件（>500MB）复制耗时 | 中 | 复制操作放入后台 `Task`，列表先显示"导入中..."占位行 |
| SFSpeechRecognizer 并发限制 | 中 | 多文件导入时按顺序逐个转录，不并发 |
| 原文件时间戳 vs 导入时间 | 低 | 优先使用文件创建时间，失败则回退当前时间 |

### 8.2 待确认项（需 CEO/开发决策）

| 编号 | 问题 | 建议方案 | 决策人 |
|------|------|----------|--------|
| T-1 | 是否支持 .m4a（语音备忘录默认格式）？ | 本期不支持，后续迭代通过转码支持 | CEO |
| T-2 | 导入文件是否保留原文件名作为 `customTitle` 提示？ | 保留原文件名（去除扩展名）作为 `customTitle` 初始值 | CEO |
| T-3 | 多文件导入时是否显示总进度？ | 本期不显示，仅列表行内状态；若文件大则后续优化 | CEO |
| T-4 | 导入按钮是否放入 Menu Bar 右键菜单？ | 本期仅放入主窗口列表页；Menu Bar 后续统一规划 | CEO |

---

## 9. 实施建议

### 9.1 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `AIRecording/Services/AudioImportService.swift` | 新增 | 导入核心逻辑：文件选择、复制、元数据读取、创建 Recording、自动转录 |
| `AIRecording/Models/AudioSource.swift` | 新增（或合并到现有枚举） | 扩展 `AudioSource` 增加 `imported` case |
| `AIRecording/Views/RecordingListView.swift` | 修改 | 工具栏新增"导入音频"按钮，绑定 `AudioImportService` |
| `AIRecording/ViewModels/RecordingListViewModel.swift` | 修改 | 可选：暴露 `importFiles()` 方法或直接使用 Service |

### 9.2 里程碑

| 阶段 | 内容 | 预估工期 |
|------|------|----------|
| M1 | `AudioImportService` + `AudioSource` 扩展 + 单元测试 | 1 天 |
| M2 | UI 集成（按钮、面板、列表状态、错误提示） | 0.5 天 |
| M3 | 端到端测试（wav/mp3/损坏文件/大文件/多文件） | 0.5 天 |
| M4 | 回归测试（现有录音流程） | 0.5 天 |

**总预估：2.5 开发日 + 0.5 缓冲日 = 3 天**

---

## 10. 附录：AudioImportService 接口草案（供开发参考）

```swift
import Foundation
import AVFoundation
import CoreData

/// Errors that can occur during audio import.
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

/// Result of a single file import attempt.
struct AudioImportResult {
    let sourceURL: URL
    let recording: Recording?
    let error: AudioImportError?
}

@MainActor
final class AudioImportService: ObservableObject {
    static let shared = AudioImportService()

    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double = 0

    private let persistence = PersistenceController.shared
    private let transcriptionService = TranscriptionService.shared

    private init() {}

    /// Import one or more audio files. Automatically triggers transcription for each success.
    func importFiles(urls: [URL]) async -> [AudioImportResult] {
        // Implementation: validate, copy, create Recording, transcribe
    }

    /// Generate a unique filename in the app storage directory.
    private func generateImportURL(originalURL: URL) -> URL {
        // Implementation
    }

    /// Read audio metadata using AVFoundation.
    private func readAudioMetadata(url: URL) -> (duration: Double, sampleRate: Double, channels: Int, bitDepth: Int)? {
        // Implementation
    }
}
```

---

*文档版本: v1.0*  
*创建日期: 2026-06-16*  
*作者: claude-cp-lead*  
*状态: 待 CEO 审阅，待开发实现*
