import CoreData
import Foundation

@objc(KnowledgeSourceLink)
public class KnowledgeSourceLink: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<KnowledgeSourceLink> {
        NSFetchRequest<KnowledgeSourceLink>(entityName: "KnowledgeSourceLink")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var sourceId: String?
    @NSManaged public var recordingId: UUID?
    @NSManaged public var segmentId: UUID?
    @NSManaged public var startTime: Double
    @NSManaged public var endTime: Double
    @NSManaged public var sourceOrder: Int32
    @NSManaged public var message: KnowledgeChatMessage?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
    }
}
