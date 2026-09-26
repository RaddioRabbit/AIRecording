# 智能图表 PNG 导出全图修复（分块滚动截图拼接）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复"导出 PNG"只含可视区内容的缺陷：改为分块滚动截图再垂直拼接，导出完整整页（标题+摘要+导图）。

**Architecture:** 不再拉高 WebView frame（WebKit 不栅格化窗口外区域，这是根因）。保持 WebView 可见尺寸不变，从页面顶部按视口高度逐块滚动、等待渲染、对视口截图，Swift 侧把图块拼成整页 NSImage。末尾块对齐页面底部（与上一块重叠若干像素，内容相同无副作用），避免任何源图裁剪逻辑。

**Tech Stack:** Swift / AppKit / WebKit / XCTest，SPM（`swift build` / `swift test`）。

**设计依据:** `docs/superpowers/specs/2026-08-03-smartchart-png-export-fullpage-fix-design.md`

**涉及文件:**
- Modify: `AIRecording/Views/MindMapPNGExporter.swift` — 重写 `snapshotFullPage`，新增 `tileOffsets` 纯函数，简化 `restoreState`（不再动 frame）
- Modify: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift` — 删除过时的"高度不收敛"测试，新增分块/拼接/零尺寸守卫测试

---

### Task 1: `tileOffsets` 分块偏移纯函数

**Files:**
- Modify: `AIRecording/Views/MindMapPNGExporter.swift`
- Test: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/AIRecordingTests/MindMapPNGExporterTests.swift` 的 `MindMapPNGExporterTests` 类内追加：

```swift
func testTileOffsets() {
    // 页面高 1480、视口高 240：步进 240，末块对齐页底（1240，与上一块重叠 200）
    XCTAssertEqual(
        MindMapPNGExporter.tileOffsets(pageHeight: 1480, viewportHeight: 240),
        [0, 240, 480, 720, 960, 1200, 1240]
    )
    // 页面恰好 2 屏
    XCTAssertEqual(
        MindMapPNGExporter.tileOffsets(pageHeight: 480, viewportHeight: 240),
        [0, 240]
    )
    // 页面恰等于视口
    XCTAssertEqual(
        MindMapPNGExporter.tileOffsets(pageHeight: 240, viewportHeight: 240),
        [0]
    )
    // 页面不足一屏：退化为单块
    XCTAssertEqual(
        MindMapPNGExporter.tileOffsets(pageHeight: 100, viewportHeight: 240),
        [0]
    )
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter MindMapPNGExporterTests.testTileOffsets`
Expected: 编译失败，`tileOffsets` 未定义。

- [ ] **Step 3: 实现 `tileOffsets`**

在 `AIRecording/Views/MindMapPNGExporter.swift` 的 `MindMapPNGExporter` enum 内（`snapshotFullPage` 之前）添加：

```swift
/// 分块纵向偏移序列：步长 = 视口高；末块对齐页面底部（与上一块允许重叠，
/// 重叠区像素相同，拼接无副作用）。页面不足一屏时退化为单块 [0]。
static func tileOffsets(pageHeight: CGFloat, viewportHeight: CGFloat) -> [CGFloat] {
    var offsets: [CGFloat] = []
    var offset: CGFloat = 0
    while true {
        if offset + viewportHeight >= pageHeight {
            offsets.append(max(0, pageHeight - viewportHeight))
            break
        }
        offsets.append(offset)
        offset += viewportHeight
    }
    return offsets
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter MindMapPNGExporterTests.testTileOffsets`
Expected: PASS（4 组断言全过）。

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Views/MindMapPNGExporter.swift Tests/AIRecordingTests/MindMapPNGExporterTests.swift
git commit -m "feat: PNG 导出分块偏移计算 tileOffsets"
```

---

### Task 2: 重写 `snapshotFullPage` 为分块滚动截图拼接

**Files:**
- Modify: `AIRecording/Views/MindMapPNGExporter.swift`（重写 `snapshotFullPage`，简化 `restoreState`，更新文件头注释）
- Test: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`

- [ ] **Step 1: 改造测试——删除过时用例，新增分块/拼接/守卫用例**

1. **删除** `testSnapshotRejectsUnstablePageHeightAndRestoresState`（该用例针对已删除的"拉高 frame + 测量收敛"逻辑，新方案无此行为）。

2. **保留** `testSnapshotFullPageRendersBelowViewportAndRestoresState`（核心回归：真实快照须包含视口下方的红色标记）、`testSnapshotFailureRestoresWebViewState`、`testPNGData*`、`testDefaultFileName*`，均不改动。

3. **新增**两个用例（追加到类内）：

```swift
@MainActor
func testSnapshotRejectsZeroSizeWebView() async throws {
    let webView = WKWebView(frame: .zero)
    do {
        _ = try await MindMapPNGExporter.snapshotFullPage(of: webView)
        XCTFail("Expected zero-size webView to be rejected")
    } catch ChartSkillError.invalidResponse {
        // 预期：零尺寸直接拒绝，不触碰 JS。
    }
}

@MainActor
func testSnapshotStitchesOneTilePerViewportBand() async throws {
    let webView = try await loadedWebView() // 页面内容 1400+80=1480px，视口 320x240

    let colors: [NSColor] = [.red, .green, .blue, .yellow, .magenta, .cyan, .orange, .white]
    var callCount = 0
    let image = try await MindMapPNGExporter.snapshotFullPage(of: webView) { _, configuration in
        XCTAssertEqual(configuration.rect, CGRect(x: 0, y: 0, width: 320, height: 240))
        XCTAssertEqual(webView.magnification, 1.0)
        let tile = NSImage(size: configuration.rect.size)
        tile.lockFocus()
        colors[callCount % colors.count].setFill()
        NSRect(origin: .zero, size: configuration.rect.size).fill()
        tile.unlockFocus()
        callCount += 1
        return tile
    }

    // 分块次数与整图高度（pageHeight 用与实现相同的 JS 实测，避免硬编码脆性）
    let measured = try await webView.evaluateJavaScript(
        "Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight))"
    ) as? NSNumber
    let pageHeight = try XCTUnwrap(measured?.doubleValue)
    let expectedOffsets = MindMapPNGExporter.tileOffsets(
        pageHeight: CGFloat(pageHeight), viewportHeight: 240
    )
    XCTAssertEqual(callCount, expectedOffsets.count)
    XCTAssertEqual(image.size.width, 320, accuracy: 1)
    XCTAssertEqual(image.size.height, CGFloat(pageHeight), accuracy: 1)

    // 经生产 pngData 解码（PNG 自顶向下），验证每个分块落在正确纵向位置：
    // 非末块采样带内 offset+10（下一块尚未覆盖），末块采样页底上方 10px。
    let data = try XCTUnwrap(MindMapPNGExporter.pngData(from: image))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
    let scale = Double(bitmap.pixelsHigh) / Double(image.size.height)
    for (index, offset) in expectedOffsets.enumerated() {
        let isLast = index == expectedOffsets.count - 1
        let sampleTop = isLast ? CGFloat(pageHeight) - 10 : offset + 10
        let sampled = try XCTUnwrap(
            bitmap.colorAt(x: Int(160 * scale), y: Int(sampleTop * scale))?
                .usingColorSpace(.deviceRGB),
            "tile \(index) 采样失败"
        )
        let expected = try XCTUnwrap(colors[index % colors.count].usingColorSpace(.deviceRGB))
        XCTAssertEqual(sampled.redComponent, expected.redComponent, accuracy: 0.05, "tile \(index) R")
        XCTAssertEqual(sampled.greenComponent, expected.greenComponent, accuracy: 0.05, "tile \(index) G")
        XCTAssertEqual(sampled.blueComponent, expected.blueComponent, accuracy: 0.05, "tile \(index) B")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter MindMapPNGExporterTests`
Expected: 编译通过但 `testSnapshotStitchesOneTilePerViewportBand` FAIL（旧实现整页一次截图，callCount == 1 ≠ expectedOffsets.count）。

- [ ] **Step 3: 重写 `snapshotFullPage`**

在 `AIRecording/Views/MindMapPNGExporter.swift` 中：

1. 文件头注释改为：

```swift
/// 思维导图 PNG 导出：分块滚动截图拼接——保持 WebView 可见尺寸不变，
/// 逐视口滚动、截图，再垂直拼接成整页全图。
/// （WebKit 只栅格化窗口可见区域，拉高 frame 截全图会得到下半截空白。）
```

2. **整体替换** `snapshotFullPage` 与 `restoreState` 两个方法（删除旧的 frame 拉高与测量收敛循环；`pageHeight`、`scrollPosition`、`waitForPageLayout`、`pngData`、`defaultFileName` 保持不变）：

```swift
/// 分块滚动截图拼接：保持 frame 不动，逐视口滚动截图后拼成整页 NSImage。
/// evaluateJavaScript 与 WKUserScript 同属应用侧注入，不受页面 CSP script-src 'none' 限制。
@MainActor
static func snapshotFullPage(
    of webView: WKWebView,
    snapshotAction: SnapshotAction? = nil
) async throws -> NSImage {
    // 取整（向下），保证分块步长/截图 rect/拼接偏移同源且无亚像素接缝
    let rawSize = webView.bounds.size
    let viewportSize = NSSize(width: floor(rawSize.width), height: floor(rawSize.height))
    guard viewportSize.width > 0, viewportSize.height > 0 else {
        throw ChartSkillError.invalidResponse
    }

    let originalMagnification = webView.magnification
    let originalScroll = try await scrollPosition(of: webView)
    defer {
        webView.magnification = originalMagnification
        webView.evaluateJavaScript(
            "window.scrollTo(\(originalScroll.x), \(originalScroll.y))",
            completionHandler: { _, _ in }
        )
    }

    do {
        webView.magnification = 1.0
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 0)")
        try await waitForPageLayout(in: webView)

        let pageHeight = try await pageHeight(of: webView)
        let offsets = tileOffsets(pageHeight: pageHeight, viewportHeight: viewportSize.height)

        // 先逐块捕获（含 await），再同步拼接——避免 lockFocus 期间挂起。
        var tiles: [(offset: CGFloat, image: NSImage)] = []
        for offset in offsets {
            _ = try await webView.evaluateJavaScript("window.scrollTo(0, \(offset))")
            try await waitForPageLayout(in: webView)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: viewportSize)
            let tile: NSImage
            if let snapshotAction {
                tile = try await snapshotAction(webView, configuration)
            } else {
                tile = try await webView.takeSnapshot(configuration: configuration)
            }
            tiles.append((offset, tile))
        }

        // NSImage lockFocus 坐标原点在左下角：页顶 offset 越大，目标 y 越小。
        let image = NSImage(size: NSSize(width: viewportSize.width, height: pageHeight))
        image.lockFocus()
        for (offset, tile) in tiles {
            tile.draw(
                in: NSRect(
                    x: 0,
                    y: pageHeight - offset - viewportSize.height,
                    width: viewportSize.width,
                    height: viewportSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        image.unlockFocus()

        try await restoreState(
            of: webView,
            magnification: originalMagnification,
            scroll: originalScroll
        )
        return image
    } catch {
        try? await restoreState(
            of: webView,
            magnification: originalMagnification,
            scroll: originalScroll
        )
        throw error
    }
}

@MainActor
private static func restoreState(
    of webView: WKWebView,
    magnification: CGFloat,
    scroll: CGPoint
) async throws {
    webView.magnification = magnification
    _ = try await webView.evaluateJavaScript("window.scrollTo(\(scroll.x), \(scroll.y))")
    webView.magnification = magnification
}
```

注意：`restoreState` 签名从旧版的 `(of:frame:magnification:scroll:)` 变为 `(of:magnification:scroll:)`——frame 全程不再变动，无需恢复。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter MindMapPNGExporterTests`
Expected: 全部 PASS，包括：
- `testTileOffsets`
- `testSnapshotRejectsZeroSizeWebView`
- `testSnapshotStitchesOneTilePerViewportBand`（7 块、每块颜色落在正确纵向带）
- `testSnapshotFullPageRendersBelowViewportAndRestoresState`（真实快照含页底红色标记）
- `testSnapshotFailureRestoresWebViewState`（注入失败后缩放/滚动复原）
- `testPNGData*`、`testDefaultFileName*`

- [ ] **Step 5: 全量回归**

Run: `swift build && swift test`
Expected: 构建成功，整个测试套件全绿（确认无其他调用方依赖 `restoreState` 旧签名或已删行为）。

- [ ] **Step 6: Commit**

```bash
git add AIRecording/Views/MindMapPNGExporter.swift Tests/AIRecordingTests/MindMapPNGExporterTests.swift
git commit -m "fix: PNG 导出改为分块滚动截图拼接，修复全图下半截空白"
```

---

### Task 3: 实机验证

**Files:** 无（手工验证）

- [ ] **Step 1: 构建并运行 App**

Run: `swift build`，然后用 `xed .` 在 Xcode 里 Run（或项目既有脚本 `Scripts/build-app.sh`），打开根因录音"智能监测中心产品演示"的智能图表页。

- [ ] **Step 2: 验证导出完整性**

点击"导出 PNG"，检查导出的图片：
1. 底部图表完整渲染，无黑色区域；
2. 分块之间无接缝、无重复行（重点看每屏交界处）；
3. 图片高度覆盖整页（标题+摘要+完整导图）。

- [ ] **Step 3: 验证现场恢复**

导出完成后确认 App 内图表页的滚动位置与缩放倍率与导出前一致；再滚动/缩放后重新导出一次，结果仍完整。

- [ ] **Step 4: 更新规格状态并收尾**

把 `docs/superpowers/specs/2026-08-03-smartchart-png-export-fullpage-fix-design.md` 头部的"状态：待实施"改为"状态：已实施"，然后：

```bash
git add docs/superpowers/specs/2026-08-03-smartchart-png-export-fullpage-fix-design.md
git commit -m "docs: PNG 导出修复已实施"
```
