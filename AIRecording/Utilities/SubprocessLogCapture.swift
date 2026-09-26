import Foundation

/// Continuously drains one subprocess pipe, splits the byte stream into lines,
/// and forwards each line to a handler. Reading is decoupled from log writing:
/// even when file logging fails, the pipe keeps being drained so the child
/// process can never block on a full pipe buffer.
final class SubprocessLogCapture: @unchecked Sendable {
    private let pipe = Pipe()
    private let queue: DispatchQueue
    private var buffer = Data()
    private let onLine: (String) -> Void

    /// Assigned to `Process.standardOutput` / `standardError` before launch.
    var fileHandleForWriting: FileHandle { pipe.fileHandleForWriting }

    init(name: String, onLine: @escaping (String) -> Void) {
        self.queue = DispatchQueue(label: "com.airecording.capture.\(name)")
        self.onLine = onLine
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.queue.async { self.append(data) }
        }
    }

    /// Called when the process terminates: stops chunk callbacks, reads the
    /// remaining bytes to EOF, and emits the final partial line if any.
    func finish() {
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        queue.sync {
            append(rest)
            if !buffer.isEmpty {
                emit(buffer)
                buffer = Data()
            }
        }
        try? pipe.fileHandleForReading.close()
    }

    // MARK: - Private (serial queue only)

    private func append(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(buffer.prefix(upTo: newlineIndex))
            buffer = Data(buffer.suffix(from: newlineIndex + 1))
            emit(lineData)
        }
    }

    private func emit(_ data: Data) {
        onLine(String(decoding: data, as: UTF8.self))
    }
}
