import Foundation

/// Rotates the known log files (`app.log`, `chart-agent.log`) keeping at most
/// the current file plus two numbered copies. Only ever touches the explicit
/// file names below — it never scans the log directory or deletes anything else.
enum LogRotator {
    static let maxFileSize = 5 * 1024 * 1024
    static let keepFiles = 3

    /// The only file names the rotator is allowed to operate on (design §8.3).
    private static let allowedFileNames: Set<String> = ["app.log", "chart-agent.log"]

    static func rotatedURL(for url: URL, index: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let name = pathExtension.isEmpty ? "\(stem).\(index)" : "\(stem).\(index).\(pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Unconditional rotation: drops the oldest copy, shifts the rest up, and
    /// moves the current file to `.1`. Callers handle reopening a fresh file.
    static func rotate(at url: URL, keep: Int = keepFiles) {
        let fileManager = FileManager.default
        guard keep > 1,
              allowedFileNames.contains(url.lastPathComponent),
              fileManager.fileExists(atPath: url.path) else { return }

        try? fileManager.removeItem(at: rotatedURL(for: url, index: keep - 1))
        if keep > 2 {
            for index in stride(from: keep - 1, through: 2, by: -1) {
                try? fileManager.moveItem(at: rotatedURL(for: url, index: index - 1), to: rotatedURL(for: url, index: index))
            }
        }
        try? fileManager.moveItem(at: url, to: rotatedURL(for: url, index: 1))
    }

    /// Rotates only when the file exists and exceeds `maxBytes`.
    static func rotateIfNeeded(at url: URL, maxBytes: Int = maxFileSize, keep: Int = keepFiles) {
        let fileManager = FileManager.default
        guard allowedFileNames.contains(url.lastPathComponent),
              fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > maxBytes else { return }
        rotate(at: url, keep: keep)
    }
}
