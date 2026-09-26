import CoreData
import Foundation
import XCTest
@testable import AIRecording

final class StubMindMapRenderer: MindMapRendering {
    var requests: [SmartChartRenderRequest] = []
    var error: Error?

    func render(request: SmartChartRenderRequest) async throws -> SmartChartRenderResponse {
        requests.append(request)
        if let error { throw error }
        return SmartChartRenderResponse(
            version: "5.0",
            requestId: request.requestId,
            status: "success",
            htmlFragment: "<div data-segment-ids=\"\">rendered-\(requests.count)</div>",
            errorCode: nil
        )
    }
}

@MainActor
final class MindMapEditingTests: XCTestCase {
    private var stub: StubMindMapRenderer!

    override func setUp() {
        super.setUp()
        stub = StubMindMapRenderer()
    }

    private func makeViewModel() -> RecordingDetailViewModel {
        let controller = PersistenceController(inMemory: true)
        let recording = Recording(context: controller.container.viewContext)
        recording.id = UUID()
        let viewModel = RecordingDetailViewModel(objectID: recording.objectID)
        viewModel.mindMapRenderer = stub
        return viewModel
    }

    private var sampleDoc: MindMapDocDTO {
        MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会"),
            branches: [
                MindMapBranchDTO(id: "b0", text: "议题一", segmentIds: ["s1"], children: [
                    MindMapNodeDTO(id: "b0c0", text: "结论一", segmentIds: ["s1"]),
                ]),
                MindMapBranchDTO(id: "b1", text: "议题二", segmentIds: ["s2"], children: []),
            ]
        )
    }

    func testUpdateRootTextChangesDoc() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateRootText("新的中心主题")
        XCTAssertEqual(viewModel.mindMapDoc?.root.text, "新的中心主题")
    }

    func testUpdateBranchTextClearsSegmentIds() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改过的议题")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].text, "改过的议题")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].segmentIds, [])
    }

    func testUpdateChildTextClearsSegmentIds() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateChildText(branchId: "b0", childId: "b0c0", text: "改过的结论")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children[0].text, "改过的结论")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children[0].segmentIds, [])
        // 未编辑的兄弟节点不受影响
        XCTAssertEqual(viewModel.mindMapDoc?.branches[1].segmentIds, ["s2"])
    }

    func testDeleteBranchRemovesIt() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.deleteBranch(branchId: "b0")
        XCTAssertEqual(viewModel.mindMapDoc?.branches.map(\.id), ["b1"])
    }

    func testDeleteChildRemovesIt() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.deleteChild(branchId: "b0", childId: "b0c0")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children, [])
    }

    func testAddChildAppendsSequentialIdWithEmptySegmentIds() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.addChild(branchId: "b0")
        viewModel.addChild(branchId: "b0")
        let children = viewModel.mindMapDoc?.branches[0].children ?? []
        XCTAssertEqual(children.map(\.id), ["b0c0", "b0c1", "b0c2"])
        XCTAssertEqual(children[1].segmentIds, [])
        XCTAssertEqual(children[2].text, "新要点")
    }

    func testDebounceMergesRapidEditsIntoOneRender() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改 1")
        viewModel.updateBranchText(branchId: "b0", text: "改 2")
        viewModel.addChild(branchId: "b1")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(stub.requests.count, 1, "300ms 内的连续编辑必须合并为一次 render 请求")
        XCTAssertEqual(viewModel.chartHtmlFragment, "<div data-segment-ids=\"\">rendered-1</div>")
        viewModel.cleanup()
    }

    func testRenderSkippedWhileGenerating() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.isGeneratingChart = true
        await viewModel.renderEditedMindMap()
        XCTAssertEqual(stub.requests.count, 0)
        viewModel.cleanup()
    }

    func testFailedRenderKeepsPreviewAndSetsError() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.chartHtmlFragment = "<div data-segment-ids=\"\">old</div>"
        stub.error = ChartSkillError.serviceNotRunning
        await viewModel.renderEditedMindMap()
        XCTAssertEqual(viewModel.chartHtmlFragment, "<div data-segment-ids=\"\">old</div>", "失败必须保留上一版预览")
        XCTAssertEqual(viewModel.mindMapEditError, "预览刷新失败，请重试")
        XCTAssertNotNil(viewModel.mindMapDoc, "失败不得丢弃大纲内容")
        viewModel.cleanup()
    }

    func testSanitizedForRenderReplacesBlankText() {
        let viewModel = makeViewModel()
        var doc = sampleDoc
        doc.branches[0].text = "   "
        let sanitized = viewModel.sanitizedForRender(doc)
        XCTAssertEqual(sanitized.branches[0].text, "未命名")
        XCTAssertEqual(sanitized.branches[0].children[0].text, "结论一")
    }

    func testCleanupCancelsPendingRender() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改")
        viewModel.cleanup()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(stub.requests.count, 0)
    }

    func testAddChildAfterNonLastDeletionAvoidsIdCollision() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.addChild(branchId: "b0") // children: b0c0, b0c1
        viewModel.deleteChild(branchId: "b0", childId: "b0c0") // children: b0c1
        viewModel.addChild(branchId: "b0")
        let children = viewModel.mindMapDoc?.branches[0].children ?? []
        XCTAssertEqual(children.map(\.id), ["b0c1", "b0c2"], "新增 id 不得与现有节点重复")
        // updateChildText 必须命中新节点，而不是同 id 的旧节点
        viewModel.updateChildText(branchId: "b0", childId: "b0c2", text: "编辑新要点")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children[1].text, "编辑新要点")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children[0].text, "新要点", "兄弟节点不受影响")
    }

    func testCancelledInFlightRenderDoesNotSetError() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        stub.error = URLError(.cancelled)
        let task = Task { await viewModel.renderEditedMindMap() }
        task.cancel()
        await task.value
        XCTAssertNil(viewModel.mindMapEditError, "被新编辑取消的在途渲染不得写入编辑错误")
        viewModel.cleanup()
    }

    func testFlushPendingRenderBeforeExportRendersImmediately() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改")
        XCTAssertEqual(stub.requests.count, 0, "防抖窗口内不应已发请求")
        let flushed = await viewModel.flushPendingMindMapRender()
        XCTAssertTrue(flushed)
        XCTAssertEqual(stub.requests.count, 1, "导出前必须把防抖中的编辑立即冲刷渲染")
        XCTAssertEqual(viewModel.chartHtmlFragment, "<div data-segment-ids=\"\">rendered-1</div>")
        viewModel.cleanup()
    }

    func testFlushPendingRenderFailureAbortsExport() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改")
        stub.error = ChartSkillError.serviceNotRunning
        let flushed = await viewModel.flushPendingMindMapRender()
        XCTAssertFalse(flushed, "冲刷失败必须中止导出，避免保存过期 PNG")
        XCTAssertEqual(viewModel.mindMapEditError, "预览刷新失败，请重试")
        viewModel.cleanup()
    }

    func testFlushWithoutPendingRenderIsNoop() async {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        let flushed = await viewModel.flushPendingMindMapRender()
        XCTAssertTrue(flushed)
        XCTAssertEqual(stub.requests.count, 0, "无待渲染编辑时不应发起请求")
        viewModel.cleanup()
    }
}
