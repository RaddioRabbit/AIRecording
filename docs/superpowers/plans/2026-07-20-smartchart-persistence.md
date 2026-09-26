# 智能图表结果持久化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 智能图表生成成功后写入 Core Data，重新打开录音详情页时直接恢复显示，不再重新调用后端生成。

**Architecture:** 复用 Core Data 中已预留的 `Chart` 实体（代码构建模型，位于 `PersistenceController.swift`），新增 6 个 optional 字段存 v4 响应；新增无状态辅助枚举 `ChartPersistence` 负责 保存(覆盖写)/恢复 转换；`RecordingDetailViewModel` 在生成成功和 `loadRecording()` 两个点位接线。UI 零改动。

**Tech Stack:** Swift 5.9+, SwiftUI, Core Data（程序化模型 + 轻量迁移）, XCTest, SPM。

**设计文档:** `docs/superpowers/specs/2026-07-20-smartchart-persistence-design.md`

---

### Task 1: Chart 实体新增持久化字段

**Files:**
- Modify: `AIRecording/Services/PersistenceController.swift`（Chart 实体属性数组，约 194-216 行）
- Modify: `AIRecording/Models/Chart.swift:30` 附近

- [ ] **Step 1: 在 `PersistenceController.swift` 的 `chartAttributes` 数组中追加 6 个属性**

在 `("retryCount", .integer32AttributeType, 0, false),` 一行之后追加：

```swift
            ("title",             .stringAttributeType,         nil,    true),
            ("contentType",       .stringAttributeType,         nil,    true),
            ("contentTypeDisplayName", .stringAttributeType,    nil,    true),
            ("chartTypeName",     .stringAttributeType,         nil,    true),
            ("chartTypeDisplayName", .stringAttributeType,      nil,    true),
            ("htmlFragment",      .stringAttributeType,         nil,    true),
```

注意：现有的 `("chartType", .integer16AttributeType, 0, false)` 是旧 Int16 字段，**保留不动**；新字段叫 `chartTypeName` 避免冲突。全部 optional → 轻量迁移自动处理（`PersistenceController.swift:15-16` 已开 `NSMigratePersistentStoresAutomaticallyOption` / `NSInferMappingModelAutomaticallyOption`）。

- [ ] **Step 2: 在 `Chart.swift` 添加对应 `@NSManaged` 属性**

在 `@NSManaged public var retryCount: Int32` 之后追加：

```swift
    @NSManaged public var title: String?
    @NSManaged public var contentType: String?
    @NSManaged public var contentTypeDisplayName: String?
    @NSManaged public var chartTypeName: String?
    @NSManaged public var chartTypeDisplayName: String?
    @NSManaged public var htmlFragment: String?
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: BUILD SUCCEEDED（现存代码不引用这些新字段，不应有任何报错）

- [ ] **Step 4: Commit**

```bash
git add AIRecording/Services/PersistenceController.swift AIRecording/Models/Chart.swift
git commit -m "feat: Chart 实体新增智能图表 v4 持久化字段"
```

---

### Task 2: ChartPersistence 保存/恢复辅助（TDD）

**Files:**
- Create: `AIRecording/Services/ChartPersistence.swift`
- Test: `Tests/AIRecordingTests/ChartPersistenceTests.swift`

- [ ] **Step 1: 编写失败测试**

创建 `Tests/AIRecordingTests/ChartPersistenceTests.swift`：

```swift
import CoreData
import XCTest
@testable import AIRecording

final class ChartPersistenceTests: XCTestCase {
    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext { persistence.container.viewContext }

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
    }

    override func tearDown() {
        persistence = nil
        super.tearDown()
    }

    private func makeRecording() -> Recording {
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.createdAt = Date()
        recording.updatedAt = Date()
        return recording
    }

    private func makeResponse(title: String = "周会纪要", html: String = "<div>chart</div>") -> SmartChartGenerateResponse {
        SmartChartGenerateResponse(
            version: "4.0",
            requestId: UUID().uuidString,
            status: "completed",
            contentType: .meeting,
            contentTypeDisplayName: "会议",
            chartType: "mindmap",
            chartTypeDisplayName: "思维导图",
            title: title,
            htmlFragment: html,
            errors: [],
            errorCode: nil
        )
    }

    func testSaveAndRestoreRoundtrip() {
        let recording = makeRecording()
        let response = makeResponse()

        ChartPersistence.save(response: response, for: recording, in: context)
        persistence.saveContext()

        let restored = ChartPersistence.latestResponse(for: recording)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.status, "completed")
        XCTAssertEqual(restored?.contentType, .meeting)
        XCTAssertEqual(restored?.contentTypeDisplayName, "会议")
        XCTAssertEqual(restored?.chartType, "mindmap")
        XCTAssertEqual(restored?.chartTypeDisplayName, "思维导图")
        XCTAssertEqual(restored?.title, "周会纪要")
        XCTAssertEqual(restored?.htmlFragment, "<div>chart</div>")
        XCTAssertEqual(restored?.errors, [])
    }

    func testSaveOverwritesPreviousChart() {
        let recording = makeRecording()
        ChartPersistence.save(response: makeResponse(title: "第一版"), for: recording, in: context)
        persistence.saveContext()

        ChartPersistence.save(response: makeResponse(title: "第二版"), for: recording, in: context)
        persistence.saveContext()

        XCTAssertEqual(recording.charts?.count, 1)
        XCTAssertEqual(ChartPersistence.latestResponse(for: recording)?.title, "第二版")
    }

    func testLatestResponseReturnsNilWhenNoChart() {
        let recording = makeRecording()
        persistence.saveContext()
        XCTAssertNil(ChartPersistence.latestResponse(for: recording))
    }

    func testLegacyChartWithoutHtmlFragmentIsIgnored() {
        let recording = makeRecording()
        // 模拟持久化功能上线前的旧 Chart 记录：没有 htmlFragment 字段值
        let legacy = Chart(context: context)
        legacy.id = UUID()
        legacy.recordingId = recording.id
        legacy.status = ChartStatus.completed.rawValue
        legacy.createdAt = Date()
        legacy.recording = recording
        persistence.saveContext()

        XCTAssertNil(ChartPersistence.latestResponse(for: recording))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ChartPersistenceTests`
Expected: 编译失败，`ChartPersistence` 未定义（find type 'ChartPersistence' in scope）

- [ ] **Step 3: 实现 `ChartPersistence`**

创建 `AIRecording/Services/ChartPersistence.swift`：

```swift
import CoreData

/// 智能图表结果的 Core Data 持久化：每段录音只保留最新一份图表。
/// 保存为覆盖写（先删旧记录），恢复时取 createdAt 最新且 htmlFragment 非空的一条。
enum ChartPersistence {

    /// 用生成成功的响应覆盖写入该录音的图表记录。调用方负责 saveContext()。
    static func save(response: SmartChartGenerateResponse, for recording: Recording, in context: NSManagedObjectContext) {
        if let existing = recording.charts as? Set<Chart> {
            for chart in existing {
                context.delete(chart)
            }
        }

        let chart = Chart(context: context)
        chart.id = UUID()
        chart.recordingId = recording.id
        chart.status = ChartStatus.completed.rawValue
        chart.title = response.title
        chart.contentType = response.contentType.rawValue
        chart.contentTypeDisplayName = response.contentTypeDisplayName
        chart.chartTypeName = response.chartType
        chart.chartTypeDisplayName = response.chartTypeDisplayName
        chart.htmlFragment = response.htmlFragment
        chart.createdAt = Date()
        chart.updatedAt = chart.createdAt
        chart.recording = recording
    }

    /// 恢复最近一次保存的图表；没有可用记录时返回 nil。
    static func latestResponse(for recording: Recording) -> SmartChartGenerateResponse? {
        guard let charts = recording.charts as? Set<Chart> else { return nil }
        let usable = charts.filter { chart in
            guard let fragment = chart.htmlFragment else { return false }
            return !fragment.isEmpty
        }
        guard let latest = usable.max(by: {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }) else { return nil }

        let contentType = ContentType(rawValue: latest.contentType ?? "") ?? .other
        return SmartChartGenerateResponse(
            version: "4.0",
            requestId: latest.id?.uuidString ?? "",
            status: "completed",
            contentType: contentType,
            contentTypeDisplayName: latest.contentTypeDisplayName ?? contentType.displayName,
            chartType: latest.chartTypeName ?? "",
            chartTypeDisplayName: latest.chartTypeDisplayName ?? "",
            title: latest.title ?? "",
            htmlFragment: latest.htmlFragment ?? "",
            errors: [],
            errorCode: nil
        )
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ChartPersistenceTests`
Expected: 4 个测试全部 PASS

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Services/ChartPersistence.swift Tests/AIRecordingTests/ChartPersistenceTests.swift
git commit -m "feat: ChartPersistence 图表结果保存与恢复（覆盖写）"
```

---

### Task 3: ViewModel 接线（生成后保存 + 打开页面恢复）

**Files:**
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift:170-186`（loadRecording）
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift:345-351`（generateChart 成功分支）

- [ ] **Step 1: `loadRecording()` 中恢复图表**

在 `RecordingDetailViewModel.loadRecording()` 里，`self.summary = rec.transcription?.summary` 一行之后追加：

```swift
                if chartResult == nil, let restored = ChartPersistence.latestResponse(for: rec) {
                    chartResult = restored
                }
```

说明：只在 `chartResult == nil` 时恢复，避免 `bindContextChanges()` 触发的自动 `loadRecording()` 用旧记录覆盖正在显示的新结果；重新生成期间（`isGeneratingChart == true`）`chartResult` 仍持有旧图表，恢复分支也不会触发。

- [ ] **Step 2: `generateChart` 成功分支保存**

在 `generateChart(forcedType:)` 的 `chartTask = Task { do { ... } }` 成功分支里，`chartResult = response` 之后追加：

```swift
                if let rec = recording {
                    ChartPersistence.save(response: response, for: rec, in: persistence.container.viewContext)
                    persistence.saveContext()
                }
```

保存失败由 `saveContext()` 内部记日志（现有静默风格），不影响 `chartResult` 已设置的内存展示。

- [ ] **Step 3: 编译 + 全量测试**

Run: `swift build && swift test`
Expected: BUILD SUCCEEDED，全部测试 PASS（含 Task 2 的 4 个新测试）

- [ ] **Step 4: Commit**

```bash
git add AIRecording/ViewModels/RecordingDetailViewModel.swift
git commit -m "feat: 详情页生成图表后持久化，打开页面自动恢复显示"
```

---

### Task 4: 手动验收（需要真实环境，无法自动化）

**Files:** 无（仅运行验证）

- [ ] **Step 1: 轻量迁移验证 — 旧数据不丢**

用本次改动前的 app 版本已有的本地数据直接运行新版本（`swift run` 或 `Scripts/build-app.sh` 打包后运行）。
Expected: app 正常启动，录音列表和详情页正常打开，无 Core Data 迁移报错崩溃。

- [ ] **Step 2: 核心场景 — 离开页面后图表仍在**

1. 打开一段已完成转录的录音详情页，点击"生成图表"，等待生成成功
2. 返回录音列表（或切换到另一段录音），再重新进入该录音详情页
Expected: "智能图表"区域直接显示已生成的图表（标题栏显示"内容类型 · 图表类型"），不再出现"暂无图表 / 生成图表"空态，也没有重新调用后端（观察日志无新的 `/chart/generate` 请求）。

- [ ] **Step 3: 覆盖语义 — 重新生成只留最新一份**

在已显示图表的详情页点"重新生成"，成功后离开再进入。
Expected: 显示的是第二次生成的图表；数据库中该录音的 Chart 记录仍为 1 条（可用 `Charts` 等 SQLite 工具或日志验证，非必须）。

- [ ] **Step 4: 记录验收结果**

若全部通过，在本计划文件末尾追加一行验收记录（日期 + 结果），然后：

```bash
git add docs/superpowers/plans/2026-07-20-smartchart-persistence.md
git commit -m "docs: 智能图表持久化手动验收通过"
```

---

## 明确不做

- 不保存多份历史版本（覆盖写）
- 不做图表与转录内容的一致性/失效检测（重新转录后旧图表照常显示）
- 不使用 `ChartNode` / `ChartEdge` / `ChartJob` 实体
- 不改任何 UI 代码
