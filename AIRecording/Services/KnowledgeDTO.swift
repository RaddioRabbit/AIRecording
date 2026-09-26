import CoreData
import CryptoKit
import Foundation

private enum KnowledgeDTOHash {
    static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct KnowledgeSegmentDTO: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let sequence: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerId: String?
    let speakerName: String?
    let text: String
}

struct KnowledgeRecordingRequest: Codable, Sendable, Equatable {
    let recordingId: UUID
    let title: String
    let recordedAt: Date
    let contentHash: String
    let summaryHash: String
    let indexVersion: Int
    let summaryMarkdown: String?
    let segments: [KnowledgeSegmentDTO]

    static func make(recording: Recording) -> Self? {
        guard let recordingID = recording.id else { return nil }
        let segments = ((recording.transcription?.segments as? Set<TranscriptionSegment>) ?? [])
            .sorted { $0.sequence < $1.sequence }
            .compactMap { segment -> KnowledgeSegmentDTO? in
                let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = segment.id, !text.isEmpty else { return nil }
                return KnowledgeSegmentDTO(
                    id: id,
                    sequence: Int(segment.sequence),
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    speakerId: segment.speakerId,
                    speakerName: segment.speakerDisplayName.nilIfEmpty,
                    text: text
                )
            }
        guard !segments.isEmpty else { return nil }
        let summary = normalizedSummary(recording.transcription?.summary)
        let canonicalTranscript = segments.map {
            "\($0.id.uuidString)|\($0.sequence)|\($0.startTime)|\($0.endTime)|\($0.speakerId ?? "")|\($0.text)"
        }.joined(separator: "\n")
        return Self(
            recordingId: recordingID,
            title: recording.displayTitle,
            recordedAt: recording.createdAt ?? Date(timeIntervalSince1970: 0),
            contentHash: KnowledgeDTOHash.hex(canonicalTranscript),
            summaryHash: KnowledgeDTOHash.hex(summary ?? ""),
            indexVersion: 1,
            summaryMarkdown: summary,
            segments: segments
        )
    }

    private static func normalizedSummary(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            return trimmed
        }
        let content = lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.nilIfEmpty
    }
}

struct KnowledgeStatusDTO: Codable, Sendable, Equatable {
    let documents: Int
    let chunks: Int
    let pendingJobs: Int
    let failedJobs: Int
    let degraded: Bool
}

struct KnowledgeSourceDTO: Codable, Sendable, Equatable, Identifiable {
    let sourceId: String
    let recordingId: UUID
    let segmentIds: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerName: String?

    var id: String { sourceId }
}

struct KnowledgeHistoryMessageDTO: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable, Equatable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct KnowledgeQueryRequest: Codable, Sendable, Equatable {
    let requestId: UUID
    let sessionId: UUID
    let query: String
    let history: [KnowledgeHistoryMessageDTO]

    init(requestId: UUID, sessionId: UUID, query: String, history: [KnowledgeHistoryMessageDTO]) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.history = Array(history.suffix(6))
    }
}

enum KnowledgeJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: KnowledgeJSONValue])
    case array([KnowledgeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: KnowledgeJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([KnowledgeJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct KnowledgeStreamEvent: Codable, Sendable, Equatable {
    enum Event: String, Codable, Sendable, Equatable {
        case retrievalStarted = "retrieval_started"
        case sources
        case answerDelta = "answer_delta"
        case answerCompleted = "answer_completed"
        case error
    }

    let event: Event
    let requestId: String
    let data: [String: KnowledgeJSONValue]

    func stringValue(for key: String) -> String? {
        guard case let .string(value)? = data[key] else { return nil }
        return value
    }
}

struct KnowledgeHealthDTO: Codable, Sendable, Equatable {
    let status: String
    let apiVersion: String
    let serviceVersion: String
    let indexVersion: Int
}

struct KnowledgeUpsertResponse: Codable, Sendable, Equatable {
    let status: String
    let generationChunks: Int
    let retrievalChunks: Int
    let summaryChunks: Int
    let embeddedChunks: Int
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
