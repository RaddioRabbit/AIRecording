import CoreData

/// 智能图表结果的 Core Data 持久化：每段录音只保留最新一份图表。
/// 保存为覆盖写（先删旧记录），恢复时取 createdAt 最新且 htmlFragment 非空的一条。
enum ChartPersistence {

    /// 用生成成功的响应覆盖写入该录音的图表记录。调用方负责 saveContext()。
    static func save(response: SmartChartGenerateResponse, for recording: Recording, in context: NSManagedObjectContext) {
        if let existing = recording.charts as? Set<Chart> {
            for chart in existing {
                context.delete(chart)
            }
        }

        let chart = Chart(context: context)
        chart.id = UUID()
        chart.recordingId = recording.id
        chart.status = ChartStatus.completed.rawValue
        chart.title = response.title
        chart.contentType = response.contentType.rawValue
        chart.contentTypeDisplayName = response.contentTypeDisplayName
        chart.chartTypeName = response.chartType
        chart.chartTypeDisplayName = response.chartTypeDisplayName
        chart.htmlFragment = response.htmlFragment
        chart.mindMapJSON = response.mindMap.flatMap {
            try? JSONEncoder().encode($0)
        }.flatMap { String(data: $0, encoding: .utf8) }
        chart.overview = response.overview
        chart.createdAt = Date()
        chart.updatedAt = chart.createdAt
        chart.recording = recording
    }

    /// 恢复最近一次保存的图表；没有可用记录时返回 nil。
    static func latestResponse(for recording: Recording) -> SmartChartGenerateResponse? {
        guard let charts = recording.charts as? Set<Chart> else { return nil }
        let usable = charts.filter { chart in
            guard let fragment = chart.htmlFragment else { return false }
            return !fragment.isEmpty
        }
        guard let latest = usable.max(by: {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }) else { return nil }

        let contentType = ContentType(rawValue: latest.contentType ?? "") ?? .other
        let mindMap: MindMapDocDTO?
        if let json = latest.mindMapJSON {
            do {
                mindMap = try JSONDecoder().decode(MindMapDocDTO.self, from: Data(json.utf8))
            } catch {
                AppLogger.log(.warning, category: "chart", event: "mindmap_json_decode_failed",
                              metadata: ["error": String(describing: error)])
                mindMap = nil
            }
        } else {
            mindMap = nil
        }
        return SmartChartGenerateResponse(
            version: "5.0",
            requestId: latest.id?.uuidString ?? "",
            status: "completed",
            contentType: contentType,
            contentTypeDisplayName: latest.contentTypeDisplayName ?? contentType.displayName,
            chartType: latest.chartTypeName ?? "",
            chartTypeDisplayName: latest.chartTypeDisplayName ?? "",
            title: latest.title ?? "",
            htmlFragment: latest.htmlFragment ?? "",
            mindMap: mindMap,
            overview: latest.overview,
            errors: [],
            errorCode: nil
        )
    }

    /// 编辑后增量更新该录音最新一份图表的大纲与预览；没有记录时不做事。调用方负责 saveContext()。
    static func saveEdits(mindMap: MindMapDocDTO, htmlFragment: String?, for recording: Recording, in context: NSManagedObjectContext) {
        guard let charts = recording.charts as? Set<Chart>,
              let latest = charts.max(by: {
                  ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
              }) else { return }

        latest.mindMapJSON = (try? JSONEncoder().encode(mindMap)).flatMap { String(data: $0, encoding: .utf8) }
        if let htmlFragment {
            latest.htmlFragment = htmlFragment
        }
        latest.isUserEdited = true
        latest.updatedAt = Date()
    }
}
