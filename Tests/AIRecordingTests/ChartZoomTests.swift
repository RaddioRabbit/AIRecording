import CoreData
import XCTest
@testable import AIRecording

@MainActor
final class ChartZoomTests: XCTestCase {
    private func makeViewModel() -> RecordingDetailViewModel {
        let controller = PersistenceController(inMemory: true)
        let recording = Recording(context: controller.container.viewContext)
        recording.id = UUID()
        return RecordingDetailViewModel(objectID: recording.objectID)
    }

    func testClampChartZoomBounds() {
        XCTAssertEqual(RecordingDetailViewModel.clampChartZoom(0.1), 0.5)
        XCTAssertEqual(RecordingDetailViewModel.clampChartZoom(9.9), 3.0)
        XCTAssertEqual(RecordingDetailViewModel.clampChartZoom(1.2), 1.2)
    }

    func testZoomInOutStepAndClamp() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.chartZoom, 1.0)
        viewModel.zoomInChart()
        XCTAssertEqual(viewModel.chartZoom, 1.25)
        viewModel.zoomOutChart()
        viewModel.zoomOutChart()
        XCTAssertEqual(viewModel.chartZoom, 0.75)
        for _ in 0..<10 { viewModel.zoomOutChart() }
        XCTAssertEqual(viewModel.chartZoom, 0.5)
        for _ in 0..<20 { viewModel.zoomInChart() }
        XCTAssertEqual(viewModel.chartZoom, 3.0)
    }

    func testResetChartZoom() {
        let viewModel = makeViewModel()
        viewModel.zoomInChart()
        viewModel.resetChartZoom()
        XCTAssertEqual(viewModel.chartZoom, 1.0)
    }

    func testSetChartZoomClamps() {
        let viewModel = makeViewModel()
        viewModel.setChartZoom(4.2)
        XCTAssertEqual(viewModel.chartZoom, 3.0)
        viewModel.setChartZoom(0.05)
        XCTAssertEqual(viewModel.chartZoom, 0.5)
    }
}
