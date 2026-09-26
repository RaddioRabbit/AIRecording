import Foundation
import XCTest
@testable import AIRecording

final class SmartChartV5DTOTests: XCTestCase {
    private let mindMapJSON = """
    {
      "root": {"id": "root", "text": "周会纪要"},
      "branches": [
        {"id": "b0", "text": "议题一", "segment_ids": ["s1", "s2"],
         "children": [
           {"id": "b0c0", "text": "结论：当天完成", "segment_ids": ["s1"]},
           {"id": "b0c1", "text": "新要点", "segment_ids": []}
         ]}
      ]
    }
    """

    func testV5ResponseDecodesMindMap() throws {
        let json = """
        {
          "version": "5.0",
          "requestId": "r1",
          "status": "success",
          "contentType": "meeting",
          "contentTypeDisplayName": "会议",
          "chartType": "mind_map",
          "chartTypeDisplayName": "思维导图",
          "title": "周会纪要",
          "htmlFragment": "<div data-segment-ids=\\"s1\\">ok</div>",
          "mindMap": \(mindMapJSON),
          "plan": {},
          "errors": []
        }
        """
        let response = try JSONDecoder().decode(SmartChartGenerateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.version, "5.0")
        XCTAssertEqual(response.chartType, "mind_map")
        let mindMap = try XCTUnwrap(response.mindMap)
        XCTAssertEqual(mindMap.root.text, "周会纪要")
        XCTAssertEqual(mindMap.branches.count, 1)
        XCTAssertEqual(mindMap.branches[0].segmentIds, ["s1", "s2"])
        XCTAssertEqual(mindMap.branches[0].children[1].id, "b0c1")
        XCTAssertEqual(mindMap.branches[0].children[1].segmentIds, [])
    }

    func testV5ResponseDecodesNullMindMapForHighlights() throws {
        let json = """
        {
          "version": "5.0",
          "requestId": "r1",
          "status": "success",
          "contentType": "other",
          "contentTypeDisplayName": "其他",
          "chartType": "highlights",
          "chartTypeDisplayName": "重点句子",
          "title": "重点句子",
          "htmlFragment": "<div data-segment-ids=\\"s1\\">ok</div>",
          "mindMap": null,
          "plan": {},
          "errors": []
        }
        """
        let response = try JSONDecoder().decode(SmartChartGenerateResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.mindMap)
    }

    func testRenderRequestEncodesSnakeCaseSegmentIdsAndV5() throws {
        let doc = MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会纪要"),
            branches: [
                MindMapBranchDTO(id: "b0", text: "议题一", segmentIds: ["s1"], children: [
                    MindMapNodeDTO(id: "b0c0", text: "结论", segmentIds: ["s1"]),
                ]),
            ]
        )
        let request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: doc)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "5.0")
        let mindMap = try XCTUnwrap(json["mindMap"] as? [String: Any])
        let root = try XCTUnwrap(mindMap["root"] as? [String: Any])
        XCTAssertNil(root["segment_ids"], "root 不得携带 segment_ids（后端 extra=forbid）")
        let branches = try XCTUnwrap(mindMap["branches"] as? [[String: Any]])
        XCTAssertEqual(branches[0]["segment_ids"] as? [String], ["s1"])
        let children = try XCTUnwrap(branches[0]["children"] as? [[String: Any]])
        XCTAssertEqual(children[0]["segment_ids"] as? [String], ["s1"])
    }

    func testRenderResponseDecodes() throws {
        let json = """
        {"version": "5.0", "requestId": "r1", "status": "success",
         "htmlFragment": "<svg></svg>", "errorCode": null}
        """
        let response = try JSONDecoder().decode(SmartChartRenderResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, "success")
        XCTAssertEqual(response.htmlFragment, "<svg></svg>")
        XCTAssertNil(response.errorCode)
    }

    func testGenerateRequestDefaultsToV5() {
        let request = SmartChartGenerateRequest(
            recordingId: "rec-1",
            segments: [TranscriptSegmentDTO(id: "s1", speaker: "甲", startTime: 0, endTime: 1, text: "内容")]
        )
        XCTAssertEqual(request.version, "5.0")
    }

    func testV5ResponseDecodesOverview() throws {
        let json = """
        {
          "version": "5.0",
          "requestId": "r1",
          "status": "success",
          "contentType": "meeting",
          "contentTypeDisplayName": "会议",
          "chartType": "mind_map",
          "chartTypeDisplayName": "思维导图",
          "title": "周会纪要",
          "htmlFragment": "<div>ok</div>",
          "mindMap": \(mindMapJSON),
          "overview": "会议确认了私有化部署的排期与分工",
          "plan": {},
          "errors": []
        }
        """
        let response = try JSONDecoder().decode(SmartChartGenerateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.overview, "会议确认了私有化部署的排期与分工")
    }

    func testRenderRequestEncodesOverviewAndDefaultsNil() throws {
        let doc = MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会纪要"),
            branches: []
        )
        let withOverview = SmartChartRenderRequest(
            recordingId: "rec-1", mindMap: doc,
            overview: "会议确认了私有化部署的排期与分工"
        )
        let data = try JSONEncoder().encode(withOverview)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["overview"] as? String, "会议确认了私有化部署的排期与分工")

        let withoutOverview = SmartChartRenderRequest(recordingId: "rec-1", mindMap: doc)
        let nilData = try JSONEncoder().encode(withoutOverview)
        let nilJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: nilData) as? [String: Any])
        XCTAssertNil(nilJSON["overview"], "overview 缺省时不应编码（后端 Optional 默认 None）")
    }
}
