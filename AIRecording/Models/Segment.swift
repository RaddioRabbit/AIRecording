import Foundation
import CoreData

@objc(TranscriptionSegment)
public class TranscriptionSegment: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TranscriptionSegment> {
        return NSFetchRequest<TranscriptionSegment>(entityName: "TranscriptionSegment")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var transcriptionId: UUID?
    @NSManaged public var startTime: Double
    @NSManaged public var endTime: Double
    @NSManaged public var speakerId: String?
    @NSManaged public var text: String?
    @NSManaged public var confidence: Float
    @NSManaged public var sequence: Int32

    @NSManaged public var transcription: Transcription?

    var formattedTimeRange: String {
        let start = formatTime(startTime)
        let end = formatTime(endTime)
        return "[\(start) - \(end)]"
    }

    var speakerDisplayName: String {
        guard let sid = speakerId, !sid.isEmpty else { return "" }
        if let map = UserDefaults.standard.dictionary(forKey: "speaker.name.map") as? [String: String],
           let custom = map[sid], !custom.isEmpty {
            return custom
        }
        return sid
    }

    private func formatTime(_ time: Double) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
