import Foundation
import CoreData

@objc(ChartJob)
public class ChartJob: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ChartJob> {
        return NSFetchRequest<ChartJob>(entityName: "ChartJob")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var chartId: UUID?
    @NSManaged public var recordingId: UUID?
    @NSManaged public var jobType: Int16
    @NSManaged public var status: Int16
    @NSManaged public var progress: Int32
    @NSManaged public var inputData: String?
    @NSManaged public var startedAt: Date?
    @NSManaged public var completedAt: Date?
    @NSManaged public var errorMessage: String?
    @NSManaged public var createdAt: Date?

    @NSManaged public var chart: Chart?
}
