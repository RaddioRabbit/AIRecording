import Foundation

/// The single file writer for one log target. All writes run on an internal
/// serial queue so line order and the file handle stay consistent; callers
/// submit records and never wait for disk I/O or receive write errors.
final class FileLogWriter: @unchecked Sendable {

    /// Invoked (once per failure kind, on the caller's queue) when directory
    /// creation, file opening, encoding or writing fails. Lets AppLogger fall
    /// back to Unified Logging without recursion into itself.
    var onFailure: (String) -> Void = { _ in }

    private let directory: URL
    private let fileURL: URL
    private let maxFileSize: Int
    private let keepFiles: Int
    private let queue: DispatchQueue
    private var handle: FileHandle?
    private var currentSize: Int = 0
    private var isUsable = true
    private var reportedFailures = Set<String>()

    init(directory: URL, fileName: String, maxFileSize: Int = LogRotator.maxFileSize, keepFiles: Int = LogRotator.keepFiles) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.maxFileSize = maxFileSize
        self.keepFiles = keepFiles
        self.queue = DispatchQueue(label: "com.airecording.filelogwriter.\(fileName)")
        queue.sync {
            prepareFile()
        }
    }

    deinit {
        queue.sync {
            try? handle?.close()
        }
    }

    /// Appends one pre-encoded JSON line (newline added here). Fire-and-forget:
    /// a single write failure is reported to `onFailure`, never to the caller.
    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        queue.async { [self] in
            append(data)
        }
    }

    /// Blocks until all previously submitted writes have completed. Test hook.
    func synchronize() {
        queue.sync {}
    }

    // MARK: - Private (serial queue only)

    private func reportFailure(_ kind: String) {
        guard reportedFailures.insert(kind).inserted else { return }
        onFailure(kind)
    }

    private func prepareFile() {
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            // Tighten permissions whenever they are wider than required.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            // Startup size check: rotate files that grew past the limit before
            // this run (e.g. written by an older build without rotation).
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > maxFileSize {
                LogRotator.rotate(at: fileURL, keep: keepFiles)
            }

            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            let handle = try FileHandle(forWritingTo: fileURL)
            currentSize = Int(handle.seekToEndOfFile())
            self.handle = handle
        } catch {
            isUsable = false
            reportFailure("prepare")
        }
    }

    private func append(_ data: Data) {
        guard isUsable, let handle else { return }

        // Rotate before appending when this record would exceed the cap.
        if currentSize + data.count > maxFileSize {
            rotateAndReopen()
            guard isUsable, let reopenedHandle = self.handle else { return }
            writeData(reopenedHandle, data)
            return
        }
        writeData(handle, data)
    }

    private func writeData(_ handle: FileHandle, _ data: Data) {
        do {
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            reportFailure("write")
        }
    }

    /// Rotation failure keeps the current file and continues appending to it.
    private func rotateAndReopen() {
        do {
            try handle?.close()
        } catch {
            reportFailure("close")
        }
        handle = nil

        LogRotator.rotate(at: fileURL, keep: keepFiles)

        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let newHandle = try FileHandle(forWritingTo: fileURL)
            currentSize = Int(newHandle.seekToEndOfFile())
            handle = newHandle
        } catch {
            isUsable = false
            reportFailure("rotate")
        }
    }
}
