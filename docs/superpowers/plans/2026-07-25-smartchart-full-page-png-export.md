# SmartChart Full-Page PNG Export Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the complete SmartChart page—header, summary, and every mind-map node—into a PNG without clipping content outside the visible `WKWebView` frame or disturbing the user's preview state.

**Architecture:** Keep the existing live-WebView snapshot path, but make `MindMapPNGExporter` own the temporary export state. It will capture the frame, magnification, and scroll position; render at 100% and the current preview width; expand only the height; wait for two browser animation frames; remeasure once for layout stability; snapshot; and restore all captured state through `defer`. A real `WKWebView` regression test will place a red marker below the viewport and verify that the marker appears in the PNG.

**Tech Stack:** Swift 5.9, AppKit, WebKit (`WKWebView`, `WKSnapshotConfiguration`), XCTest, Swift Package Manager

---

## File Structure

- Modify `AIRecording/Views/MindMapPNGExporter.swift`
  - Own complete-page measurement, temporary WebView resizing, layout stabilization, snapshot injection for the failure test, and unconditional state restoration.
- Modify `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`
  - Retain existing PNG encoding and filename tests.
  - Add real-WebView coverage for content below the viewport and restoration on success and failure.
- Modify `docs/superpowers/specs/2026-07-25-smartchart-full-page-png-export-design.md`
  - Mark the approved design as implemented only after build, automated tests, and manual verification pass.

Do not modify `ChartAgent/agent/mindmap.py` or `AIRecording/Views/ChartWebView.swift`. Do not stage the unrelated existing changes in `AIRecording/Services/ChartPersistence.swift` or `AIRecording/ViewModels/RecordingDetailViewModel.swift`.

### Task 1: Add the full-page WebView regression tests

**Files:**
- Modify: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`
- Test: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`

- [ ] **Step 1: Add a deterministic long-page fixture and WebView helpers**

Add these helpers inside `MindMapPNGExporterTests`:

```swift
private enum ForcedSnapshotError: Error {
    case failed
}

@MainActor
private func makeLoadedLongPageWebView() async throws -> WKWebView {
    let webView = WKWebView(
        frame: NSRect(x: 11, y: 13, width: 320, height: 240)
    )
    webView.loadHTMLString(
        """
        <!doctype html>
        <html>
        <head>
          <style>
            * { box-sizing: border-box; }
            html, body {
              margin: 0;
              width: 100%;
              background: rgb(15, 15, 26);
            }
            #above-the-fold { height: 1400px; }
            #below-viewport-marker {
              width: 100%;
              height: 80px;
              background: rgb(255, 0, 0);
            }
          </style>
        </head>
        <body>
          <div id="above-the-fold"></div>
          <div id="below-viewport-marker"></div>
        </body>
        </html>
        """,
        baseURL: nil
    )

    for _ in 0..<100 {
        let state = try await webView.evaluateJavaScript("document.readyState") as? String
        if state == "complete" {
            return webView
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    throw ChartSkillError.invalidResponse
}

private func containsRedMarker(_ image: NSImage) throws -> Bool {
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            guard let color = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB) else {
                continue
            }
            if color.redComponent > 0.8,
               color.greenComponent < 0.2,
               color.blueComponent < 0.2 {
                return true
            }
        }
    }
    return false
}
```

Add `import WebKit` beside the existing imports.

- [ ] **Step 2: Add the successful full-page export test**

Add this test inside `MindMapPNGExporterTests`:

```swift
@MainActor
func testSnapshotFullPageRendersBelowViewportAndRestoresState() async throws {
    let webView = try await makeLoadedLongPageWebView()
    webView.setMagnification(1.5, centeredAt: NSPoint(x: 160, y: 120))
    webView.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
    webView.scrollView.reflectScrolledClipView(webView.scrollView.contentView)

    let originalFrame = webView.frame
    let originalMagnification = webView.magnification
    let originalScrollOrigin = webView.scrollView.contentView.bounds.origin

    let image = try await MindMapPNGExporter.snapshotFullPage(of: webView)

    XCTAssertEqual(image.size.width, originalFrame.width, accuracy: 2)
    XCTAssertGreaterThan(image.size.height, 1_450)
    XCTAssertTrue(
        try containsRedMarker(image),
        "PNG must contain content located below the original 240pt viewport"
    )
    XCTAssertEqual(webView.frame, originalFrame)
    XCTAssertEqual(webView.magnification, originalMagnification, accuracy: 0.001)
    XCTAssertEqual(
        webView.scrollView.contentView.bounds.origin.y,
        originalScrollOrigin.y,
        accuracy: 1
    )
}
```

The red marker assertion is essential. An image-height-only assertion would allow the current bug—an empty long canvas with clipped content—to pass.

- [ ] **Step 3: Add the failure-restoration test**

Add this test:

```swift
@MainActor
func testSnapshotFailureRestoresWebViewState() async throws {
    let webView = try await makeLoadedLongPageWebView()
    webView.setMagnification(1.5, centeredAt: NSPoint(x: 160, y: 120))
    webView.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
    webView.scrollView.reflectScrolledClipView(webView.scrollView.contentView)

    let originalFrame = webView.frame
    let originalMagnification = webView.magnification
    let originalScrollOrigin = webView.scrollView.contentView.bounds.origin

    do {
        _ = try await MindMapPNGExporter.snapshotFullPage(of: webView) { _, _ in
            throw ForcedSnapshotError.failed
        }
        XCTFail("Forced snapshot failure must be thrown")
    } catch ForcedSnapshotError.failed {
        // Expected.
    }

    XCTAssertEqual(webView.frame, originalFrame)
    XCTAssertEqual(webView.magnification, originalMagnification, accuracy: 0.001)
    XCTAssertEqual(
        webView.scrollView.contentView.bounds.origin.y,
        originalScrollOrigin.y,
        accuracy: 1
    )
}
```

- [ ] **Step 4: Run the tests and verify the new API requirement fails**

Run:

```bash
swift test --filter MindMapPNGExporterTests
```

Expected: compilation fails at the failure test because the current
`snapshotFullPage(of:)` method does not accept a snapshot action closure.
The diagnostic should include `extra trailing closure passed in call` or its Swift-version equivalent.

Do not weaken or remove the failure test to make this step pass.

### Task 2: Stabilize full-page layout and restore WebView state

**Files:**
- Modify: `AIRecording/Views/MindMapPNGExporter.swift`
- Test: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`

- [ ] **Step 1: Replace the current snapshot implementation**

Inside `MindMapPNGExporter`, replace only `snapshotFullPage(of:)` and add the three focused private helpers shown below. Keep `pngData(from:)` and `defaultFileName(recordingTitle:)` unchanged.

```swift
typealias SnapshotAction = @MainActor (
    WKWebView,
    WKSnapshotConfiguration
) async throws -> NSImage

/// 以当前预览宽度导出完整页面；临时状态在所有退出路径中恢复。
@MainActor
static func snapshotFullPage(
    of webView: WKWebView,
    snapshotAction: SnapshotAction? = nil
) async throws -> NSImage {
    let originalFrame = webView.frame
    let originalMagnification = webView.magnification
    let originalScrollOrigin = webView.scrollView.contentView.bounds.origin

    guard originalFrame.width > 0, originalFrame.height > 0 else {
        throw ChartSkillError.invalidResponse
    }

    defer {
        webView.frame = originalFrame
        webView.magnification = originalMagnification
        webView.layoutSubtreeIfNeeded()
        webView.scrollView.contentView.scroll(to: originalScrollOrigin)
        webView.scrollView.reflectScrolledClipView(webView.scrollView.contentView)
    }

    webView.magnification = 1.0
    var contentHeight = try await pageContentHeight(of: webView)

    // 首次扩高可能改变 CSS 的 vh/min-height 计算；最多复测一次即可稳定。
    for _ in 0..<2 {
        webView.setFrameSize(
            CGSize(width: originalFrame.width, height: contentHeight)
        )
        webView.layoutSubtreeIfNeeded()
        try await waitForPageLayout(in: webView)

        let measuredHeight = try await pageContentHeight(of: webView)
        if abs(measuredHeight - contentHeight) < 1 {
            contentHeight = measuredHeight
            break
        }
        contentHeight = measuredHeight
    }

    guard contentHeight > 0 else {
        throw ChartSkillError.invalidResponse
    }

    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(
        x: 0,
        y: 0,
        width: originalFrame.width,
        height: contentHeight
    )

    if let snapshotAction {
        return try await snapshotAction(webView, configuration)
    }
    return try await webView.takeSnapshot(configuration: configuration)
}

@MainActor
private static func pageContentHeight(of webView: WKWebView) async throws -> CGFloat {
    let result = try await webView.evaluateJavaScript(
        """
        Math.ceil(Math.max(
          document.body.scrollHeight,
          document.documentElement.scrollHeight
        ))
        """
    )
    guard let number = result as? NSNumber,
          number.doubleValue > 0 else {
        throw ChartSkillError.invalidResponse
    }
    return CGFloat(number.doubleValue)
}

@MainActor
private static func waitForPageLayout(in webView: WKWebView) async throws {
    _ = try await webView.callAsyncJavaScript(
        """
        await new Promise(resolve => {
          requestAnimationFrame(() => requestAnimationFrame(resolve));
        });
        return true;
        """,
        arguments: [:],
        in: nil,
        contentWorld: .page
    )
}
```

Why each detail exists:

- `originalFrame.width` implements the approved “keep current width, extend height” behavior.
- Two `requestAnimationFrame` callbacks allow WebKit to lay out and paint after the resize.
- The second measurement handles `vh` and `min-height: 100vh` without an open-ended stabilization loop.
- `defer` restores state after success, JavaScript failure, injected snapshot failure, or WebKit snapshot failure.
- The optional `snapshotAction` is internal test injection only; production callers remain unchanged.

- [ ] **Step 2: Run the focused exporter tests**

Run:

```bash
swift test --filter MindMapPNGExporterTests
```

Expected: all `MindMapPNGExporterTests` pass, including:

- PNG encoding remains non-empty.
- PNG remains writable.
- Filename sanitization remains unchanged.
- The red marker below the initial viewport appears in the exported image.
- Frame, magnification, and scroll position are restored on success.
- The same state is restored when the snapshot action throws.

- [ ] **Step 3: Review the surgical diff**

Run:

```bash
git diff --check -- \
  AIRecording/Views/MindMapPNGExporter.swift \
  Tests/AIRecordingTests/MindMapPNGExporterTests.swift

git diff -- \
  AIRecording/Views/MindMapPNGExporter.swift \
  Tests/AIRecordingTests/MindMapPNGExporterTests.swift
```

Expected:

- No whitespace errors.
- No changes to PNG encoding or filename behavior.
- No changes outside the exporter and its tests.
- The earlier uncommitted `setFrameSize(contentSize)` attempt is replaced by the stabilized implementation, not duplicated.

- [ ] **Step 4: Commit the tested exporter fix**

Stage only the exporter and exporter tests:

```bash
git add -- \
  AIRecording/Views/MindMapPNGExporter.swift \
  Tests/AIRecordingTests/MindMapPNGExporterTests.swift
git commit -m "fix(chart): export complete mind map PNG"
```

Before committing, verify `git diff --cached --name-only` lists exactly those two paths.
Do not stage `AIRecording/Services/ChartPersistence.swift` or
`AIRecording/ViewModels/RecordingDetailViewModel.swift`.

### Task 3: Run SmartChart and full-package regression checks

**Files:**
- Test: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`
- Test: `Tests/AIRecordingTests/MindMapEditingTests.swift`
- Test: `Tests/AIRecordingTests/ChartZoomTests.swift`

- [ ] **Step 1: Build the macOS package**

Run:

```bash
swift build
```

Expected: exit code `0` and `Build complete!`.

- [ ] **Step 2: Run focused SmartChart regression suites**

Run:

```bash
swift test --filter MindMapPNGExporterTests
swift test --filter MindMapEditingTests
swift test --filter ChartZoomTests
```

Expected: all three commands exit `0`; no failures in export, edit-flush, or zoom behavior.

- [ ] **Step 3: Run the complete Swift test suite**

Run:

```bash
swift test
```

Expected: exit code `0` with zero failed tests.

- [ ] **Step 4: Verify the working tree still preserves unrelated edits**

Run:

```bash
git status --short
```

Expected: the pre-existing modifications to these paths remain unstaged unless the user separately changed their status:

```text
 M AIRecording/Services/ChartPersistence.swift
 M AIRecording/ViewModels/RecordingDetailViewModel.swift
```

No temporary HTML, PNG, cache, or test artifact should remain in the repository.

### Task 4: Perform the real long-mind-map acceptance check

**Files:**
- Modify after successful verification: `docs/superpowers/specs/2026-07-25-smartchart-full-page-png-export-design.md:4`

- [ ] **Step 1: Launch the app**

Run:

```bash
swift run AIRecording
```

Expected: the macOS app launches and displays the recording detail interface.

- [ ] **Step 2: Export a two-to-three-screen SmartChart**

Use the recording that reproduced the reported bug, open “智能图表”, and select “导出 PNG”.
Save the PNG outside the repository.

Verify all of the following:

- The PNG contains the title, content-type badge, summary box, and complete mind map.
- The final node appears.
- The width matches the current chart preview area.
- Text remains at the normal 100% export size.
- The final node is followed only by normal page padding, not a large empty region.
- The app returns to the same zoom level and scroll position after export.

If any item fails, do not mark the design implemented. Keep the failure evidence and return to Task 2.

- [ ] **Step 3: Mark the design implemented**

After every automated and manual check passes, change:

```markdown
- 状态：设计已确认，待实施
```

to:

```markdown
- 状态：已实施
```

- [ ] **Step 4: Commit the verified design status**

Run:

```bash
git add -- docs/superpowers/specs/2026-07-25-smartchart-full-page-png-export-design.md
git commit -m "docs: mark full-page PNG export implemented"
```

Expected: the commit contains only the one-line design status update.

