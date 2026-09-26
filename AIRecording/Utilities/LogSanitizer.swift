import Foundation

/// Central privacy gate for all log output. Every record passes through here
/// before it can reach disk: callers cannot bypass it to write files directly.
enum LogSanitizer {
    static let messageMaxLength = 200

    private static let credentialPatterns: [NSRegularExpression] = [
        // Bearer tokens
        try! NSRegularExpression(pattern: #"(?i)bearer\s+[^\s,;]+"#),
        // API keys of the common "sk-..." shape
        try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]+\b"#),
        // api_key=... / api-key: ...
        try! NSRegularExpression(pattern: #"(?i)(api[_-]?key[=:]\s*)[^\s,;]+"#),
        // Provider-specific key names (for example DASHSCOPE_API_KEY=...).
        try! NSRegularExpression(pattern: #"(?i)((?:dashscope|openai)[_-]?api[_-]?key[=:]\s*)[^\s,;]+"#),
        // Presigned URL signature parameters
        try! NSRegularExpression(pattern: #"(?i)(X-Amz-Signature|OSSAccessKeyId|Signature|Security-Token|Expires)=[^\s&]+"#),
        // Authorization header values
        try! NSRegularExpression(pattern: #"(?i)(authorization[=:]\s*)[^\s,;]+"#),
        // User-content fields emitted by a subprocess or an error wrapper.
        // A log line has no legitimate reason to retain their values.
        try! NSRegularExpression(pattern: #"(?i)\b(?:query|question|answer|title|speaker(?:name)?|segment(?:text)?|transcript|summary|prompt|content)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\r\n]+)"#),
    ]

    private static let sensitiveMetadataKeys: Set<String> = [
        "apikey", "authorization", "token", "secret", "password", "query", "question", "answer",
        "title", "speaker", "speakername", "segment", "segmenttext", "transcript", "summary",
        "prompt", "content"
    ]

    /// Redacts common credential patterns and truncates to `messageMaxLength`.
    static func sanitizeMessage(_ message: String) -> String {
        var result = message
        for pattern in credentialPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        if result.count > messageMaxLength {
            result = String(result.prefix(messageMaxLength))
        }
        return result
    }

    /// Metadata whitelist: only non-sensitive scalar values are kept.
    static func sanitizeMetadata(_ metadata: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in metadata {
            let normalizedKey = key.lowercased().replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            guard !sensitiveMetadataKeys.contains(normalizedKey) else { continue }
            switch value {
            case let value as String:
                result[key] = value
            case let value as Bool:
                result[key] = value
            case let value as Int:
                result[key] = value
            case let value as Double:
                result[key] = value
            case let value as NSNumber:
                result[key] = value
            default:
                continue
            }
        }
        return result
    }

    /// Secondary sanitization for records that arrive already structured
    /// (e.g. Python chart-agent output) before they are written to disk.
    static func sanitizeRecord(_ record: [String: Any]) -> [String: Any] {
        var result = record
        if let message = record["message"] as? String {
            result["message"] = sanitizeMessage(message)
        }
        if let metadata = record["metadata"] as? [String: Any] {
            result["metadata"] = sanitizeMetadata(metadata)
        }
        return result
    }
}
