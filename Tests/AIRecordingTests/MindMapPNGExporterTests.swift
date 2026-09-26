import AppKit
import WebKit
import XCTest
@testable import AIRecording

final class MindMapPNGExporterTests: XCTestCase {
    private enum ForcedSnapshotError: Error {
        case failed
    }

    @MainActor
    private func loadedWebView() async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 11, y: 13, width: 320, height: 240))
        try await load(
            """
            <!doctype html><html><head><style>
            html, body { margin: 0; background: #111111; }
            #spacer { height: 1400px; }
            #marker { width: 320px; height: 80px; background: #ff0000; }
            </style></head><body><div id="spacer"></div><div id="marker"></div></body></html>
            """,
            in: webView
        )
        return webView
    }

    @MainActor
    private func load(_ html: String, in webView: WKWebView) async throws {
        webView.loadHTMLString(html, baseURL: nil)

        for _ in 0..<100 {
            let readyState = try? await webView.evaluateJavaScript("document.readyState") as? String
            if readyState == "complete" {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChartSkillError.invalidResponse
    }

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
        // 注意：本测试验证的是分块纵向位置而非色彩保真——NSBitmapImageRep(data:) 读回 PNG 后
        // 被标为 Generic RGB，ColorSync 转 deviceRGB 对饱和色有固定串扰（实测红→G 0.149），
        // 逐通道 0.05 精度在部分 Mac 上物理不可达；调色板 8 色互相距离足够大，
        // 最近邻归类对色彩管理鲁棒。
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
            // 最近邻归类：采样色与调色板各色在 deviceRGB 空间比距离
            var nearestIndex = -1
            var nearestDistance = Double.greatestFiniteMagnitude
            for (paletteIndex, paletteColor) in colors.enumerated() {
                let expected = try XCTUnwrap(paletteColor.usingColorSpace(.deviceRGB))
                let dr = sampled.redComponent - expected.redComponent
                let dg = sampled.greenComponent - expected.greenComponent
                let db = sampled.blueComponent - expected.blueComponent
                let distance = dr * dr + dg * dg + db * db
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = paletteIndex
                }
            }
            XCTAssertEqual(nearestIndex, index % colors.count, "tile \(index) 落带颜色不匹配")
        }
    }

    @MainActor
    private func pageScrollY(of webView: WKWebView) async throws -> CGFloat {
        guard let value = try await webView.evaluateJavaScript("window.scrollY") as? NSNumber else {
            throw ChartSkillError.invalidResponse
        }
        return CGFloat(value.doubleValue)
    }

    private func containsRedMarker(in image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return false }

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8,
                   color.greenComponent < 0.2,
                   color.blueComponent < 0.2 {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    func testSnapshotFullPageRendersBelowViewportAndRestoresState() async throws {
        let webView = try await loadedWebView()
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 120)")

        let originalFrame = webView.frame
        let originalMagnification = webView.magnification
        let originalScrollY = try await pageScrollY(of: webView)

        let image = try await MindMapPNGExporter.snapshotFullPage(of: webView)

        XCTAssertEqual(image.size.width, originalFrame.width, accuracy: 2)
        XCTAssertGreaterThan(image.size.height, 1450)
        XCTAssertTrue(containsRedMarker(in: image))
        XCTAssertEqual(webView.frame, originalFrame)
        XCTAssertEqual(webView.magnification, originalMagnification)
        let restoredScrollY = try await pageScrollY(of: webView)
        XCTAssertEqual(restoredScrollY, originalScrollY, accuracy: 1)
    }

    @MainActor
    func testSnapshotFailureRestoresWebViewState() async throws {
        let webView = try await loadedWebView()
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 120)")

        let originalFrame = webView.frame
        let originalMagnification = webView.magnification
        let originalScrollY = try await pageScrollY(of: webView)

        do {
            _ = try await MindMapPNGExporter.snapshotFullPage(of: webView) { _, _ in
                XCTAssertEqual(webView.magnification, 1.0)
                throw ForcedSnapshotError.failed
            }
            XCTFail("Expected injected snapshot failure")
        } catch ForcedSnapshotError.failed {
            // Expected: restoration must occur even when WebKit capture fails.
        }

        XCTAssertEqual(webView.frame, originalFrame)
        XCTAssertEqual(webView.magnification, originalMagnification)
        let restoredScrollY = try await pageScrollY(of: webView)
        XCTAssertEqual(restoredScrollY, originalScrollY, accuracy: 1)
    }

    func testPNGDataFromImageIsNonEmpty() {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()

        let data = MindMapPNGExporter.pngData(from: image)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
        // PNG 魔数
        XCTAssertEqual(data?.prefix(8).count, 8)
        XCTAssertEqual(data?.first, 0x89)
    }

    func testPNGDataWritableToTempFile() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(MindMapPNGExporter.pngData(from: image))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(NSImage(contentsOf: url))
    }

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
        // 视口高为零/页面高为零：均退化为单块，不死循环
        XCTAssertEqual(MindMapPNGExporter.tileOffsets(pageHeight: 1480, viewportHeight: 0), [0])
        XCTAssertEqual(MindMapPNGExporter.tileOffsets(pageHeight: 0, viewportHeight: 240), [0])
    }

    func testDefaultFileNameSanitizesIllegalCharacters() {
        XCTAssertEqual(
            MindMapPNGExporter.defaultFileName(recordingTitle: "周会/复盘: 9月"),
            "周会 复盘  9月-思维导图.png"
        )
        XCTAssertEqual(MindMapPNGExporter.defaultFileName(recordingTitle: "   "), "录音-思维导图.png")
        XCTAssertEqual(MindMapPNGExporter.defaultFileName(recordingTitle: "常规标题"), "常规标题-思维导图.png")
    }
}
