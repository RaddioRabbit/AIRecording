import XCTest
@testable import AIRecording

final class KnowledgeModelCatalogTests: XCTestCase {
    func testEmbeddingPresetsExposeDimensionOptionsWithDefaultFirst() {
        XCTAssertEqual(
            KnowledgeModelCatalog.embeddingModelNames.first,
            KnowledgeModelCatalog.defaultEmbeddingModel
        )
        XCTAssertEqual(
            KnowledgeModelCatalog.dimensions(for: "text-embedding-v4")?.first,
            1024
        )
        XCTAssertEqual(
            KnowledgeModelCatalog.dimensions(for: "text-embedding-v3")?.first,
            1024
        )
    }

    func testUnknownModelHasNoPresetDimensions() {
        XCTAssertNil(KnowledgeModelCatalog.dimensions(for: "my-own-model"))
        XCTAssertNil(KnowledgeModelCatalog.dimensions(for: KnowledgeModelCatalog.customSentinel))
    }

    func testRerankPresetsContainDefaultFirst() {
        XCTAssertEqual(
            KnowledgeModelCatalog.rerankModelNames.first,
            KnowledgeModelCatalog.defaultRerankModel
        )
    }

    func testPresetTablesMatchVerifiedOfficialValues() {
        XCTAssertEqual(
            KnowledgeModelCatalog.embeddingDimensionsByModel["text-embedding-v4"],
            [1024, 1536, 2048, 768, 512, 256, 128, 64]
        )
        XCTAssertEqual(
            KnowledgeModelCatalog.embeddingDimensionsByModel["text-embedding-v3"],
            [1024, 768, 512, 256, 128, 64]
        )
        XCTAssertEqual(KnowledgeModelCatalog.embeddingModelNames, ["text-embedding-v4", "text-embedding-v3"])
        XCTAssertEqual(KnowledgeModelCatalog.rerankModelNames, ["gte-rerank-v2", "qwen3-rerank"])
    }
}
