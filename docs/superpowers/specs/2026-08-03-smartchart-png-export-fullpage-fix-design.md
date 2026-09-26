# 智能图表：PNG 导出全图不完整修复 — 设计文档

- 日期：2026-08-03
- 状态：待实施
- 影响范围：仅 Swift 端 `AIRecording/Views/MindMapPNGExporter.swift` 及其测试；Python 后端与页面模板不动

## 1. 背景与问题

v5/v6 已上线"导出 PNG"（`RecordingDetailViewModel.exportMindMapPNG` → `MindMapPNGExporter.snapshotFullPage`）。当前缺陷：页面内容超出 WebView 可视区时，导出的 PNG 画布高度正确（整页高度），但只有原可视区对应的上半截有内容，下半截纯黑——用户拿不到完整图表。

### 根因

`snapshotFullPage` 的做法是：把 WebView 的 frame 拉高到整页内容高度，再用 `WKWebView.takeSnapshot` 一次性截全 rect。但 **WebKit 只栅格化窗口可见区域内的内容**——WebView 被拉高后，超出窗口的部分从未真正绘制（compositing tiles 不存在），快照里对应区域就是空白/黑色。拉高 frame 触发了布局，却无法触发窗口外区域的光栅化，这是 WKWebView 的固有行为，靠"等待更久"或"多次测量收敛"无法解决。

## 2. 目标与非目标

### 目标

- 导出 PNG 包含完整整页内容（标题 + 摘要 + 思维导图全图），无黑区、无接缝、无重复/缺失行。
- 导出不依赖用户当前滚动位置与缩放倍率；导出结束后页面滚动位置、缩放恢复原状。
- 保持现有导出语义与交互不变：`NSSavePanel` 写盘、文件名规则、`pngData` 转换。

### 非目标

- 不改导出内容范围（维持整页：标题 + 摘要 + 导图，不裁成只有导图本体）。
- 不改 Python 后端、不改 HTML/SVG 模板、不改 ChartWebView 的页面加载逻辑。
- 不做 2x/Retina 超采样导出（维持当前屏幕分辨率 1x）。
- 不处理 `other` 类型 highlights 兜底页面之外的新内容类型。

## 3. 方案

**分块滚动截图拼接**：不再拉高 WebView frame，保持其在窗口中的可见尺寸不变。导出时从页面顶部开始，每次滚动一个视口高度 → 等待渲染 → 只对视口 rect 截图，循环到底部，最后在 Swift 侧把所有图块垂直拼接成一张整页 NSImage。WebKit 只画可见区，那就让它始终只截可见区。

被否决的备选：

- **离屏全尺寸 WebView 重渲染**：HTML 需加载两遍；离屏/超出窗口的 WebView 同样不栅格化，可靠性无保证；内存随页面高度增长。
- **页面内 SVG→Canvas→PNG**：清晰度最高，但只能导 SVG 本体，丢失标题与摘要，与已确认的"整页导出"范围冲突。

## 4. 详细设计

### 4.1 `snapshotFullPage` 重写（`MindMapPNGExporter.swift`）

流程：

1. 记录当前 `magnification` 与滚动位置（现有 `scrollPosition(of:)` 复用）。
2. 设 `magnification = 1.0`，`window.scrollTo(0, 0)`，等待一帧。
3. 测量：
   - `pageHeight`：现有 `pageHeight(of:)` JS 不变（`max(body.scrollHeight, documentElement.scrollHeight)`）。
   - `viewportHeight`：`webView.bounds.height`（不动 frame，直接读）。
   - 守卫：`webView.bounds.width > 0 && viewportHeight > 0 && pageHeight > 0`，否则抛 `ChartSkillError.invalidResponse`。
4. 分块循环，`offset` 取自纯函数 `tileOffsets(pageHeight:viewportHeight:)`：从 0 开始、步长 `viewportHeight`；**末块对齐页面底部**（`pageHeight - viewportHeight`，与上一块允许重叠——重叠区像素相同，拼接无副作用，因此无需任何源图裁剪）。每块：
   1. `window.scrollTo(0, offset)`；
   2. `waitForPageLayout`（现有双 rAF + 100ms 超时复用）；
   3. `takeSnapshot`，`WKSnapshotConfiguration.rect = CGRect(origin: .zero, size: viewportSize)`——每块只截视口。
5. 拼接实现：先收齐全部图块（含 await 阶段不做任何绘制），再在**固定 sRGB `CGContext`** 中按 Quartz 左下原点坐标（`y = pageHeight - offset - viewportHeight`，乘以从首块 CGImage 推算的 backing scale）逐块绘制，输出 `NSImage(cgImage:size:)`。不用 `NSImage.lockFocus`：它会按显示器描述文件重编码像素，在广色域 Mac 上导出 PNG 色彩偏移；固定 sRGB 上下文保证导出色彩确定。
6. 恢复（现有 defer/restore 逻辑保留）：恢复 `magnification` 与滚动位置。**删除** frame 拉高与"测量-收敛"循环（frame 全程不动）。

### 4.2 拼接精度约定

- `pageHeight`、`viewportHeight`、每块 `offset` 全部用 `ceil`/整数化处理，保证块与块之间无 1px 重叠或缝隙。
- 滚动步长必须等于截图 rect 高度（`viewportHeight`），两者不可来自不同来源。

### 4.3 测试改造（`Tests/AIRecordingTests/`）

- `SnapshotAction` 语义从"整页一次"变为"每块一次"；注入的假快照按 configuration.rect 生成可区分颜色/图案的块。
- 新增/改造用例：
  - 页面高 = 2.5 × 视口高：验证 snapshot 调用 3 次，各块 rect 正确，拼接后总图高度 = `pageHeight`、各块纵向偏移正确、末块裁剪正确。
  - 页面高 ≤ 视口高：只截 1 次，退化为单块。
  - 恢复逻辑：导出后滚动位置与 magnification 复原（沿用现有断言思路）。
- `pngData`、`defaultFileName` 已有测试不动。

## 5. 验证（实机）

用根因录音（"智能监测中心产品演示"，页面明显超出一屏）实机导出 PNG，确认：

1. 底部图表完整渲染，无黑色区域；
2. 块与块之间无接缝、无重复行；
3. 导出后 App 内页面滚动位置与缩放倍率与导出前一致；
4. `swift build` 与 `swift test` 通过。
