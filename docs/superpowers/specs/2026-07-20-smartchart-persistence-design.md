# 智能图表结果持久化设计

日期：2026-07-20
状态：已确认（方案 A）

## 背景与目标

当前智能图表（v4，按内容类型路由）生成成功后，结果只保存在 `RecordingDetailViewModel.chartResult` 内存属性中。`RecordingDetailView` 每次打开都会新建 ViewModel，`loadRecording()` 不恢复图表状态，因此用户离开再进入录音详情页后必须重新生成（一次 LLM 调用，几十秒 + API 费用）。

> 注：`docs/superpowers/specs/2026-07-17-smartchart-content-type-skills-design.md` 曾明确"不做图表持久化（维持按需生成）"，本设计推翻该决策。

**目标**：图表生成成功后持久化；再次打开同一录音的详情页时直接展示已保存的图表，不重新调用后端。

**已确认的决策**：
- 每段录音只保留最新一份图表，重新生成覆盖旧记录。
- 重新转录后已保存的图表仍然显示（不做失效检测），用户可手动点"重新生成"。

## 方案

复用 Core Data 中已预留但从未使用的 `Chart` 实体（`PersistenceController.swift` 以代码方式构建），补充存 v4 响应所需的字段。`Recording.charts` 一对多关系（级联删除）已存在，直接使用。

## 1. 数据模型变更

`AIRecording/Services/PersistenceController.swift` 的 `Chart` 实体新增 6 个属性，全部为 optional string：

| 属性 | 内容 |
|---|---|
| `htmlFragment` | 图表 HTML 片段（核心内容） |
| `contentType` | 内容类型原始值（如 `meeting`） |
| `contentTypeDisplayName` | 内容类型显示名（如 `会议`） |
| `chartTypeName` | 图表类型原始名（现有 `chartType` 是 Int16 旧字段，保留不动，避免冲突） |
| `chartTypeDisplayName` | 图表类型显示名 |
| `title` | 图表标题 |

`AIRecording/Models/Chart.swift` 同步添加对应 `@NSManaged` 属性。

- 全部为 optional → Core Data 轻量迁移自动完成，已有用户数据不受影响。
- `ChartNode` / `ChartEdge` / `ChartJob` 三个旧实体本次不使用、不修改。

## 2. 保存逻辑

位置：`RecordingDetailViewModel.generateChart(forcedType:)` 成功分支（`chartResult = response` 之后）。

1. 在该录音的 `charts` 中删除全部旧 `Chart` 记录（保证只留最新一份）。
2. 新建一条 `Chart`，写入：
   - `id = UUID()`、`recordingId`、`createdAt = updatedAt = Date()`
   - `status = ChartStatus.completed.rawValue`
   - 响应中的 `htmlFragment` / `contentType` / `contentTypeDisplayName` / `chartType` → `chartTypeName` / `chartTypeDisplayName` / `title`
   - 关联到当前 `Recording`
3. `persistence.saveContext()`。

保存失败只通过 `AppLogger` 记日志，不影响内存中图表的正常显示。

## 3. 恢复逻辑

位置：`RecordingDetailViewModel.loadRecording()`。

加载录音后，从其 `charts` 中取 `createdAt` 最新且 `htmlFragment` 非空的一条，重建 `SmartChartGenerateResponse`（status=completed，各字段从 Chart 实体读回）赋给 `chartResult`。

- 页面打开即呈现"结果态"UI（与刚生成完一致），"重新生成"按钮照常可用，点击后走第 2 节覆盖旧记录。
- 读取失败记日志，`chartResult` 保持 nil，面板退回"暂无图表"空态，行为与现状一致。

## 4. UI 变更

无。`chartResult` 被恢复后，现有 `chartPanelView`（`RecordingDetailView.swift:426-510`）的结果态分支自然生效。

## 5. 边界情况

- **录音删除**：当前为软删除（`isDeletedValue`），图表记录随录音一起隐藏/恢复；若未来硬删除，`Recording.charts` 已配置级联删除。
- **重新转录**：按已确认决策，不触动已保存图表。
- **生成中离开页面**：现有 `cleanup()` 取消任务、令牌失效，不写库，行为不变。
- **后端返回失败/错误码**：只有成功响应才落库，失败仅写 `chartError`（现状不变）。

## 6. 错误处理与日志

- 所有 Core Data 读写失败：仅 `AppLogger.log(.error, category: "persistence", ...)`，不向图表 UI 传播错误（与 `saveContext()` 现有静默风格一致）。
- 不记录 `htmlFragment` 内容，只记录 errorType 等标量（遵守日志隐私规范）。

## 7. 测试

在 `Tests/AIRecordingTests` 新增用例（使用内存 store 的 PersistenceController）：

1. 生成成功后能从 Core Data 读回完整字段（roundtrip）。
2. 第二次生成后该录音只剩一条 `Chart` 记录（覆盖语义）。
3. 无图表记录的录音执行恢复逻辑后 `chartResult` 为 nil。
4. 老版本 store（无新字段）打开正常（轻量迁移不报错——可选，若测试基建支持）。

## 不做的事（YAGNI）

- 不保存多份历史版本。
- 不做图表与转录内容的一致性/失效检测。
- 不使用 `ChartNode` / `ChartEdge` / `ChartJob`。
- 不做图表导出（`exportedImagePath` 等字段保持不用）。
