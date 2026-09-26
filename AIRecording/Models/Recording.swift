import Foundation
import CoreData

@objc(Recording)
public class Recording: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Recording> {
        return NSFetchRequest<Recording>(entityName: "Recording")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var filePath: String?
    @NSManaged public var fileFormat: String?
    @NSManaged public var duration: Int32
    @NSManaged public var sampleRate: Int32
    @NSManaged public var channels: Int32
    @NSManaged public var bitDepth: Int32
    @NSManaged public var fileSize: Double
    @NSManaged public var sourceType: Int16
    @NSManaged public var status: Int16
    @NSManaged public var title: String?
    @NSManaged public var customTitle: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var isEncrypted: Bool
    @NSManaged public var isFavorite: Bool
    @NSManaged public var isDeletedValue: Bool
    @NSManaged public var deletedAt: Date?
    @NSManaged public var storageLocation: String?

    @NSManaged public var transcription: Transcription?
    @NSManaged public var charts: NSSet?

    var displayTitle: String {
        return customTitle ?? title ?? "未命名录音"
    }

    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var formattedDate: String {
        guard let date = createdAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedFileSize: String {
        let size = fileSize
        let kb = size / 1024
        let mb = kb / 1024
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", kb)
        }
    }

    var audioURL: URL? {
        guard let path = filePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var sourceTypeEnum: AudioSource {
        return AudioSource(rawValue: Int(sourceType)) ?? .microphone
    }

    var sourceDisplayName: String {
        return sourceTypeEnum.displayName
    }

    var sourceIconName: String {
        return sourceTypeEnum.iconName
    }
}

// MARK: - Generated accessors for charts

extension Recording {
    @objc(addChartsObject:)
    @NSManaged public func addToCharts(_ value: Chart)

    @objc(removeChartsObject:)
    @NSManaged public func removeFromCharts(_ value: Chart)

    @objc(addCharts:)
    @NSManaged public func addToCharts(_ values: NSSet)

    @objc(removeCharts:)
    @NSManaged public func removeFromCharts(_ values: NSSet)
}
