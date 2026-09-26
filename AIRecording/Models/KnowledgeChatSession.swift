import CoreData
import Foundation

@objc(KnowledgeChatSession)
public class KnowledgeChatSession: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<KnowledgeChatSession> {
        NSFetchRequest<KnowledgeChatSession>(entityName: "KnowledgeChatSession")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var title: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var messages: NSSet?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        if title == nil { title = "新建对话" }
        let now = Date()
        createdAt = now
        updatedAt = now
    }
}

extension KnowledgeChatSession {
    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: KnowledgeChatMessage)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: KnowledgeChatMessage)
}
