import Foundation
import CoreData
import Combine

@MainActor
class RecordingListViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var errorMessage: String?

    private let persistence = PersistenceController.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for context changes to refresh list
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: persistence.container.viewContext)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadRecordings()
            }
            .store(in: &cancellables)
    }

    func loadRecordings() {
        let context = persistence.container.viewContext
        let request: NSFetchRequest<Recording> = Recording.fetchRequest()
        request.predicate = NSPredicate(format: "isDeletedValue == false")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            recordings = try context.fetch(request)
        } catch {
            errorMessage = "加载录音失败: \(error.localizedDescription)"
            recordings = []
        }
    }

    func search(query: String) {
        guard !query.isEmpty else {
            loadRecordings()
            return
        }

        let context = persistence.container.viewContext
        let request: NSFetchRequest<Recording> = Recording.fetchRequest()
        request.predicate = NSPredicate(
            format: "isDeletedValue == false AND (title CONTAINS[cd] %@ OR customTitle CONTAINS[cd] %@)",
            query, query
        )
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            recordings = try context.fetch(request)
        } catch {
            errorMessage = "搜索失败: \(error.localizedDescription)"
        }
    }

    func deleteRecording(_ recording: Recording) {
        recording.isDeletedValue = true
        recording.deletedAt = Date()
        recording.updatedAt = Date()
        persistence.saveContext()
        loadRecordings()
    }
}
