import Foundation

protocol KnowledgeClientProtocol: Sendable {
    func health() async throws -> KnowledgeHealthDTO
    func status() async throws -> KnowledgeStatusDTO
    func upsert(_ request: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse
    func delete(recordingId: UUID) async throws
    func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error>
    func retryFailed() async throws
    func resetIndex() async throws
}

enum KnowledgeClientError: Error, Equatable {
    case invalidResponse
    case encodingFailed
    case decodingFailed
    case serviceUnavailable
    case requestRejected
    case network
    case cancelled
}

final class KnowledgeClient: KnowledgeClientProtocol, @unchecked Sendable {
    static let shared = KnowledgeClient()

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(baseURL: URL = URL(string: "http://127.0.0.1:8766")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func health() async throws -> KnowledgeHealthDTO {
        try await send(path: "health", method: "GET")
    }

    func status() async throws -> KnowledgeStatusDTO {
        try await send(path: "knowledge/status", method: "GET")
    }

    func upsert(_ request: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse {
        let body: Data
        do { body = try encoder.encode(request) }
        catch { throw KnowledgeClientError.encodingFailed }
        return try await send(path: "knowledge/recordings/\(request.recordingId.uuidString)", method: "PUT", body: body)
    }

    func delete(recordingId: UUID) async throws {
        let _: EmptyResponse = try await send(path: "knowledge/recordings/\(recordingId.uuidString)", method: "DELETE")
    }

    func retryFailed() async throws {
        let _: EmptyResponse = try await send(path: "knowledge/retry-failed", method: "POST")
    }

    func resetIndex() async throws {
        let _: EmptyResponse = try await send(path: "knowledge/reset-index", method: "POST")
    }

    func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error> {
        let cancellation = KnowledgeStreamCancellation()
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: KnowledgeClientError.cancelled)
                    return
                }
                do {
                    let body: Data
                    do { body = try self.encoder.encode(request) }
                    catch { throw KnowledgeClientError.encodingFailed }
                    var urlRequest = self.makeRequest(path: "knowledge/query", method: "POST", body: body)
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    try Task.checkCancellation()
                    try self.validate(response)
                    var frame = KnowledgeSSEFrame()
                    var lineBytes = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard byte == UInt8(ascii: "\n") else {
                            lineBytes.append(byte)
                            continue
                        }
                        if lineBytes.last == UInt8(ascii: "\r") { lineBytes.removeLast() }
                        let normalizedLine = String(decoding: lineBytes, as: UTF8.self)
                            .trimmingCharacters(in: .whitespaces)
                        lineBytes.removeAll(keepingCapacity: true)
                        if normalizedLine.isEmpty {
                            if let event = try frame.decodedEvent(using: self.decoder, expectedRequestID: request.requestId) {
                                continuation.yield(event)
                            }
                            frame = KnowledgeSSEFrame()
                        } else {
                            frame.append(line: normalizedLine)
                        }
                    }
                    if let event = try frame.decodedEvent(using: self.decoder, expectedRequestID: request.requestId) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: KnowledgeClientError.cancelled)
                } catch let error as KnowledgeClientError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: KnowledgeClientError.cancelled)
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            cancellation.set(task)
            continuation.onTermination = { @Sendable _ in cancellation.cancel() }
        }
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> Response {
        let request = makeRequest(path: path, method: method, body: body)
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response)
            guard !data.isEmpty else {
                if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
                throw KnowledgeClientError.decodingFailed
            }
            do { return try decoder.decode(Response.self, from: data) }
            catch { throw KnowledgeClientError.decodingFailed }
        } catch let error as KnowledgeClientError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private func makeRequest(path: String, method: String, body: Data? = nil) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw KnowledgeClientError.invalidResponse }
        switch response.statusCode {
        case 200...299: return
        case 502, 503, 504: throw KnowledgeClientError.serviceUnavailable
        case 400...499: throw KnowledgeClientError.requestRejected
        default: throw KnowledgeClientError.invalidResponse
        }
    }

    private static func map(_ error: Error) -> KnowledgeClientError {
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .network
        }
        return .network
    }
}

private struct EmptyResponse: Decodable { }

private final class KnowledgeStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private struct KnowledgeSSEFrame {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func append(line: String) {
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
        }
    }

    func decodedEvent(using decoder: JSONDecoder, expectedRequestID: UUID) throws -> KnowledgeStreamEvent? {
        guard !dataLines.isEmpty else { return nil }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        if let envelope = try? decoder.decode(KnowledgeStreamEvent.self, from: data) {
            guard UUID(uuidString: envelope.requestId) == expectedRequestID,
                  eventName == nil || eventName == envelope.event.rawValue else {
                throw KnowledgeClientError.decodingFailed
            }
            return envelope
        }
        guard let eventName,
              let event = KnowledgeStreamEvent.Event(rawValue: eventName) else {
            throw KnowledgeClientError.decodingFailed
        }
        struct Payload: Decodable {
            let requestId: String
            let data: [String: KnowledgeJSONValue]
        }
        do {
            let payload = try decoder.decode(Payload.self, from: data)
            guard UUID(uuidString: payload.requestId) == expectedRequestID else {
                throw KnowledgeClientError.decodingFailed
            }
            return KnowledgeStreamEvent(event: event, requestId: payload.requestId, data: payload.data)
        } catch {
            throw KnowledgeClientError.decodingFailed
        }
    }
}
