import Foundation

// MARK: - SmartChart Content Type

enum ContentType: String, CaseIterable, Codable {
    case meeting, interview, lecture, dialogue, speech, memo, other

    var displayName: String {
        switch self {
        case .meeting: return "会议"
        case .interview: return "访谈"
        case .lecture: return "讲座"
        case .dialogue: return "对话"
        case .speech: return "演讲"
        case .memo: return "随手记"
        case .other: return "其他"
        }
    }
}

enum ChartStatus: Int16, Codable {
    case pending = 0
    case analyzing = 1
    case generating = 2
    case rendering = 3
    case completed = 4
    case failed = 5
    case cancelled = 6
}

enum ChartSkillError: Error, Equatable {
    case serviceUnavailable
    case serviceNotRunning
    case invalidRequest
    case invalidResponse
    case generationFailed(String)
    case validationFailed(String)
    case networkError(underlying: Error)
    case timeout
    case contentTooShort
    case decodingFailed

    var localizedDescription: String {
        switch self {
        case .serviceUnavailable: return "图表服务不可用"
        case .serviceNotRunning: return "图表引擎未启动"
        case .invalidRequest: return "请求参数无效"
        case .invalidResponse: return "响应格式无效"
        case .generationFailed(let msg): return "生成失败: \(msg)"
        case .validationFailed(let msg): return "校验失败: \(msg)"
        case .networkError(let err): return "网络错误: \(err.localizedDescription)"
        case .timeout: return "图表生成超时"
        case .contentTooShort: return "内容过短，无法生成有意义的图表"
        case .decodingFailed: return "数据解析失败"
        }
    }

    static func == (lhs: ChartSkillError, rhs: ChartSkillError) -> Bool {
        switch (lhs, rhs) {
        case (.serviceUnavailable, .serviceUnavailable): return true
        case (.serviceNotRunning, .serviceNotRunning): return true
        case (.invalidRequest, .invalidRequest): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.generationFailed(let a), .generationFailed(let b)): return a == b
        case (.validationFailed(let a), .validationFailed(let b)): return a == b
        case (.networkError, .networkError): return true
        case (.timeout, .timeout): return true
        case (.contentTooShort, .contentTooShort): return true
        case (.decodingFailed, .decodingFailed): return true
        default: return false
        }
    }
}

// MARK: - SmartChart Request / Response Models

/// A single transcription segment with source information.
struct TranscriptSegmentDTO: Codable, Identifiable {
    let id: String
    let speaker: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

// MARK: - Mind Map DTOs (v5)

/// 思维导图中心主题节点。无 segmentIds（后端 root 模型 extra="forbid"）。
struct MindMapRootDTO: Codable, Equatable {
    var id: String
    var text: String
}

/// 思维导图要点节点（二级）。
struct MindMapNodeDTO: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var segmentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, text
        case segmentIds = "segment_ids"
    }
}

/// 思维导图一级分支。
struct MindMapBranchDTO: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var segmentIds: [String]
    var children: [MindMapNodeDTO]

    enum CodingKeys: String, CodingKey {
        case id, text, children
        case segmentIds = "segment_ids"
    }
}

/// 思维导图结构数据：root（中心主题）+ branches（一级分支，各带要点）。
struct MindMapDocDTO: Codable, Equatable {
    var root: MindMapRootDTO
    var branches: [MindMapBranchDTO]
}

/// SmartChart generation request. Sends raw transcript segments so the agent can
/// route by content structure; `forceContentType` overrides content-type detection
/// when set.
struct SmartChartGenerateRequest: Codable {
    var version: String
    var requestId: String
    var recordingId: String
    var segments: [TranscriptSegmentDTO]
    var summaryMarkdown: String?
    var forceContentType: ContentType?

    init(
        version: String = "5.0",
        requestId: String = UUID().uuidString,
        recordingId: String,
        segments: [TranscriptSegmentDTO],
        summaryMarkdown: String? = nil,
        forceContentType: ContentType? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.recordingId = recordingId
        self.segments = segments
        self.summaryMarkdown = summaryMarkdown
        self.forceContentType = forceContentType
    }
}

/// SmartChart generation response. Contains exactly one rendered chart.
struct SmartChartGenerateResponse: Codable {
    var version: String
    var requestId: String
    var status: String
    var contentType: ContentType
    var contentTypeDisplayName: String
    var chartType: String
    var chartTypeDisplayName: String
    var title: String
    var htmlFragment: String
    /// 思维导图结构数据；chartType == "mind_map" 时必带，highlights 兜底时为 nil。
    var mindMap: MindMapDocDTO?
    /// 总览条文案；重渲染 /chart/render 时回传，避免编辑后总览条丢失。
    var overview: String?
    var errors: [String]
    /// Structured error code returned by newer backends (e.g. "TIMEOUT").
    /// Optional so responses from older backends without this field still decode.
    var errorCode: String?
}

/// POST /chart/render 请求：编辑后的思维导图确定性重渲染（无 LLM）。
struct SmartChartRenderRequest: Codable {
    var version: String = "5.0"
    var requestId: String = UUID().uuidString
    var recordingId: String
    var mindMap: MindMapDocDTO
    var theme: String = "darkCyberpunk"
    /// 总览条文案回传；缺省为 nil，不编码（后端 Optional 默认 None）。
    var overview: String?
}

/// POST /chart/render 响应。
struct SmartChartRenderResponse: Codable {
    var version: String
    var requestId: String
    var status: String
    var htmlFragment: String
    var errorCode: String?
}

enum ChartSourceResolver {
    static func earliestSegmentID(
        in segmentIDs: [String],
        startTimes: [String: TimeInterval]
    ) -> String? {
        segmentIDs
            .compactMap { id in startTimes[id].map { (id: id, startTime: $0) } }
            .min { left, right in
                if left.startTime == right.startTime {
                    return left.id < right.id
                }
                return left.startTime < right.startTime
            }?
            .id
    }
}

// MARK: - Legacy Chart DTOs (kept for Core Data compatibility)

struct ChartResult: Codable {
    let chartType: String
    let chartTypeDisplayName: String
    let confidence: Double
    let contentType: String?
    let contentTypeConfidence: Double?
    let htmlFragment: String
    let renderConfig: RenderConfig
    let structuredData: ChartStructuredData
    let metadata: ChartMetadata

    struct RenderConfig: Codable {
        let styleTokens: [String: String]
        let cssFramework: String
    }

    struct ChartStructuredData: Codable {
        let nodes: [ChartNodeDTO]
        let edges: [ChartEdgeDTO]

        struct ChartNodeDTO: Codable {
            let id: String
            let label: String
            let level: Int
            let nodeType: String
            let color: String?
            let metadata: [String: String]?

            enum CodingKeys: String, CodingKey {
                case id, label, level, color, metadata
                case nodeType = "node_type"
            }
        }

        struct ChartEdgeDTO: Codable {
            let from: String
            let to: String
            let label: String?
        }
    }

    struct ChartMetadata: Codable {
        let nodeCount: Int
        let maxDepth: Int
        let generationTimeMs: Int
    }
}

struct ChartStyleConfig: Codable {
    let theme: String
    let bg: String
    let card: String
    let border: String
    let text: String
    let textSecondary: String
    let cyan: String
    let purple: String
    let orange: String
    let green: String
    let red: String
    let blue: String
    let cardRadius: String
    let cardShadow: String
    let glassBlur: String
    let gradientText: String
    let terminalBg: String
}

// MARK: - Protocol

protocol ChartSkill {
    var skillId: String { get }
    var skillVersion: String { get }
    var displayName: String { get }

    func checkAvailability() async -> Bool
    func generate(request: SmartChartGenerateRequest) async throws -> SmartChartGenerateResponse
}

// MARK: - Chart Request Gate

/// Guards against stale async chart responses overwriting newer requests.
/// Each `begin()` issues a fresh token and invalidates all previously issued ones;
/// `invalidate()` invalidates everything issued so far.
final class ChartRequestGate: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let rawValue: UInt64
    }

    private var counter: UInt64 = 0
    private let lock = NSLock()

    func begin() -> Token {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return Token(rawValue: counter)
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.rawValue == counter
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
    }
}

// MARK: - Mind Map Rendering (v5)

/// /chart/render 纯渲染客户端抽象，便于 ViewModel 在测试中注入桩实现。
protocol MindMapRendering {
    func render(request: SmartChartRenderRequest) async throws -> SmartChartRenderResponse
}
