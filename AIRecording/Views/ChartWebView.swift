import SwiftUI
import WebKit

struct ChartWebView: NSViewRepresentable {
    let htmlContent: String
    var zoomLevel: Double = 1.0
    var onZoomChanged: ((Double) -> Void)?
    var onSegmentTap: (([String]) -> Void)?

    /// 最近一次创建的 WebView（PNG 全尺寸快照的源）；弱引用，面板销毁后自动失效。
    static weak var currentWebView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "segmentTap")
        userContentController.addUserScript(
            WKUserScript(
                source: Self.segmentTapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        Self.currentWebView = webView
        context.coordinator.lastAppliedZoom = nil
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        if let old = context.coordinator.scrollWheelMonitor {
            NSEvent.removeMonitor(old)
            context.coordinator.scrollWheelMonitor = nil
        }
        context.coordinator.scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak webView, weak coordinator = context.coordinator] event in
            guard let webView, event.window === webView.window,
                  event.modifierFlags.contains(.command) else { return event }
            let locationInView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(locationInView) else { return event }
            let delta: Double
            if event.hasPreciseScrollingDeltas {
                delta = Double(event.scrollingDeltaY) * 0.002
            } else {
                delta = event.scrollingDeltaY > 0 ? 0.1 : -0.1
            }
            let newValue = RecordingDetailViewModel.clampChartZoom(webView.magnification + delta)
            webView.setMagnification(newValue, centeredAt: locationInView)
            coordinator?.onZoomChanged?(newValue)
            return nil
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSegmentTap = onSegmentTap
        context.coordinator.onZoomChanged = onZoomChanged
        // 只在 zoomLevel 相对本视图上次写入值变化时才应用；
        // 用户捏合直接改 WebView，不属于这种情况，不得回写覆盖。
        if context.coordinator.lastAppliedZoom == nil || abs(zoomLevel - context.coordinator.lastAppliedZoom!) > 0.001 {
            webView.magnification = zoomLevel
            context.coordinator.lastAppliedZoom = zoomLevel
        }
        let styledHTML = wrapWithDarkTheme(htmlContent)
        guard context.coordinator.loadedHTML != styledHTML else { return }
        context.coordinator.loadedHTML = styledHTML
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        if let monitor = coordinator.scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.scrollWheelMonitor = nil
        }
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "segmentTap")
        webView.configuration.userContentController.removeAllUserScripts()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSegmentTap: onSegmentTap)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onSegmentTap: (([String]) -> Void)?
        var loadedHTML: String?
        var onZoomChanged: ((Double) -> Void)?
        var scrollWheelMonitor: Any?
        var lastAppliedZoom: Double?

        init(onSegmentTap: (([String]) -> Void)?) {
            self.onSegmentTap = onSegmentTap
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "segmentTap",
                  let body = message.body as? String,
                  !body.isEmpty else { return }
            let segmentIDs = body
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !segmentIDs.isEmpty else { return }
            onSegmentTap?(segmentIDs)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isInternalDocument = url.scheme == "about" || url.scheme == "data"
            decisionHandler(isInternalDocument ? .allow : .cancel)
        }
    }

    private static let segmentTapScript = """
    document.addEventListener('click', event => {
      const element = event.target instanceof Element
        ? event.target.closest('[data-segment-ids]')
        : null;
      const ids = element?.getAttribute('data-segment-ids');
      if (ids) window.webkit.messageHandlers.segmentTap.postMessage(ids);
    });
    """

    private func wrapWithDarkTheme(_ html: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none';">
        <style>
        :root {
          --bg: #0F0F1A; --card: #1E1E2E; --border: #33334D;
          --text: #E2E8F0; --text-secondary: #94A3B8;
          --cyan: #22D3EE; --purple: #8B5CF6; --orange: #F59E0B;
          --green: #34C759; --red: #FF3B30; --blue: #3B82F6;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          background: var(--bg); color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          padding: 20px; min-height: 100vh;
        }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
}
