import AppKit
import WebKit

/// 思维导图 PNG 导出：分块滚动截图拼接——保持 WebView 可见尺寸不变，
/// 逐视口滚动、截图，再垂直拼接成整页全图。
/// （WebKit 只栅格化窗口可见区域，拉高 frame 截全图会得到下半截空白。）
enum MindMapPNGExporter {
    typealias SnapshotAction = @MainActor (WKWebView, WKSnapshotConfiguration) async throws -> NSImage

    /// 分块纵向偏移序列：步长 = 视口高；末块对齐页面底部（与上一块允许重叠，
    /// 重叠区像素相同，拼接无副作用）。页面不足一屏时退化为单块 [0]。
    static func tileOffsets(pageHeight: CGFloat, viewportHeight: CGFloat) -> [CGFloat] {
        guard viewportHeight > 0 else { return [0] }
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
        // defer 是提前退出路径的兜底（fire-and-forget）；成功/失败分支里 await 的
        // restoreState 保证函数返回前恢复已完成——两者都有存在必要，勿删其一。
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

            // 先逐块捕获（含 await），再同步拼接——避免拼接上下文挂起。
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

            // 在固定 sRGB 位图上下文中拼接，而非 NSImage.lockFocus：
            // lockFocus 会按显示器描述文件重编码像素，在广色域/自定描述文件的 Mac 上
            // PNG 读回色彩偏移（纯色通道串扰不可逆）；固定 sRGB 上下文保证导出 PNG 色彩确定。
            var proposedRect = NSRect(origin: .zero, size: viewportSize)
            guard let firstTile = tiles.first?.image
                .cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw ChartSkillError.invalidResponse
            }
            let scale = CGFloat(firstTile.width) / viewportSize.width
            let pixelWidth = firstTile.width
            let pixelHeight = Int((pageHeight * scale).rounded())
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ChartSkillError.invalidResponse
            }
            // Quartz 坐标原点在左下角：页顶 offset 越大，目标 y 越小。
            for (offset, tile) in tiles {
                var tileRect = NSRect(origin: .zero, size: viewportSize)
                guard let cgTile = tile.cgImage(forProposedRect: &tileRect, context: nil, hints: nil) else {
                    throw ChartSkillError.invalidResponse
                }
                context.draw(
                    cgTile,
                    in: CGRect(
                        x: 0,
                        y: (pageHeight - offset - viewportSize.height) * scale,
                        width: CGFloat(pixelWidth),
                        height: viewportSize.height * scale
                    )
                )
            }
            guard let stitched = context.makeImage() else {
                throw ChartSkillError.invalidResponse
            }
            let image = NSImage(
                cgImage: stitched,
                size: NSSize(width: viewportSize.width, height: pageHeight)
            )

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
    private static func pageHeight(of webView: WKWebView) async throws -> CGFloat {
        let result = try await webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight))"
        )
        guard let height = result as? NSNumber, height.doubleValue > 0 else {
            throw ChartSkillError.invalidResponse
        }
        return CGFloat(height.doubleValue)
    }

    @MainActor
    private static func scrollPosition(of webView: WKWebView) async throws -> CGPoint {
        let result = try await webView.evaluateJavaScript("({x: window.scrollX, y: window.scrollY})")
        guard let position = result as? [String: Any],
              let x = position["x"] as? NSNumber,
              let y = position["y"] as? NSNumber else {
            throw ChartSkillError.invalidResponse
        }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    @MainActor
    private static func restoreState(
        of webView: WKWebView,
        magnification: CGFloat,
        scroll: CGPoint
    ) async throws {
        webView.magnification = magnification
        _ = try await webView.evaluateJavaScript("window.scrollTo(\(scroll.x), \(scroll.y))")
    }

    @MainActor
    private static func waitForPageLayout(in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.callAsyncJavaScript(
                """
                await new Promise(resolve => {
                    var done = false;
                    const finish = () => {
                        if (done) return;
                        done = true;
                        resolve();
                    };
                    requestAnimationFrame(() => requestAnimationFrame(finish));
                    setTimeout(finish, 100);
                })
                """,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// NSImage → PNG 数据（纯函数，可单测）。
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 导出默认文件名："<录音标题>-思维导图.png"，剔除文件系统非法字符。
    static func defaultFileName(recordingTitle: String) -> String {
        let cleaned = recordingTitle
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "录音" : cleaned
        return "\(base)-思维导图.png"
    }
}
