import Foundation
import CoreData
import Combine
import AVFoundation
import AppKit

struct TranscriptionParagraph: Identifiable {
    let id: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerId: String?
    let speakerName: String
    let text: String
    let segments: [TranscriptionSegment]
}

struct RecordingDetailSourceTarget: Equatable {
    let segmentID: UUID?
    let seekTime: TimeInterval
}

@MainActor
class RecordingDetailViewModel: ObservableObject {
    @Published var recording: Recording?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Double = 1.0
    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0
    @Published var waveformLevels: [Float] = []
    @Published var summary: String?
    @Published var isGeneratingSummary = false
    @Published var summaryError: String?
    @Published var transcriptionError: String?
    @Published var isGeneratingChart = false
    @Published var chartResult: SmartChartGenerateResponse?
    @Published var chartError: String?
    @Published var mindMapDoc: MindMapDocDTO?
    @Published var chartHtmlFragment: String?
    @Published var isRenderingMindMap = false
    @Published var mindMapEditError: String?
    @Published var highlightedSegmentId: String?
    @Published var isExportingSummary = false
    @Published var exportSummaryError: String?

    private let objectID: NSManagedObjectID
    private let persistence = PersistenceController.shared
    private let playerService = AudioPlayerService.shared
    private var cancellables = Set<AnyCancellable>()
    private var waveformTimer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    private var chartTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pendingSourceSeekTime: TimeInterval?
    /// /chart/render 客户端（测试注入桩实现）。
    var mindMapRenderer: any MindMapRendering = HTTPChartSkill.shared
    private let chartGate = ChartRequestGate()

    var transcriptionParagraphs: [TranscriptionParagraph] {
        guard let transcription = recording?.transcription, transcription.isCompleted,
              let segments = transcription.segments as? Set<TranscriptionSegment> else {
            return []
        }

        let sorted = segments.sorted { $0.sequence < $1.sequence }
        guard !sorted.isEmpty else { return [] }

        let hasSpeakerInfo = sorted.contains { segment in
            guard let sid = segment.speakerId else { return false }
            return !sid.isEmpty
        }

        var paragraphs: [TranscriptionParagraph] = []
        var currentSegments: [TranscriptionSegment] = []

        for segment in sorted {
            if currentSegments.isEmpty {
                currentSegments.append(segment)
                continue
            }

            let shouldMerge: Bool
            if hasSpeakerInfo {
                let lastSpeaker = currentSegments.last?.speakerId ?? ""
                let currentSpeaker = segment.speakerId ?? ""
                shouldMerge = lastSpeaker == currentSpeaker
            } else {
                shouldMerge = true
            }

            if shouldMerge {
                currentSegments.append(segment)
            } else {
                paragraphs.append(makeParagraph(from: currentSegments))
                currentSegments = [segment]
            }
        }

        if !currentSegments.isEmpty {
            paragraphs.append(makeParagraph(from: currentSegments))
        }

        return paragraphs
    }

    private func makeParagraph(from segments: [TranscriptionSegment]) -> TranscriptionParagraph {
        let startTime = segments.first?.startTime ?? 0
        let endTime = segments.last?.endTime ?? 0
        let speakerId = segments.first?.speakerId
        let speakerName = segments.first?.speakerDisplayName ?? ""
        let texts = segments.compactMap { $0.text }.filter { !$0.isEmpty }
        let mergedText = texts.joined(separator: " ")
        return TranscriptionParagraph(
            id: stableSegmentID(for: segments.first),
            startTime: startTime,
            endTime: endTime,
            speakerId: speakerId,
            speakerName: speakerName,
            text: mergedText,
            segments: segments
        )
    }

    static func resolveSourceTarget(
        segmentID: UUID?,
        startTime: TimeInterval,
        segments: [TranscriptionSegment]
    ) -> RecordingDetailSourceTarget {
        if let segmentID,
           let segment = segments.first(where: { $0.id == segmentID }) {
            return RecordingDetailSourceTarget(segmentID: segmentID, seekTime: max(segment.startTime, 0))
        }

        let nonEmptySegments = segments.filter {
            !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let fallback = nonEmptySegments.min(by: {
            sourceDistance(from: startTime, to: $0) < sourceDistance(from: startTime, to: $1)
        }) else {
            return RecordingDetailSourceTarget(segmentID: nil, seekTime: max(startTime, 0))
        }
        return RecordingDetailSourceTarget(segmentID: fallback.id, seekTime: max(startTime, 0))
    }

    private static func sourceDistance(from time: TimeInterval, to segment: TranscriptionSegment) -> TimeInterval {
        if time < segment.startTime { return segment.startTime - time }
        if time > segment.endTime { return time - segment.endTime }
        return 0
    }

    func paragraphContainsHighlightedSegment(_ paragraph: TranscriptionParagraph) -> Bool {
        guard let highlightedSegmentId else { return false }
        return paragraph.segments.contains { chartSegmentID(for: $0) == highlightedSegmentId }
    }

    init(objectID: NSManagedObjectID) {
        self.objectID = objectID
        bindPlayerService()
        bindContextChanges()
        bindTranscriptionProgress()
    }

    private func bindPlayerService() {
        playerService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isPlaying = state == .playing
                if state == .finished {
                    self?.stopWaveformTimer()
                }
            }
            .store(in: &cancellables)

        playerService.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
            }
            .store(in: &cancellables)

        playerService.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                self?.duration = dur
            }
            .store(in: &cancellables)
    }

    private func bindContextChanges() {
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: persistence.container.viewContext)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadRecording()
                // Recording is a reference type; assigning the same object does not trigger
                // objectWillChange. Force a refresh so the UI picks up transcription status changes.
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func bindTranscriptionProgress() {
        TranscriptionService.shared.$transcriptionProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.transcriptionProgress = progress
            }
            .store(in: &cancellables)
    }

    func loadRecording() {
        let context = persistence.container.viewContext
        do {
            if let rec = try context.existingObject(with: objectID) as? Recording {
                recording = rec
                self.summary = rec.transcription?.summary
                if mindMapDoc == nil, let restored = ChartPersistence.latestResponse(for: rec) {
                    applyChartResponse(restored)
                }
                if let url = rec.audioURL {
                    Task {
                        try? await playerService.load(url: url)
                        if let pendingSourceSeekTime {
                            playerService.seek(to: pendingSourceSeekTime)
                            self.pendingSourceSeekTime = nil
                        }
                    }
                }
            }
        } catch {
            AppLogger.log(.error, category: "persistence", event: "recording_load_failed",
                          metadata: ["errorType": String(describing: type(of: error))])
        }
    }

    func togglePlayPause() {
        if isPlaying {
            playerService.pause()
            stopWaveformTimer()
        } else {
            playerService.play()
            startWaveformTimer()
        }
    }

    func seek(to time: TimeInterval) {
        playerService.seek(to: time)
    }

    func openKnowledgeSource(_ navigation: KnowledgeSourceNavigation) {
        guard navigation.recordingObjectURI == objectID.uriRepresentation() else { return }
        let segments = ((recording?.transcription?.segments as? Set<TranscriptionSegment>) ?? [])
        let target = Self.resolveSourceTarget(
            segmentID: navigation.segmentId,
            startTime: navigation.startTime,
            segments: Array(segments)
        )
        pendingSourceSeekTime = target.seekTime
        seek(to: target.seekTime)
        if let segmentID = target.segmentID,
           let segment = segments.first(where: { $0.id == segmentID }) {
            highlightedSegmentId = chartSegmentID(for: segment)
        } else {
            highlightedSegmentId = nil
        }
    }

    func skipForward() {
        let newTime = min(currentTime + 10, duration)
        seek(to: newTime)
    }

    func skipBackward() {
        let newTime = max(currentTime - 10, 0)
        seek(to: newTime)
    }

    func setPlaybackRate(_ rate: Double) {
        playerService.setPlaybackRate(Float(rate))
    }

    func startTranscription() {
        guard let recording = recording else {
            AppLogger.log(.warning, category: "transcription", event: "manual_transcription_aborted",
                          message: "recording 为空")
            return
        }
        // Cancel any in-flight transcription before starting a new one
        cancelTranscription()
        AppLogger.log(.info, category: "transcription", event: "manual_transcription_started",
                      recordingId: recording.id?.uuidString,
                      metadata: ["existingState": recording.transcription?.isFailed == true ? "failed" : recording.transcription?.isProcessing == true ? "processing" : "none"])
        isTranscribing = true
        transcriptionProgress = 0
        transcriptionError = nil

        transcriptionTask = Task {
            do {
                _ = try await TranscriptionService.shared.transcribe(recording: recording)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTranscribing = false
                    loadRecording() // Refresh to get new transcription
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.log(.error, category: "transcription", event: "manual_transcription_failed",
                              recordingId: recording.id?.uuidString,
                              metadata: ["errorType": String(describing: type(of: error))])
                await MainActor.run {
                    isTranscribing = false
                    transcriptionError = (error as? TranscriptionError)?.localizedDescription ?? error.localizedDescription
                    loadRecording()
                }
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        TranscriptionService.shared.cancelTranscription()

        isTranscribing = false

        if let transcription = recording?.transcription, transcription.isProcessing {
            transcription.status = Int16(TranscriptionStatus.failed.rawValue)
            transcription.errorMessage = "已取消"
            transcription.updatedAt = Date()
            persistence.saveContext()
            loadRecording()
        }
    }

    func generateSummary() {
        guard let transcription = recording?.transcription, transcription.isCompleted else { return }
        let text = transcription.fullText
        guard !text.isEmpty else { return }

        isGeneratingSummary = true
        summaryError = nil

        Task {
            do {
                let result = try await LLMService.shared.generateSummary(from: text)
                await MainActor.run {
                    summary = result
                    isGeneratingSummary = false
                    if let rec = self.recording {
                        rec.transcription?.summary = result
                        rec.transcription?.updatedAt = Date()
                        self.persistence.saveContext()
                    }
                }
            } catch {
                await MainActor.run {
                    summaryError = (error as? LLMError)?.localizedDescription ?? error.localizedDescription
                    isGeneratingSummary = false
                }
            }
        }
    }

    func deleteRecording() {
        guard let recording = recording else { return }
        recording.isDeletedValue = true
        recording.deletedAt = Date()
        recording.updatedAt = Date()
        persistence.saveContext()
    }

    func generateChart(forcedType: ContentType? = nil) {
        guard let transcription = recording?.transcription, transcription.isCompleted else {
            chartError = "请先完成转录，再生成图表"
            return
        }
        let segments = (transcription.segments as? Set<TranscriptionSegment>) ?? []
        guard !segments.isEmpty else {
            chartError = "转录内容为空，无法生成图表"
            return
        }

        // Cancel the previous in-flight request; the gate token invalidates its late response.
        chartTask?.cancel()
        renderTask?.cancel()
        renderTask = nil
        let token = chartGate.begin()

        isGeneratingChart = true
        chartError = nil
        // 重新生成丢弃未导出的编辑，以新响应为准（设计文档 §8）
        mindMapDoc = nil
        chartHtmlFragment = nil
        mindMapEditError = nil
        highlightedSegmentId = nil

        let segmentDTOs = segments
            .sorted { $0.sequence < $1.sequence }
            .map { segment in
                TranscriptSegmentDTO(
                    id: chartSegmentID(for: segment),
                    speaker: segment.speakerDisplayName,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: segment.text ?? ""
                )
            }

        let request = SmartChartGenerateRequest(
            requestId: UUID().uuidString,
            recordingId: recording?.id?.uuidString ?? objectID.uriRepresentation().absoluteString,
            segments: segmentDTOs,
            summaryMarkdown: summary,
            forceContentType: forcedType
        )

        chartTask = Task {
            do {
                let response = try await HTTPChartSkill.shared.generate(request: request)
                guard chartGate.isCurrent(token), !Task.isCancelled else { return }
                applyChartResponse(response)
                if let rec = recording {
                    ChartPersistence.save(response: response, for: rec, in: persistence.container.viewContext)
                    persistence.saveContext()
                }
                isGeneratingChart = false
                chartTask = nil
            } catch is CancellationError {
                // A task cancelled because a newer request started owns a stale
                // token and must not clear the new request's loading state.
                guard chartGate.isCurrent(token) else { return }
                isGeneratingChart = false
                chartTask = nil
            } catch {
                guard chartGate.isCurrent(token), !Task.isCancelled else { return }
                chartError = (error as? ChartSkillError)?.localizedDescription
                    ?? error.localizedDescription
                isGeneratingChart = false
                chartTask = nil
            }
        }
    }

    // MARK: - Chart Zoom (v6)

    static let chartZoomRange: ClosedRange<Double> = 0.5...3.0
    static let chartZoomStep: Double = 0.25

    @Published var chartZoom: Double = 1.0

    static func clampChartZoom(_ value: Double) -> Double {
        min(chartZoomRange.upperBound, max(chartZoomRange.lowerBound, value))
    }

    /// 以 WebView 当前实际缩放为基准步进（触控板捏合直接改 WebView，按钮以它为准自愈）。
    func zoomInChart() { chartZoom = Self.clampChartZoom(currentChartMagnification() + Self.chartZoomStep) }
    func zoomOutChart() { chartZoom = Self.clampChartZoom(currentChartMagnification() - Self.chartZoomStep) }
    func resetChartZoom() {
        chartZoom = 1.0
        // 捏合可能已把 WebView 缩放到其他值而未回写 chartZoom；
        // 此时 updateNSView 会因值不变跳过，必须直接命令 WebView 复位。
        ChartWebView.currentWebView?.magnification = 1.0
    }

    /// ⌘+滚轮直接改了 WebView 后回写，保持百分比显示一致。
    func setChartZoom(_ value: Double) { chartZoom = Self.clampChartZoom(value) }

    private func currentChartMagnification() -> Double {
        guard let magnification = ChartWebView.currentWebView?.magnification else { return chartZoom }
        return Double(magnification)
    }

    // MARK: - Mind Map Editing (v5)

    private func applyChartResponse(_ response: SmartChartGenerateResponse) {
        chartResult = response
        chartHtmlFragment = response.htmlFragment
        mindMapDoc = response.mindMap
        mindMapEditError = nil
    }

    func updateRootText(_ text: String) {
        guard mindMapDoc != nil else { return }
        mindMapDoc?.root.text = text
        scheduleMindMapRender()
    }

    /// 文字编辑使节点脱离原文依据：segmentIds 置空，点图不再跳音频（设计文档 §4）。
    func updateBranchText(branchId: String, text: String) {
        guard let index = mindMapDoc?.branches.firstIndex(where: { $0.id == branchId }) else { return }
        mindMapDoc?.branches[index].text = text
        mindMapDoc?.branches[index].segmentIds = []
        scheduleMindMapRender()
    }

    func updateChildText(branchId: String, childId: String, text: String) {
        guard let branchIndex = mindMapDoc?.branches.firstIndex(where: { $0.id == branchId }),
              let childIndex = mindMapDoc?.branches[branchIndex].children.firstIndex(where: { $0.id == childId })
        else { return }
        mindMapDoc?.branches[branchIndex].children[childIndex].text = text
        mindMapDoc?.branches[branchIndex].children[childIndex].segmentIds = []
        scheduleMindMapRender()
    }

    func deleteBranch(branchId: String) {
        guard var doc = mindMapDoc,
              let index = doc.branches.firstIndex(where: { $0.id == branchId }) else { return }
        doc.branches.remove(at: index)
        mindMapDoc = doc
        scheduleMindMapRender()
    }

    func deleteChild(branchId: String, childId: String) {
        guard var doc = mindMapDoc,
              let branchIndex = doc.branches.firstIndex(where: { $0.id == branchId }),
              let childIndex = doc.branches[branchIndex].children.firstIndex(where: { $0.id == childId })
        else { return }
        doc.branches[branchIndex].children.remove(at: childIndex)
        mindMapDoc = doc
        scheduleMindMapRender()
    }

    /// 只能在分支末尾新增要点；新节点 segmentIds 为空（无原文依据）。
    /// id 序号取现有最大序号 +1，删除中间要点后新增也不会撞 id。
    func addChild(branchId: String) {
        guard var doc = mindMapDoc,
              let index = doc.branches.firstIndex(where: { $0.id == branchId }) else { return }
        let prefix = "\(branchId)c"
        let nextSuffix = (doc.branches[index].children.compactMap { child -> Int? in
            guard child.id.hasPrefix(prefix) else { return nil }
            return Int(child.id.dropFirst(prefix.count))
        }.max() ?? -1) + 1
        doc.branches[index].children.append(MindMapNodeDTO(id: "\(prefix)\(nextSuffix)", text: "新要点", segmentIds: []))
        mindMapDoc = doc
        scheduleMindMapRender()
    }

    /// 300ms 防抖：连续编辑合并为一次 /chart/render 请求。
    private func scheduleMindMapRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            // 先落盘大纲，即使渲染失败或页面退出，编辑内容也不会丢。
            self?.persistMindMapEdits()
            await self?.renderEditedMindMap()
        }
    }

    /// 把编辑后的大纲（及可选的新预览）写回 Core Data，退出页面后再次进入可恢复。
    private func persistMindMapEdits(htmlFragment: String? = nil) {
        guard let doc = mindMapDoc, let rec = recording else { return }
        ChartPersistence.saveEdits(mindMap: doc, htmlFragment: htmlFragment, for: rec, in: persistence.container.viewContext)
        persistence.saveContext()
    }

    /// 调 /chart/render 重渲染编辑后的 doc；走 ChartRequestGate 防旧响应覆盖；
    /// 生成进行中不发起；失败保留上一版预览，大纲内容不丢（设计文档 §7.4）。
    func renderEditedMindMap() async {
        guard let doc = mindMapDoc, !isGeneratingChart else { return }
        let token = chartGate.begin()
        let request = SmartChartRenderRequest(
            recordingId: recording?.id?.uuidString ?? objectID.uriRepresentation().absoluteString,
            mindMap: sanitizedForRender(doc),
            overview: chartResult?.overview
        )
        isRenderingMindMap = true
        do {
            let response = try await mindMapRenderer.render(request: request)
            // 被取消/过期的渲染不得提前清掉新渲染的刷新指示，直接返回。
            guard chartGate.isCurrent(token), !Task.isCancelled else { return }
            isRenderingMindMap = false
            chartHtmlFragment = response.htmlFragment
            mindMapEditError = nil
            persistMindMapEdits(htmlFragment: response.htmlFragment)
        } catch {
            // 新编辑取消了在途渲染：任务已取消时不写错误、不记日志（与成功路径一致）。
            guard !Task.isCancelled, chartGate.isCurrent(token) else { return }
            isRenderingMindMap = false
            mindMapEditError = "预览刷新失败，请重试"
            AppLogger.log(.warning, category: "chart", event: "mindmap_render_failed",
                          recordingId: recording?.id?.uuidString,
                          metadata: ["errorType": String(describing: type(of: error))])
        }
    }

    /// 发送前把空白文本替换为占位文字（后端 schema 要求 text 非空）；本地编辑内容不变。
    func sanitizedForRender(_ doc: MindMapDocDTO) -> MindMapDocDTO {
        func clean(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "未命名" : trimmed
        }
        return MindMapDocDTO(
            root: MindMapRootDTO(id: doc.root.id, text: clean(doc.root.text)),
            branches: doc.branches.map { branch in
                MindMapBranchDTO(
                    id: branch.id,
                    text: clean(branch.text),
                    segmentIds: branch.segmentIds,
                    children: branch.children.map {
                        MindMapNodeDTO(id: $0.id, text: clean($0.text), segmentIds: $0.segmentIds)
                    }
                )
            }
        )
    }

    /// 导出前冲刷防抖中的待渲染编辑：取消防抖任务并立即重渲染，保证快照反映当前大纲。
    /// 返回 false 表示放弃导出（冲刷失败，错误已由 renderEditedMindMap 写入 mindMapEditError）。
    @discardableResult
    func flushPendingMindMapRender() async -> Bool {
        guard renderTask != nil else { return true }
        renderTask?.cancel()
        renderTask = nil
        await renderEditedMindMap()
        return mindMapEditError == nil
    }

    /// 导出当前编辑结果对应预览的完整全图为 PNG（NSSavePanel 写盘）。
    func exportMindMapPNG() {
        guard mindMapDoc != nil, let recording else { return }
        guard let webView = ChartWebView.currentWebView else {
            mindMapEditError = "图表尚未渲染完成，无法导出"
            return
        }
        Task {
            // 编辑→立即导出：先冲刷防抖中的渲染，失败则不保存已知过期的 PNG。
            guard await flushPendingMindMapRender() else { return }
            do {
                let image = try await MindMapPNGExporter.snapshotFullPage(of: webView)
                guard let pngData = MindMapPNGExporter.pngData(from: image) else {
                    throw ChartSkillError.invalidResponse
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = MindMapPNGExporter.defaultFileName(
                    recordingTitle: recording.displayTitle
                )
                panel.canCreateDirectories = true
                let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
                guard response == .OK, let url = panel.url else { return }
                try pngData.write(to: url, options: .atomic)
                AppLogger.log(.info, category: "chart", event: "mindmap_png_exported",
                              recordingId: recording.id?.uuidString)
            } catch {
                mindMapEditError = "导出失败，请重试"
                AppLogger.log(.error, category: "chart", event: "mindmap_png_export_failed",
                              recordingId: recording.id?.uuidString,
                              metadata: ["errorType": String(describing: type(of: error))])
            }
        }
    }

    func seekToSegment(_ segmentId: String) {
        guard let transcription = recording?.transcription,
              let segments = transcription.segments as? Set<TranscriptionSegment>,
              let segment = segments.first(where: { chartSegmentID(for: $0) == segmentId }) else {
            return
        }
        let startTime = max(segment.startTime, 0)
        seek(to: startTime)
        highlightedSegmentId = segmentId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.highlightedSegmentId == segmentId {
                self?.highlightedSegmentId = nil
            }
        }
    }

    func seekToEarliestSegment(_ segmentIds: [String]) {
        guard let transcription = recording?.transcription,
              let segments = transcription.segments as? Set<TranscriptionSegment> else {
            return
        }
        let startTimes = Dictionary(uniqueKeysWithValues: segments.map {
            (chartSegmentID(for: $0), $0.startTime)
        })
        guard let earliestID = ChartSourceResolver.earliestSegmentID(
            in: segmentIds,
            startTimes: startTimes
        ) else {
            return
        }
        seekToSegment(earliestID)
    }

    private func chartSegmentID(for segment: TranscriptionSegment) -> String {
        stableSegmentID(for: segment)
    }

    private func stableSegmentID(for segment: TranscriptionSegment?) -> String {
        guard let segment else { return "segment-missing" }
        return segment.id?.uuidString ?? segment.objectID.uriRepresentation().absoluteString
    }

    func exportSummaryToWord() {
        guard let recording = recording else {
            exportSummaryError = "录音未加载"
            return
        }
        guard let summary = summary, !summary.isEmpty else {
            exportSummaryError = "暂无纪要内容"
            return
        }

        isExportingSummary = true
        exportSummaryError = nil

        Task {
            do {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.init(filenameExtension: "docx")!]
                panel.nameFieldStringValue = "会议纪要_\(recording.displayTitle).docx"
                panel.canCreateDirectories = true

                let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
                guard response == .OK, let url = panel.url else {
                    await MainActor.run {
                        isExportingSummary = false
                    }
                    return
                }

                try await DocxExportService.shared.export(
                    summary: summary,
                    recording: recording,
                    destinationURL: url
                )

                await MainActor.run {
                    isExportingSummary = false
                }
            } catch {
                await MainActor.run {
                    exportSummaryError = error.localizedDescription
                    isExportingSummary = false
                }
            }
        }
    }

    func cleanup() {
        chartTask?.cancel()
        chartTask = nil
        renderTask?.cancel()
        renderTask = nil
        chartGate.invalidate()
        isGeneratingChart = false

        playerService.stop()
        stopWaveformTimer()
        cancellables.removeAll()
    }

    private func startWaveformTimer() {
        stopWaveformTimer()
        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var levels = self.waveformLevels
            levels.append(Float.random(in: 0.1...0.8))
            if levels.count > 100 {
                levels.removeFirst()
            }
            self.waveformLevels = levels
        }
    }

    private func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        waveformLevels = []
    }
}
