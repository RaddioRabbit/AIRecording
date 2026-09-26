import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct RecordingListView: View {
    @Binding var selectedRecordingObjectID: NSManagedObjectID?
    @Binding var knowledgeSourceNavigation: KnowledgeSourceNavigation?
    @StateObject private var viewModel = RecordingListViewModel()
    @State private var showNewRecording = false
    @State private var searchText = ""
    @State private var toastMessage: String? = nil
    @State private var showToast = false

    var body: some View {
        Group {
            if let objectID = selectedRecordingObjectID {
                RecordingDetailView(
                    objectID: objectID,
                    sourceNavigation: $knowledgeSourceNavigation,
                    onBack: {
                        selectedRecordingObjectID = nil
                        knowledgeSourceNavigation = nil
                    }
                )
            } else {
                listView
            }
        }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("录音列表")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { showImportPanel() }) {
                    Label("导入音频", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button(action: { showNewRecording = true }) {
                    Label("新建录音", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            // Toast overlay
            if showToast, let message = toastMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Search
            TextField("搜索录音...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onChange(of: searchText) { newValue in
                    viewModel.search(query: newValue)
                }

            // List
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.recordings, id: \.objectID) { recording in
                        VStack(spacing: 0) {
                            Button {
                                selectedRecordingObjectID = recording.objectID
                            } label: {
                                RecordingRowView(recording: recording)
                                    .padding(.horizontal)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        selectedRecordingObjectID == recording.objectID
                                            ? Color.accentColor.opacity(0.12)
                                            : Color.clear
                                    )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    viewModel.deleteRecording(recording)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showNewRecording) {
            NewRecordingView(isPresented: $showNewRecording)
        }
        .onAppear {
            viewModel.loadRecordings()
        }
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.wav, .mp3, UTType(filenameExtension: "m4a")].compactMap { $0 }
        panel.message = "选择要导入的音频文件（支持 .wav、.mp3 和 .m4a）"
        panel.prompt = "导入"
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        Task {
            let results = await AudioImportService.shared.importFiles(urls: urls)
            let errors = results.compactMap { $0.error }
            if !errors.isEmpty {
                let message = "\(errors.count) 个文件导入失败"
                await MainActor.run {
                    showToast(message: message)
                }
            }
        }
    }

    private func showToast(message: String) {
        toastMessage = message
        withAnimation {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showToast = false
            }
        }
    }
}

struct RecordingRowView: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(recording.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(recording.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: recording.sourceIconName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let transcription = recording.transcription {
                        if transcription.isProcessing {
                            Label("转录中", systemImage: "ellipsis.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if transcription.isCompleted {
                            Label("已转录", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            Spacer()

            // File size
            Text(recording.formattedFileSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
