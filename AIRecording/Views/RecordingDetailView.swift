import SwiftUI
import CoreData

struct RecordingDetailView: View {
    let objectID: NSManagedObjectID
    @Binding var sourceNavigation: KnowledgeSourceNavigation?
    let onBack: () -> Void

    @StateObject private var viewModel: RecordingDetailViewModel
    @State private var showSpeakerEdit = false
    @State private var speakerToEdit: String = ""
    @State private var editedSpeakerName: String = ""

    init(
        objectID: NSManagedObjectID,
        sourceNavigation: Binding<KnowledgeSourceNavigation?>,
        onBack: @escaping () -> Void
    ) {
        self.objectID = objectID
        _sourceNavigation = sourceNavigation
        self.onBack = onBack
        _viewModel = StateObject(wrappedValue: RecordingDetailViewModel(objectID: objectID))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                // Header
                headerView

                Divider()

                // Audio Player
                playerView

                Divider()

                // Transcription
                transcriptionView

                Divider()

                // AI Summary
                summaryView

                Divider()

                // Chart Panel
                chartPanelView

                Spacer(minLength: 40)
                }
                .padding()
            }
            .onChange(of: viewModel.highlightedSegmentId) { segmentID in
                guard let segmentID else { return }
                withAnimation {
                    proxy.scrollTo(segmentID, anchor: .center)
                }
            }
        }
        .onAppear {
            viewModel.loadRecording()
            if let sourceNavigation {
                viewModel.openKnowledgeSource(sourceNavigation)
                self.sourceNavigation = nil
            }
        }
        .onChange(of: sourceNavigation) { navigation in
            guard let navigation else { return }
            viewModel.openKnowledgeSource(navigation)
            sourceNavigation = nil
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .alert("编辑说话人名称", isPresented: $showSpeakerEdit) {
            TextField("名称", text: $editedSpeakerName)
            Button("保存") {
                saveSpeakerName()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("为 \"\(speakerToEdit)\" 设置显示名称")
        }
    }

    private func saveSpeakerName() {
        guard !speakerToEdit.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: "speaker.name.map") as? [String: String] ?? [:]
        map[speakerToEdit] = editedSpeakerName
        UserDefaults.standard.set(map, forKey: "speaker.name.map")
        viewModel.loadRecording()
    }

    private var headerView: some View {
        HStack {
            Button(action: onBack) {
                Label("返回", systemImage: "chevron.left")
            }

            Spacer()

            if let recording = viewModel.recording {
                VStack(spacing: 4) {
                    Text(recording.displayTitle)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("\(recording.formattedDate) · \(recording.formattedDuration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(recording.sourceDisplayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            if let recording = viewModel.recording {
                Menu {
                    Button {
                        viewModel.startTranscription()
                    } label: {
                        Label("重新转录", systemImage: "text.bubble")
                    }

                    Button(role: .destructive) {
                        viewModel.deleteRecording()
                        onBack()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var playerView: some View {
        VStack(spacing: 12) {
            // Waveform placeholder
            AudioWaveformView(levels: viewModel.waveformLevels, isPlaying: viewModel.isPlaying)
                .frame(height: 60)

            // Progress
            HStack {
                Text(formatTime(viewModel.currentTime))
                    .font(.caption)
                    .monospacedDigit()
                Slider(value: $viewModel.currentTime, in: 0...max(viewModel.duration, 1)) { editing in
                    if !editing {
                        viewModel.seek(to: viewModel.currentTime)
                    }
                }
                Text(formatTime(viewModel.duration))
                    .font(.caption)
                    .monospacedDigit()
            }

            // Controls
            HStack(spacing: 20) {
                Button(action: { viewModel.skipBackward() }) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.skipForward() }) {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Spacer()

                // Playback rate
                Picker("", selection: $viewModel.playbackRate) {
                    Text("0.5x").tag(0.5)
                    Text("1x").tag(1.0)
                    Text("1.5x").tag(1.5)
                    Text("2x").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: viewModel.playbackRate) { newValue in
                    viewModel.setPlaybackRate(newValue)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("转录文本")
                    .font(.headline)

                Spacer()

                if viewModel.isTranscribing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("转录中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let transcription = viewModel.recording?.transcription, transcription.isCompleted {
                    Button("重新转录") {
                        viewModel.startTranscription()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let transcription = viewModel.recording?.transcription {
                if transcription.isCompleted {
                    let paragraphs = viewModel.transcriptionParagraphs
                    if paragraphs.isEmpty {
                        HStack {
                            Spacer()
                            Text("未识别到语音内容")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else {
                        let isAppleSpeech = transcription.engine == Int16(TranscriptionEngine.appleSpeech.rawValue)
                        let hasSpeakerInfo = paragraphs.contains { !$0.speakerName.isEmpty }
                        if isAppleSpeech && !hasSpeakerInfo {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                Text("Apple Speech 引擎不支持说话人分离，切换到 Fun-ASR 可获得说话人区分效果。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(paragraphs) { paragraph in
                                TranscriptionParagraphRow(
                                    paragraph: paragraph,
                                    isHighlighted: viewModel.paragraphContainsHighlightedSegment(paragraph),
                                    onTapTime: {
                                        viewModel.seek(to: paragraph.startTime)
                                    },
                                    onEditSpeaker: {
                                        if let sid = paragraph.speakerId, !sid.isEmpty {
                                            speakerToEdit = sid
                                            editedSpeakerName = paragraph.speakerName
                                            showSpeakerEdit = true
                                        }
                                    }
                                )
                                .id(paragraph.id)
                            }
                        }
                    }
                } else if transcription.isProcessing {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView(value: viewModel.transcriptionProgress)
                                .frame(maxWidth: 240)
                            Text("正在识别语音，请稍候... \(Int(viewModel.transcriptionProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("停止转录") {
                                viewModel.cancelTranscription()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else if transcription.isFailed {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("转录失败")
                                .foregroundStyle(.secondary)
                            if let errorMsg = transcription.errorMessage, !errorMsg.isEmpty {
                                Text(errorMsg)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            Button("重试") {
                                viewModel.startTranscription()
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else {
                    Text("等待转录...")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        if let error = viewModel.transcriptionError {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("重试") {
                                viewModel.startTranscription()
                            }
                        } else {
                            Text("暂无转录")
                                .foregroundStyle(.secondary)
                            Button("开始转录") {
                                viewModel.startTranscription()
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 纪要")
                    .font(.headline)

                Spacer()

                if viewModel.isGeneratingSummary {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("生成中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.summary != nil {
                    HStack(spacing: 8) {
                        Button("导出 Word") {
                            viewModel.exportSummaryToWord()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isExportingSummary)

                        Button("重新生成") {
                            viewModel.generateSummary()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let error = viewModel.summaryError {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            viewModel.generateSummary()
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error = viewModel.exportSummaryError {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            viewModel.exportSummaryToWord()
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let summary = viewModel.summary {
                ScrollView {
                    MarkdownTextView(markdown: summary)
                        .font(.body)
                        .lineSpacing(6)
                }
                .frame(maxHeight: 400)
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("暂无纪要")
                            .foregroundStyle(.secondary)
                        Button("生成 AI 纪要") {
                            viewModel.generateSummary()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var chartHeaderView: some View {
        HStack {
            Text("智能图表")
                .font(.headline)
            Spacer()
            if viewModel.isGeneratingChart {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("生成中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.isRenderingMindMap {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("刷新中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let chart = viewModel.chartResult {
                HStack(spacing: 8) {
                    Text("\(chart.contentTypeDisplayName) · \(chart.chartTypeDisplayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let editError = viewModel.mindMapEditError {
                        Text(editError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("重新生成") {
                        viewModel.generateChart()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Menu {
                        Button("自动识别") { viewModel.generateChart() }
                        Divider()
                        ForEach(ContentType.allCases, id: \.self) { type in
                            Button(type.displayName) { viewModel.generateChart(forcedType: type) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        viewModel.zoomOutChart()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        viewModel.resetChartZoom()
                    } label: {
                        Text(viewModel.chartZoom, format: .percent.precision(.fractionLength(0)))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        viewModel.zoomInChart()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("导出 PNG") {
                        viewModel.exportMindMapPNG()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.mindMapDoc == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var mindMapOutlineSection: some View {
        if let doc = viewModel.mindMapDoc {
            VStack(alignment: .leading, spacing: 4) {
                Text("大纲编辑")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MindMapOutlineRow(
                    text: Binding(
                        get: { doc.root.text },
                        set: { viewModel.updateRootText($0) }
                    ),
                    indent: 0,
                    showsDelete: false,
                    onDelete: {}
                )
                ForEach(doc.branches) { branch in
                    MindMapOutlineRow(
                        text: Binding(
                            get: { branch.text },
                            set: { viewModel.updateBranchText(branchId: branch.id, text: $0) }
                        ),
                        indent: 1,
                        showsDelete: true,
                        onDelete: { viewModel.deleteBranch(branchId: branch.id) }
                    )
                    ForEach(branch.children) { child in
                        MindMapOutlineRow(
                            text: Binding(
                                get: { child.text },
                                set: { viewModel.updateChildText(branchId: branch.id, childId: child.id, text: $0) }
                            ),
                            indent: 2,
                            showsDelete: true,
                            onDelete: { viewModel.deleteChild(branchId: branch.id, childId: child.id) }
                        )
                    }
                    Button("+ 添加要点") {
                        viewModel.addChild(branchId: branch.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                }
            }
            .padding(12)
            .background(Color(hex: "#16162A"))
            .cornerRadius(12)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private var chartPanelView: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartHeaderView

            if let error = viewModel.chartError {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            viewModel.generateChart()
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if viewModel.chartResult != nil {
                ChartWebView(
                    htmlContent: viewModel.chartHtmlFragment ?? "",
                    zoomLevel: viewModel.chartZoom,
                    onZoomChanged: { viewModel.setChartZoom($0) },
                    onSegmentTap: { segmentIds in
                        viewModel.seekToEarliestSegment(segmentIds)
                    }
                )
                .frame(minHeight: 400)
                .background(Color(hex: "#0F0F1A"))
                .cornerRadius(12)

                mindMapOutlineSection
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("暂无图表")
                            .foregroundStyle(.secondary)
                        Button("生成图表") {
                            viewModel.generateChart()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(.vertical, 40)
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// 大纲编辑行：缩进 + TextField + 行尾悬停删除。无拖拽、无层级调整（设计文档 §8）。
struct MindMapOutlineRow: View {
    @Binding var text: String
    let indent: Int
    let showsDelete: Bool
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(indent == 0 ? .headline : (indent == 1 ? .body : .callout))
            if showsDelete && isHovering {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, CGFloat(indent * 24))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct TranscriptionParagraphRow: View {
    let paragraph: TranscriptionParagraph
    let isHighlighted: Bool
    let onTapTime: () -> Void
    let onEditSpeaker: () -> Void

    private var formattedTimeRange: String {
        let start = formatTime(paragraph.startTime)
        let end = formatTime(paragraph.endTime)
        return "[\(start) - \(end)]"
    }

    private var speakerColor: Color {
        guard !paragraph.speakerName.isEmpty else { return .secondary }
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        let stableHash = paragraph.speakerName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[stableHash % colors.count]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onTapTime) {
                Text(formattedTimeRange)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            if !paragraph.speakerName.isEmpty {
                Text(paragraph.speakerName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(speakerColor)
                    .cornerRadius(4)
                    .onTapGesture {
                        onEditSpeaker()
                    }
                    .help("点击编辑说话人名称")
            }

            Text(paragraph.text)
                .font(.body)
                .lineSpacing(4)

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
