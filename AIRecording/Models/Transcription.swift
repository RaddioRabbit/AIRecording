import Foundation
import CoreData

@objc(Transcription)
public class Transcription: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Transcription> {
        return NSFetchRequest<Transcription>(entityName: "Transcription")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var recordingId: UUID?
    @NSManaged public var engine: Int16
    @NSManaged public var status: Int16
    @NSManaged public var language: String?
    @NSManaged public var confidence: Double
    @NSManaged public var startedAt: Date?
    @NSManaged public var completedAt: Date?
    @NSManaged public var retryCount: Int32
    @NSManaged public var errorMessage: String?
    @NSManaged public var summary: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    @NSManaged public var recording: Recording?
    @NSManaged public var segments: NSSet?

    var isCompleted: Bool {
        return status == Int16(TranscriptionStatus.completed.rawValue)
    }

    var isProcessing: Bool {
        return status == Int16(TranscriptionStatus.processing.rawValue)
    }

    var isFailed: Bool {
        return status == Int16(TranscriptionStatus.failed.rawValue)
    }

    var fullText: String {
        guard let segments = segments as? Set<TranscriptionSegment> else { return "" }
        let sorted = segments.sorted { $0.sequence < $1.sequence }
        return sorted.map { $0.text ?? "" }.joined(separator: " ")
    }
}

// MARK: - Generated accessors for segments
extension Transcription {
    @objc(addSegmentsObject:)
    @NSManaged public func addToSegments(_ value: TranscriptionSegment)

    @objc(removeSegmentsObject:)
    @NSManaged public func removeFromSegments(_ value: TranscriptionSegment)

    @objc(addSegments:)
    @NSManaged public func addToSegments(_ values: NSSet)

    @objc(removeSegments:)
    @NSManaged public func removeFromSegments(_ values: NSSet)
}
