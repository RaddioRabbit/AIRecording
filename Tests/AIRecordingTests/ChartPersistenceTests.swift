import CoreData
import XCTest
@testable import AIRecording

final class ChartPersistenceTests: XCTestCase {
    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext { persistence.container.viewContext }

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
    }

    override func tearDown() {
        persistence = nil
        super.tearDown()
    }

    private func makeRecording() -> Recording {
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.createdAt = Date()
        recording.updatedAt = Date()
        return recording
    }

    private func makeResponse(title: String = "周会纪要", html: String = "<div>chart</div>") -> SmartChartGenerateResponse {
        SmartChartGenerateResponse(
            version: "4.0",
            requestId: UUID().uuidString,
            status: "completed",
            contentType: .meeting,
            contentTypeDisplayName: "会议",
            chartType: "mindmap",
            chartTypeDisplayName: "思维导图",
            title: title,
            htmlFragment: html,
            errors: [],
            errorCode: nil
        )
    }

    func testSaveAndRestoreRoundtrip() {
        let recording = makeRecording()
        let response = makeResponse()

        ChartPersistence.save(response: response, for: recording, in: context)
        persistence.saveContext()

        let restored = ChartPersistence.latestResponse(for: recording)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.status, "completed")
        XCTAssertEqual(restored?.contentType, .meeting)
        XCTAssertEqual(restored?.contentTypeDisplayName, "会议")
        XCTAssertEqual(restored?.chartType, "mindmap")
        XCTAssertEqual(restored?.chartTypeDisplayName, "思维导图")
        XCTAssertEqual(restored?.title, "周会纪要")
        XCTAssertEqual(restored?.htmlFragment, "<div>chart</div>")
        XCTAssertEqual(restored?.errors, [])
    }

    func testSaveOverwritesPreviousChart() {
        let recording = makeRecording()
        ChartPersistence.save(response: makeResponse(title: "第一版"), for: recording, in: context)
        persistence.saveContext()

        ChartPersistence.save(response: makeResponse(title: "第二版"), for: recording, in: context)
        persistence.saveContext()

        XCTAssertEqual(recording.charts?.count, 1)
        XCTAssertEqual(ChartPersistence.latestResponse(for: recording)?.title, "第二版")
    }

    func testLatestResponseReturnsNilWhenNoChart() {
        let recording = makeRecording()
        persistence.saveContext()
        XCTAssertNil(ChartPersistence.latestResponse(for: recording))
    }

    func testLegacyChartWithoutHtmlFragmentIsIgnored() {
        let recording = makeRecording()
        // 模拟持久化功能上线前的旧 Chart 记录：没有 htmlFragment 字段值
        let legacy = Chart(context: context)
        legacy.id = UUID()
        legacy.recordingId = recording.id
        legacy.status = ChartStatus.completed.rawValue
        legacy.createdAt = Date()
        legacy.recording = recording
        persistence.saveContext()

        XCTAssertNil(ChartPersistence.latestResponse(for: recording))
    }

    private func makeMindMapDoc(rootText: String = "中心主题") -> MindMapDocDTO {
        MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: rootText),
            branches: [
                MindMapBranchDTO(
                    id: "b1",
                    text: "分支一",
                    segmentIds: ["s1"],
                    children: [MindMapNodeDTO(id: "b1c0", text: "要点一", segmentIds: ["s2"])]
                )
            ]
        )
    }

    func testSaveAndRestoreIncludesMindMapAndOverview() {
        let recording = makeRecording()
        var response = makeResponse()
        response.mindMap = makeMindMapDoc()
        response.overview = "共 1 个分支"

        ChartPersistence.save(response: response, for: recording, in: context)
        persistence.saveContext()

        let restored = ChartPersistence.latestResponse(for: recording)
        XCTAssertEqual(restored?.mindMap, makeMindMapDoc())
        XCTAssertEqual(restored?.overview, "共 1 个分支")
    }

    func testSaveEditsUpdatesMindMapAndFragment() {
        let recording = makeRecording()
        var response = makeResponse()
        response.mindMap = makeMindMapDoc()
        ChartPersistence.save(response: response, for: recording, in: context)
        persistence.saveContext()

        let edited = makeMindMapDoc(rootText: "改过的主题")
        ChartPersistence.saveEdits(mindMap: edited, htmlFragment: "<div>edited</div>", for: recording, in: context)
        persistence.saveContext()

        let restored = ChartPersistence.latestResponse(for: recording)
        XCTAssertEqual(restored?.mindMap?.root.text, "改过的主题")
        XCTAssertEqual(restored?.htmlFragment, "<div>edited</div>")
        XCTAssertEqual(restored?.title, "周会纪要", "编辑不得覆盖生成时的标题")
        XCTAssertEqual(recording.charts?.count, 1, "编辑不得新增 Chart 记录")
        let chart = try? XCTUnwrap((recording.charts as? Set<Chart>)?.first)
        XCTAssertEqual(chart?.isUserEdited, true)
    }

    func testSaveEditsWithoutChartDoesNothing() {
        let recording = makeRecording()
        persistence.saveContext()

        ChartPersistence.saveEdits(mindMap: makeMindMapDoc(), htmlFragment: nil, for: recording, in: context)
        persistence.saveContext()

        XCTAssertNil(ChartPersistence.latestResponse(for: recording))
    }
}
