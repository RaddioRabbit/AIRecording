import XCTest
@testable import AIRecording

final class KnowledgeSourceChipFormatterTests: XCTestCase {
    func testDateTextFormatsLocalCalendarDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 29
        components.hour = 12
        let date = Calendar.current.date(from: components)

        XCTAssertEqual(KnowledgeSourceChipFormatter.dateText(date), "2026/08/29")
    }

    func testDateTextIsEmptyForNilDate() {
        XCTAssertEqual(KnowledgeSourceChipFormatter.dateText(nil), "")
    }
}
