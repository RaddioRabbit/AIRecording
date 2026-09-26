import CoreData
import Foundation

enum KnowledgeMessageRole: Int16, CaseIterable {
    case user = 0
    case assistant = 1
}

enum KnowledgeMessageStatus: Int16, CaseIterable {
    case pending = 0
    case completed = 1
    case failed = 2
    case cancelled = 3
}

@objc(KnowledgeChatMessage)
public class KnowledgeChatMessage: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<KnowledgeChatMessage> {
        NSFetchRequest<KnowledgeChatMessage>(entityName: "KnowledgeChatMessage")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var role: Int16
    @NSManaged public var status: Int16
    @NSManaged public var content: String?
    @NSManaged public var errorCode: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var session: KnowledgeChatSession?
    @NSManaged public var sources: NSSet?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        if content == nil { content = "" }
        createdAt = Date()
    }

    var roleEnum: KnowledgeMessageRole {
        KnowledgeMessageRole(rawValue: role) ?? .assistant
    }

    var statusEnum: KnowledgeMessageStatus {
        KnowledgeMessageStatus(rawValue: status) ?? .failed
    }
}

extension KnowledgeChatMessage {
    @objc(addSourcesObject:)
    @NSManaged public func addToSources(_ value: KnowledgeSourceLink)

    @objc(removeSourcesObject:)
    @NSManaged public func removeFromSources(_ value: KnowledgeSourceLink)
}
