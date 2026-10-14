import Foundation

/// Treaty 0x1C / 0x1D recording bitrate. New captures use 24 kbps.
/// 16 and 20 kbps stay so older flash recordings still decode.

enum RecordingBitrate: Int, CaseIterable, Identifiable, Equatable {
    case kbps16 = 16
    case kbps20 = 20
    case kbps24 = 24

    var id: Int { rawValue }

    /// Payload byte for CMD 0x1D (set) / response of 0x1C (get).
    var firmwareCode: UInt8 {
        switch self {
        case .kbps16: return 0x00
        case .kbps20: return 0x01
        case .kbps24: return 0x02
        }
    }

    var bitsPerSecond: Int { rawValue * 1_000 }

    /// CBR bytes per 10 ms frame: 16→20, 20→25, 24→30.
    var cbrFrameByteCount: Int {
        bitsPerSecond / 8 * OpusFormat.frameDurationMs / 1_000
    }

    var label: String { "\(rawValue) kbps" }

    var shortTag: String { "\(rawValue)" }

    static func from(firmwareCode: UInt8) -> RecordingBitrate? {
        allCases.first { $0.firmwareCode == firmwareCode }
    }

    static func from(frameByteCount: Int) -> RecordingBitrate? {
        allCases.first { $0.cbrFrameByteCount == frameByteCount }
    }
}
