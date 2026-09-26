import CoreData
import SwiftUI

struct KnowledgeSourceChipsView: View {
    let sources: [KnowledgeSourceLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources.sorted { $0.sourceOrder < $1.sourceOrder }, id: \.objectID) { source in
                KnowledgeSourceChip(source: source)
            }
        }
    }
}

struct KnowledgeSourceNavigation: Sendable, Equatable {
    let recordingObjectURI: URL
    let segmentId: UUID?
    let startTime: TimeInterval

    @MainActor
    static func make(recording: Recording, source: KnowledgeSourceLink) -> Self? {
        guard !recording.isDeletedValue else { return nil }
        let matchingSegment = (recording.transcription?.segments as? Set<TranscriptionSegment>)?
            .first { $0.id == source.segmentId }
        return Self(
            recordingObjectURI: recording.objectID.uriRepresentation(),
            segmentId: matchingSegment?.id,
            startTime: matchingSegment?.startTime ?? source.startTime
        )
    }
}

enum KnowledgeSourceChipFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }
}

private struct KnowledgeSourceChip: View {
    let source: KnowledgeSourceLink
    @State private var isExpanded = false
    @State private var title = "录音"
    @State private var dateText = ""
    @State private var preview = ""
    @State private var navigation: KnowledgeSourceNavigation?
    @State private var recordingDeleted = false

    private var dateSuffix: String {
        dateText.isEmpty ? "" : " · \(dateText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
                if isExpanded { loadPreview() }
            } label: {
                Text("[\(source.sourceId ?? "S?")] \(title)\(dateSuffix) · \(Formatters.formatDuration(source.startTime))")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            if isExpanded {
                if preview.isEmpty {
                    Text("暂时无法加载原始转写预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Button(recordingDeleted ? "录音已删除" : "跳到录音") {
                    if !recordingDeleted {
                        openRecording()
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
                .disabled(recordingDeleted || navigation == nil)
            }
        }
        .task(id: source.objectID) {
            loadRecordingTitle()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: source.managedObjectContext
        )) { _ in
            loadRecordingTitle()
        }
    }

    private func loadRecordingTitle() {
        guard let recording = referencedRecording() else {
            recordingDeleted = true
            navigation = nil
            preview = ""
            dateText = ""
            return
        }
        recordingDeleted = false
        title = recording.displayTitle
        dateText = KnowledgeSourceChipFormatter.dateText(recording.createdAt)
        navigation = KnowledgeSourceNavigation.make(recording: recording, source: source)
    }

    private func loadPreview() {
        guard let recording = referencedRecording() else { return }
        guard let segmentID = source.segmentId,
              let segments = recording.transcription?.segments as? Set<TranscriptionSegment>,
              let segment = segments.first(where: { $0.id == segmentID }) else { return }
        preview = segment.text ?? ""
    }

    private func openRecording() {
        guard let recording = referencedRecording(),
              let target = KnowledgeSourceNavigation.make(recording: recording, source: source) else { return }
        navigation = target
        NotificationCenter.default.post(name: .openKnowledgeSource, object: target)
    }

    private func referencedRecording() -> Recording? {
        guard let recordingID = source.recordingId else { return nil }
        let context = PersistenceController.shared.container.viewContext
        let request = Recording.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@ AND isDeletedValue == NO", recordingID as CVarArg)
        return try? context.fetch(request).first
    }
}

extension Notification.Name {
    static let openKnowledgeSource = Notification.Name("openKnowledgeSource")
}
