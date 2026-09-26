import SwiftUI

enum SidebarItem: Hashable {
    case recordings
    case knowledge
    case settings
}

struct MainWindowView: View {
    @State private var selectedItem: SidebarItem? = .recordings
    @State private var selectedRecordingObjectID: NSManagedObjectID?
    @State private var knowledgeSourceNavigation: KnowledgeSourceNavigation?
    @State private var showNewRecording = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .openRecordingDetail)) { notification in
            if let objectID = notification.object as? NSManagedObjectID {
                selectedRecordingObjectID = objectID
                selectedItem = .recordings
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            selectedItem = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKnowledgeSource)) { notification in
            guard let navigation = notification.object as? KnowledgeSourceNavigation,
                  let objectID = KnowledgeSourceNavigationResolver.recordingObjectID(
                    for: navigation,
                    in: PersistenceController.shared.container.viewContext
                  ) else { return }
            knowledgeSourceNavigation = navigation
            selectedRecordingObjectID = objectID
            selectedItem = .recordings
        }
    }

    private var sidebar: some View {
        List(selection: $selectedItem) {
            Section("录音") {
                NavigationLink(value: SidebarItem.recordings) {
                    Label("录音列表", systemImage: "waveform")
                }
            }

            Section("知识") {
                NavigationLink(value: SidebarItem.knowledge) {
                    Label("知识库", systemImage: "books.vertical")
                }
            }

            Section("配置") {
                NavigationLink(value: SidebarItem.settings) {
                    Label("设置", systemImage: "gear")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedItem {
        case .recordings:
            RecordingListView(
                selectedRecordingObjectID: $selectedRecordingObjectID,
                knowledgeSourceNavigation: $knowledgeSourceNavigation
            )
        case .knowledge:
            KnowledgeBaseView()
        case .settings:
            SettingsView()
        case .none:
            EmptyStateView()
        }
    }
}

@MainActor
enum KnowledgeSourceNavigationResolver {
    static func recordingObjectID(
        for navigation: KnowledgeSourceNavigation,
        in context: NSManagedObjectContext
    ) -> NSManagedObjectID? {
        guard let objectID = context.persistentStoreCoordinator?.managedObjectID(
            forURIRepresentation: navigation.recordingObjectURI
        ),
        let recording = try? context.existingObject(with: objectID) as? Recording,
        recording.isDeletedValue == false else {
            return nil
        }
        return objectID
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("AI 录音助手")
                .font(.title)
                .fontWeight(.semibold)
            Text("从菜单栏开始录音，或选择左侧录音列表")
                .foregroundStyle(.secondary)
        }
    }
}
