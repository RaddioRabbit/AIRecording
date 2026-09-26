/// 预设的 DashScope 检索模型目录:维度选项只能从这里选,自定义模型不传维度。
enum KnowledgeModelCatalog {
    static let customSentinel = "__custom__"

    static let defaultEmbeddingModel = "text-embedding-v4"
    static let defaultRerankModel = "gte-rerank-v2"

    static let embeddingModelNames = ["text-embedding-v4", "text-embedding-v3"]

    /// 每个预设模型的合法维度,第一个元素是该模型的默认维度。
    /// 取值已于 2026-08-29 按阿里云百炼官方文档核对(1536/2048 仅 v4 支持)。
    static let embeddingDimensionsByModel: [String: [Int]] = [
        "text-embedding-v4": [1024, 1536, 2048, 768, 512, 256, 128, 64],
        "text-embedding-v3": [1024, 768, 512, 256, 128, 64],
    ]

    static let rerankModelNames = ["gte-rerank-v2", "qwen3-rerank"]

    static func dimensions(for model: String) -> [Int]? {
        embeddingDimensionsByModel[model]
    }
}
