import Foundation
import CoreData

@objc(Chart)
public class Chart: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Chart> {
        return NSFetchRequest<Chart>(entityName: "Chart")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var recordingId: UUID?
    @NSManaged public var summaryId: UUID?
    @NSManaged public var chartType: Int16
    @NSManaged public var chartTypeConfidence: Double
    @NSManaged public var status: Int16
    @NSManaged public var styleTheme: String?
    @NSManaged public var templateId: String?
    @NSManaged public var nodeCount: Int32
    @NSManaged public var edgeCount: Int32
    @NSManaged public var maxDepth: Int32
    @NSManaged public var generationTimeMs: Int32
    @NSManaged public var version: Int32
    @NSManaged public var isUserEdited: Bool
    @NSManaged public var parentChartId: UUID?
    @NSManaged public var exportedImagePath: String?
    @NSManaged public var exportedSVGPath: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var errorMessage: String?
    @NSManaged public var retryCount: Int32
    @NSManaged public var title: String?
    @NSManaged public var contentType: String?
    @NSManaged public var contentTypeDisplayName: String?
    @NSManaged public var chartTypeName: String?
    @NSManaged public var chartTypeDisplayName: String?
    @NSManaged public var htmlFragment: String?
    @NSManaged public var mindMapJSON: String?
    @NSManaged public var overview: String?

    @NSManaged public var recording: Recording?
    @NSManaged public var nodes: NSSet?
    @NSManaged public var edges: NSSet?
    @NSManaged public var jobs: NSSet?
}

// MARK: - Generated accessors for nodes

extension Chart {
    @objc(addNodesObject:)
    @NSManaged public func addToNodes(_ value: ChartNode)

    @objc(removeNodesObject:)
    @NSManaged public func removeFromNodes(_ value: ChartNode)

    @objc(addNodes:)
    @NSManaged public func addToNodes(_ values: NSSet)

    @objc(removeNodes:)
    @NSManaged public func removeFromNodes(_ values: NSSet)
}

// MARK: - Generated accessors for edges

extension Chart {
    @objc(addEdgesObject:)
    @NSManaged public func addToEdges(_ value: ChartEdge)

    @objc(removeEdgesObject:)
    @NSManaged public func removeFromEdges(_ value: ChartEdge)

    @objc(addEdges:)
    @NSManaged public func addToEdges(_ values: NSSet)

    @objc(removeEdges:)
    @NSManaged public func removeFromEdges(_ values: NSSet)
}

// MARK: - Generated accessors for jobs

extension Chart {
    @objc(addJobsObject:)
    @NSManaged public func addToJobs(_ value: ChartJob)

    @objc(removeJobsObject:)
    @NSManaged public func removeFromJobs(_ value: ChartJob)

    @objc(addJobs:)
    @NSManaged public func addToJobs(_ values: NSSet)

    @objc(removeJobs:)
    @NSManaged public func removeFromJobs(_ values: NSSet)
}
