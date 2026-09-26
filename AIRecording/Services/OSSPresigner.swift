import Foundation
import CommonCrypto

struct OSSConfig {
    let accessKeyId: String
    let accessKeySecret: String
    let bucket: String
    let endpoint: String

    var isValid: Bool {
        !accessKeyId.isEmpty && !accessKeySecret.isEmpty && !bucket.isEmpty && !endpoint.isEmpty
    }
}

struct OSSPresigner {
    let config: OSSConfig

    /// Generates a presigned URL for the given OSS object.
    /// - Parameters:
    ///   - objectKey: The OSS object key (e.g. "recordings/audio.wav")
    ///   - method: HTTP method ("GET", "PUT", "DELETE")
    ///   - contentType: Content-Type header value for the request (e.g. "audio/wav")
    ///   - expiration: URL expiration time in seconds (default: 3600)
    func presignedURL(objectKey: String, method: String, contentType: String = "", expiration: TimeInterval = 3600) -> URL? {
        let expires = String(Int(Date().timeIntervalSince1970 + expiration))

        // OSS V1 signature: StringToSign = VERB + "\n" + CONTENT_MD5 + "\n" + CONTENT_TYPE + "\n" + EXPIRES + "\n" + CanonicalizedResource
        let canonicalizedResource = "/\(config.bucket)/\(objectKey)"
        let stringToSign = "\(method.uppercased())\n\n\(contentType)\n\(expires)\n\(canonicalizedResource)"

        guard let signature = hmacSHA1(message: stringToSign, key: config.accessKeySecret) else {
            return nil
        }

        // OSS expects + / = in base64 signature to be percent-encoded
        let encodedSignature = signature
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")

        let urlString = "https://\(config.bucket).\(config.endpoint)/\(objectKey)?OSSAccessKeyId=\(config.accessKeyId)&Expires=\(expires)&Signature=\(encodedSignature)"

        // Log signature diagnostics (stringToSign contains no secrets)
        AppLogger.log(.debug, category: "transcription", event: "oss_presigned_url_generated",
                      message: "StringToSign: \(stringToSign.replacingOccurrences(of: "\n", with: "\\n"))",
                      metadata: ["method": method, "expiresIn": Int(expiration),
                                 "keyIdLength": config.accessKeyId.count,
                                 "keySecretLength": config.accessKeySecret.count,
                                 "signatureHadPlus": signature.contains("+"),
                                 "signatureHadSlash": signature.contains("/"),
                                 "signatureHadEqual": signature.contains("="),
                                 "urlLength": urlString.count])

        return URL(string: urlString)
    }

    private func hmacSHA1(message: String, key: String) -> String? {
        guard let keyData = key.data(using: .utf8),
              let messageData = message.data(using: .utf8) else {
            return nil
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            messageData.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress,
                    keyBytes.count,
                    messageBytes.baseAddress,
                    messageBytes.count,
                    &digest
                )
            }
        }

        return Data(digest).base64EncodedString()
    }
}
