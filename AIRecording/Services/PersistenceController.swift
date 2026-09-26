import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false, storeURL: URL? = nil) {
        container = NSPersistentContainer(name: "AIRecording", managedObjectModel: Self.model)

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            if let description = container.persistentStoreDescriptions.first {
                if let storeURL {
                    description.url = storeURL
                }
                description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
                description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
                description.setValue("WAL" as NSString, forPragmaNamed: "journal_mode")
                description.setValue("1" as NSString, forPragmaNamed: "foreign_keys")
            }
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved Core Data error: \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func saveContext() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                AppLogger.log(.error, category: "persistence", event: "core_data_save_failed",
                          metadata: ["errorDomain": nsError.domain, "errorCode": nsError.code])
            }
        }
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        return container.newBackgroundContext()
    }

    static var managedObjectModel: NSManagedObjectModel { model }

    // MARK: - Programmatic Model

    private static let model: NSManagedObjectModel = {
        let model = NSManagedObjectModel()

        // ---- Recording ----
        let recording = NSEntityDescription()
        recording.name = "Recording"
        recording.managedObjectClassName = NSStringFromClass(Recording.self)

        let recordingAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",                .UUIDAttributeType,          nil,    true),
            ("filePath",         .stringAttributeType,         nil,    true),
            ("fileFormat",       .stringAttributeType,         "caf",  true),
            ("duration",         .integer32AttributeType,      0,     false),
            ("sampleRate",       .integer32AttributeType,      44100, false),
            ("channels",         .integer32AttributeType,      1,     false),
            ("bitDepth",         .integer32AttributeType,      16,    false),
            ("fileSize",         .doubleAttributeType,         0,     false),
            ("sourceType",       .integer16AttributeType,      0,     false),
            ("status",           .integer16AttributeType,      0,     false),
            ("title",            .stringAttributeType,         nil,    true),
            ("customTitle",      .stringAttributeType,         nil,    true),
            ("createdAt",        .dateAttributeType,           nil,    true),
            ("updatedAt",        .dateAttributeType,           nil,    true),
            ("isEncrypted",      .booleanAttributeType,        false, false),
            ("isFavorite",       .booleanAttributeType,        false, false),
            ("isDeletedValue",   .booleanAttributeType,        false, false),
            ("deletedAt",        .dateAttributeType,           nil,    true),
            ("storageLocation",  .stringAttributeType,         "default", true),
        ]
        recording.properties = recordingAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- Transcription ----
        let transcription = NSEntityDescription()
        transcription.name = "Transcription"
        transcription.managedObjectClassName = NSStringFromClass(Transcription.self)

        let transcriptionAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",             .UUIDAttributeType,        nil,  true),
            ("recordingId",    .UUIDAttributeType,        nil,  true),
            ("engine",         .integer16AttributeType,   0,   false),
            ("status",         .integer16AttributeType,   0,   false),
            ("language",       .stringAttributeType,      nil,  true),
            ("confidence",     .doubleAttributeType,      0,   false),
            ("startedAt",      .dateAttributeType,        nil,  true),
            ("completedAt",    .dateAttributeType,        nil,  true),
            ("retryCount",     .integer32AttributeType,   0,   false),
            ("errorMessage",   .stringAttributeType,      nil,  true),
            ("summary",        .stringAttributeType,      nil,  true),
            ("createdAt",      .dateAttributeType,        nil,  true),
            ("updatedAt",      .dateAttributeType,        nil,  true),
        ]
        transcription.properties = transcriptionAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- TranscriptionSegment ----
        let segment = NSEntityDescription()
        segment.name = "TranscriptionSegment"
        segment.managedObjectClassName = NSStringFromClass(TranscriptionSegment.self)

        let segmentAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",              .UUIDAttributeType,         nil,  true),
            ("transcriptionId", .UUIDAttributeType,         nil,  true),
            ("startTime",       .doubleAttributeType,       0,   false),
            ("endTime",         .doubleAttributeType,       0,   false),
            ("speakerId",       .stringAttributeType,       nil,  true),
            ("text",            .stringAttributeType,       nil,  true),
            ("confidence",      .floatAttributeType,        0,   false),
            ("sequence",        .integer32AttributeType,    0,   false),
        ]
        segment.properties = segmentAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- KnowledgeChatSession ----
        let knowledgeSession = NSEntityDescription()
        knowledgeSession.name = "KnowledgeChatSession"
        knowledgeSession.managedObjectClassName = NSStringFromClass(KnowledgeChatSession.self)
        let knowledgeSessionAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id", .UUIDAttributeType, nil, true),
            ("title", .stringAttributeType, "新建对话", false),
            ("createdAt", .dateAttributeType, nil, true),
            ("updatedAt", .dateAttributeType, nil, true),
        ]
        knowledgeSession.properties = knowledgeSessionAttributes.map { (name, type, defaultValue, optional) in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.defaultValue = defaultValue
            attribute.isOptional = optional
            return attribute
        }

        // ---- KnowledgeChatMessage ----
        let knowledgeMessage = NSEntityDescription()
        knowledgeMessage.name = "KnowledgeChatMessage"
        knowledgeMessage.managedObjectClassName = NSStringFromClass(KnowledgeChatMessage.self)
        let knowledgeMessageAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id", .UUIDAttributeType, nil, true),
            ("role", .integer16AttributeType, KnowledgeMessageRole.user.rawValue, false),
            ("status", .integer16AttributeType, KnowledgeMessageStatus.completed.rawValue, false),
            ("content", .stringAttributeType, "", false),
            ("errorCode", .stringAttributeType, nil, true),
            ("createdAt", .dateAttributeType, nil, true),
        ]
        knowledgeMessage.properties = knowledgeMessageAttributes.map { (name, type, defaultValue, optional) in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.defaultValue = defaultValue
            attribute.isOptional = optional
            return attribute
        }

        // ---- KnowledgeSourceLink ----
        let knowledgeSource = NSEntityDescription()
        knowledgeSource.name = "KnowledgeSourceLink"
        knowledgeSource.managedObjectClassName = NSStringFromClass(KnowledgeSourceLink.self)
        let knowledgeSourceAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id", .UUIDAttributeType, nil, true),
            ("sourceId", .stringAttributeType, "", false),
            ("recordingId", .UUIDAttributeType, nil, true),
            ("segmentId", .UUIDAttributeType, nil, true),
            ("startTime", .doubleAttributeType, 0, false),
            ("endTime", .doubleAttributeType, 0, false),
            ("sourceOrder", .integer32AttributeType, 0, false),
        ]
        knowledgeSource.properties = knowledgeSourceAttributes.map { (name, type, defaultValue, optional) in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.defaultValue = defaultValue
            attribute.isOptional = optional
            return attribute
        }

        // ---- Relationships ----
        // Recording -> Transcription (1:1, cascade delete)
        let recToTrans = NSRelationshipDescription()
        recToTrans.name = "transcription"
        recToTrans.destinationEntity = transcription
        recToTrans.minCount = 0
        recToTrans.maxCount = 1
        recToTrans.deleteRule = .cascadeDeleteRule
        recToTrans.isOptional = true

        // Transcription -> Recording (1:1, nullify)
        let transToRec = NSRelationshipDescription()
        transToRec.name = "recording"
        transToRec.destinationEntity = recording
        transToRec.minCount = 0
        transToRec.maxCount = 1
        transToRec.deleteRule = .nullifyDeleteRule
        transToRec.isOptional = true
        transToRec.inverseRelationship = recToTrans
        recToTrans.inverseRelationship = transToRec

        // Transcription -> Segments (1:many, cascade delete)
        let transToSeg = NSRelationshipDescription()
        transToSeg.name = "segments"
        transToSeg.destinationEntity = segment
        transToSeg.minCount = 0
        transToSeg.maxCount = 0 // to-many
        transToSeg.deleteRule = .cascadeDeleteRule
        transToSeg.isOptional = true

        // Segment -> Transcription (many:1, nullify)
        let segToTrans = NSRelationshipDescription()
        segToTrans.name = "transcription"
        segToTrans.destinationEntity = transcription
        segToTrans.minCount = 0
        segToTrans.maxCount = 1
        segToTrans.deleteRule = .nullifyDeleteRule
        segToTrans.isOptional = true
        segToTrans.inverseRelationship = transToSeg
        transToSeg.inverseRelationship = segToTrans

        // KnowledgeChatSession -> KnowledgeChatMessage (1:many, cascade delete)
        let sessionToMessages = NSRelationshipDescription()
        sessionToMessages.name = "messages"
        sessionToMessages.destinationEntity = knowledgeMessage
        sessionToMessages.minCount = 0
        sessionToMessages.maxCount = 0
        sessionToMessages.deleteRule = .cascadeDeleteRule
        sessionToMessages.isOptional = true

        let messageToSession = NSRelationshipDescription()
        messageToSession.name = "session"
        messageToSession.destinationEntity = knowledgeSession
        messageToSession.minCount = 0
        messageToSession.maxCount = 1
        messageToSession.deleteRule = .nullifyDeleteRule
        messageToSession.isOptional = true
        messageToSession.inverseRelationship = sessionToMessages
        sessionToMessages.inverseRelationship = messageToSession

        // KnowledgeChatMessage -> KnowledgeSourceLink (1:many, cascade delete)
        let messageToSources = NSRelationshipDescription()
        messageToSources.name = "sources"
        messageToSources.destinationEntity = knowledgeSource
        messageToSources.minCount = 0
        messageToSources.maxCount = 0
        messageToSources.deleteRule = .cascadeDeleteRule
        messageToSources.isOptional = true

        let sourceToMessage = NSRelationshipDescription()
        sourceToMessage.name = "message"
        sourceToMessage.destinationEntity = knowledgeMessage
        sourceToMessage.minCount = 0
        sourceToMessage.maxCount = 1
        sourceToMessage.deleteRule = .nullifyDeleteRule
        sourceToMessage.isOptional = true
        sourceToMessage.inverseRelationship = messageToSources
        messageToSources.inverseRelationship = sourceToMessage

        // Add relationships to entities
        recording.properties.append(recToTrans)
        transcription.properties.append(transToRec)
        transcription.properties.append(transToSeg)
        segment.properties.append(segToTrans)
        knowledgeSession.properties.append(sessionToMessages)
        knowledgeMessage.properties.append(messageToSession)
        knowledgeMessage.properties.append(messageToSources)
        knowledgeSource.properties.append(sourceToMessage)

        // ---- Chart ----
        let chart = NSEntityDescription()
        chart.name = "Chart"
        chart.managedObjectClassName = NSStringFromClass(Chart.self)

        let chartAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",                .UUIDAttributeType,          nil,    true),
            ("recordingId",       .UUIDAttributeType,          nil,    true),
            ("summaryId",         .UUIDAttributeType,          nil,    true),
            ("chartType",         .integer16AttributeType,      0,     false),
            ("chartTypeConfidence", .doubleAttributeType,       0,     false),
            ("status",            .integer16AttributeType,      0,     false),
            ("styleTheme",        .stringAttributeType,         nil,    true),
            ("templateId",        .stringAttributeType,         nil,    true),
            ("nodeCount",         .integer32AttributeType,      0,     false),
            ("edgeCount",         .integer32AttributeType,      0,     false),
            ("maxDepth",          .integer32AttributeType,      0,     false),
            ("generationTimeMs",  .integer32AttributeType,      0,     false),
            ("version",           .integer32AttributeType,      0,     false),
            ("isUserEdited",      .booleanAttributeType,        false, false),
            ("parentChartId",     .UUIDAttributeType,          nil,    true),
            ("exportedImagePath", .stringAttributeType,         nil,    true),
            ("exportedSVGPath",   .stringAttributeType,         nil,    true),
            ("createdAt",         .dateAttributeType,           nil,    true),
            ("updatedAt",         .dateAttributeType,           nil,    true),
            ("errorMessage",      .stringAttributeType,         nil,    true),
            ("retryCount",        .integer32AttributeType,      0,     false),
            ("title",             .stringAttributeType,         nil,    true),
            ("contentType",       .stringAttributeType,         nil,    true),
            ("contentTypeDisplayName", .stringAttributeType,    nil,    true),
            ("chartTypeName",     .stringAttributeType,         nil,    true),
            ("chartTypeDisplayName", .stringAttributeType,      nil,    true),
            ("htmlFragment",      .stringAttributeType,         nil,    true),
            ("mindMapJSON",       .stringAttributeType,         nil,    true),
            ("overview",          .stringAttributeType,         nil,    true),
        ]
        chart.properties = chartAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- ChartNode ----
        let chartNode = NSEntityDescription()
        chartNode.name = "ChartNode"
        chartNode.managedObjectClassName = NSStringFromClass(ChartNode.self)

        let chartNodeAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",          .UUIDAttributeType,         nil,  true),
            ("chartId",     .UUIDAttributeType,         nil,  true),
            ("nodeId",      .stringAttributeType,       nil,  true),
            ("label",       .stringAttributeType,       nil,  true),
            ("level",       .integer32AttributeType,     0,   false),
            ("nodeType",    .integer16AttributeType,     0,   false),
            ("shape",       .stringAttributeType,       nil,  true),
            ("color",       .stringAttributeType,       nil,  true),
            ("metadata",    .stringAttributeType,       nil,  true),
            ("sequence",    .integer32AttributeType,     0,   false),
            ("createdAt",   .dateAttributeType,         nil,  true),
            ("updatedAt",   .dateAttributeType,         nil,  true),
        ]
        chartNode.properties = chartNodeAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- ChartEdge ----
        let chartEdge = NSEntityDescription()
        chartEdge.name = "ChartEdge"
        chartEdge.managedObjectClassName = NSStringFromClass(ChartEdge.self)

        let chartEdgeAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",            .UUIDAttributeType,         nil,  true),
            ("chartId",       .UUIDAttributeType,         nil,  true),
            ("sourceNodeId",  .stringAttributeType,       nil,  true),
            ("targetNodeId",  .stringAttributeType,       nil,  true),
            ("label",         .stringAttributeType,       nil,  true),
            ("edgeStyle",     .stringAttributeType,       nil,  true),
            ("arrowType",     .stringAttributeType,       nil,  true),
            ("sequence",      .integer32AttributeType,     0,   false),
            ("createdAt",     .dateAttributeType,         nil,  true),
        ]
        chartEdge.properties = chartEdgeAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- ChartJob ----
        let chartJob = NSEntityDescription()
        chartJob.name = "ChartJob"
        chartJob.managedObjectClassName = NSStringFromClass(ChartJob.self)

        let chartJobAttributes: [(String, NSAttributeType, Any?, Bool)] = [
            ("id",            .UUIDAttributeType,         nil,  true),
            ("chartId",       .UUIDAttributeType,         nil,  true),
            ("recordingId",   .UUIDAttributeType,         nil,  true),
            ("jobType",       .integer16AttributeType,     0,   false),
            ("status",        .integer16AttributeType,     0,   false),
            ("progress",      .integer32AttributeType,     0,   false),
            ("inputData",     .stringAttributeType,       nil,  true),
            ("startedAt",     .dateAttributeType,         nil,  true),
            ("completedAt",   .dateAttributeType,         nil,  true),
            ("errorMessage",  .stringAttributeType,       nil,  true),
            ("createdAt",     .dateAttributeType,         nil,  true),
        ]
        chartJob.properties = chartJobAttributes.map { (name, type, defaultVal, optional) in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.defaultValue = defaultVal
            attr.isOptional = optional
            return attr
        }

        // ---- Chart Relationships ----
        // Recording -> Chart (1:many, cascade delete)
        let recToChart = NSRelationshipDescription()
        recToChart.name = "charts"
        recToChart.destinationEntity = chart
        recToChart.minCount = 0
        recToChart.maxCount = 0 // to-many
        recToChart.deleteRule = .cascadeDeleteRule
        recToChart.isOptional = true

        // Chart -> Recording (many:1, nullify)
        let chartToRec = NSRelationshipDescription()
        chartToRec.name = "recording"
        chartToRec.destinationEntity = recording
        chartToRec.minCount = 0
        chartToRec.maxCount = 1
        chartToRec.deleteRule = .nullifyDeleteRule
        chartToRec.isOptional = true
        chartToRec.inverseRelationship = recToChart
        recToChart.inverseRelationship = chartToRec

        // Chart -> ChartNode (1:many, cascade delete)
        let chartToNode = NSRelationshipDescription()
        chartToNode.name = "nodes"
        chartToNode.destinationEntity = chartNode
        chartToNode.minCount = 0
        chartToNode.maxCount = 0
        chartToNode.deleteRule = .cascadeDeleteRule
        chartToNode.isOptional = true

        // ChartNode -> Chart (many:1, nullify)
        let nodeToChart = NSRelationshipDescription()
        nodeToChart.name = "chart"
        nodeToChart.destinationEntity = chart
        nodeToChart.minCount = 0
        nodeToChart.maxCount = 1
        nodeToChart.deleteRule = .nullifyDeleteRule
        nodeToChart.isOptional = true
        nodeToChart.inverseRelationship = chartToNode
        chartToNode.inverseRelationship = nodeToChart

        // Chart -> ChartEdge (1:many, cascade delete)
        let chartToEdge = NSRelationshipDescription()
        chartToEdge.name = "edges"
        chartToEdge.destinationEntity = chartEdge
        chartToEdge.minCount = 0
        chartToEdge.maxCount = 0
        chartToEdge.deleteRule = .cascadeDeleteRule
        chartToEdge.isOptional = true

        // ChartEdge -> Chart (many:1, nullify)
        let edgeToChart = NSRelationshipDescription()
        edgeToChart.name = "chart"
        edgeToChart.destinationEntity = chart
        edgeToChart.minCount = 0
        edgeToChart.maxCount = 1
        edgeToChart.deleteRule = .nullifyDeleteRule
        edgeToChart.isOptional = true
        edgeToChart.inverseRelationship = chartToEdge
        chartToEdge.inverseRelationship = edgeToChart

        // Chart -> ChartJob (1:many, cascade delete)
        let chartToJob = NSRelationshipDescription()
        chartToJob.name = "jobs"
        chartToJob.destinationEntity = chartJob
        chartToJob.minCount = 0
        chartToJob.maxCount = 0
        chartToJob.deleteRule = .cascadeDeleteRule
        chartToJob.isOptional = true

        // ChartJob -> Chart (many:1, nullify)
        let jobToChart = NSRelationshipDescription()
        jobToChart.name = "chart"
        jobToChart.destinationEntity = chart
        jobToChart.minCount = 0
        jobToChart.maxCount = 1
        jobToChart.deleteRule = .nullifyDeleteRule
        jobToChart.isOptional = true
        jobToChart.inverseRelationship = chartToJob
        chartToJob.inverseRelationship = jobToChart

        // Add relationships to entities
        recording.properties.append(recToChart)
        chart.properties.append(chartToRec)
        chart.properties.append(chartToNode)
        chart.properties.append(chartToEdge)
        chart.properties.append(chartToJob)
        chartNode.properties.append(nodeToChart)
        chartEdge.properties.append(edgeToChart)
        chartJob.properties.append(jobToChart)

        // ---- Register entities ----
        model.entities = [
            recording, transcription, segment,
            chart, chartNode, chartEdge, chartJob,
            knowledgeSession, knowledgeMessage, knowledgeSource
        ]

        return model
    }()
}
