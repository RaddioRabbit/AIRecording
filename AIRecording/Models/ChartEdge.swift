import Foundation
import CoreData

@objc(ChartEdge)
public class ChartEdge: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ChartEdge> {
        return NSFetchRequest<ChartEdge>(entityName: "ChartEdge")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var chartId: UUID?
    @NSManaged public var sourceNodeId: String?
    @NSManaged public var targetNodeId: String?
    @NSManaged public var label: String?
    @NSManaged public var edgeStyle: String?
    @NSManaged public var arrowType: String?
    @NSManaged public var sequence: Int32
    @NSManaged public var createdAt: Date?

    @NSManaged public var chart: Chart?
}
