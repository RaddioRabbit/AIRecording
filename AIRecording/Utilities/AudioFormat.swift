import Foundation
import AVFoundation

struct AudioFormatConstants {
    static let defaultSampleRate: Double = 44100
    static let defaultChannels: Int = 1
    static let defaultBitDepth: Int = 16

    static func settings(sampleRate: Double, channels: Int, bitDepth: Int) -> [String: Any] {
        return [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
