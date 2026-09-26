import Foundation
import CoreData

@objc(ChartNode)
public class ChartNode: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ChartNode> {
        return NSFetchRequest<ChartNode>(entityName: "ChartNode")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var chartId: UUID?
    @NSManaged public var nodeId: String?
    @NSManaged public var label: String?
    @NSManaged public var level: Int32
    @NSManaged public var nodeType: Int16
    @NSManaged public var shape: String?
    @NSManaged public var color: String?
    @NSManaged public var metadata: String?
    @NSManaged public var sequence: Int32
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    @NSManaged public var chart: Chart?
}
