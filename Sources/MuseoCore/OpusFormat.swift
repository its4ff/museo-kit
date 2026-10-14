import Foundation

/// Firmware Opus config: 16 kHz mono, CBR 16/20/24 kbps, 10 ms frames.

enum OpusFormat {
    static let sampleRate = 16_000
    static let frameDurationMs = 10
    /// PCM samples per Opus packet at 16 kHz (10 ms).
    static let samplesPerFrame = sampleRate * frameDurationMs / 1_000

    /// Every capture encodes at 24 kbps. Older recordings can still be decoded —
    /// see `cbrFrameByteCandidates`.
    static let activeBitrate: RecordingBitrate = .kbps24

    static var bitrate: Int { activeBitrate.bitsPerSecond }
    /// CBR bytes per 10 ms frame at 24 kbps (30).
    static var cbrFrameByteCount: Int { activeBitrate.cbrFrameByteCount }

    /// All 10 ms CBR sizes the ring has ever produced — 24 kbps first, then legacy.
    static var cbrFrameByteCandidates: [Int] {
        let preferred = cbrFrameByteCount
        return [preferred] + RecordingBitrate.allCases.map(\.cbrFrameByteCount).filter { $0 != preferred }
    }

    /// Observed TOC byte on 54L15 streaming CBR frames (config 22, 10 ms).
    static let streamingFrameMarker: UInt8 = 0xB0
    /// Previous firmware used 5 ms frames (~10 bytes).
    static let legacyFrameByteCount = 10
    static let legacyFrameDurationMs = 5
    static let legacySamplesPerFrame = sampleRate * legacyFrameDurationMs / 1_000

    static let fixedFrameByteCandidates = RecordingBitrate.allCases.map(\.cbrFrameByteCount) + [legacyFrameByteCount]

    static func durationSeconds(packetCount: Int, samplesPerFrame: Int = samplesPerFrame) -> Double {
        Double(packetCount * samplesPerFrame) / Double(sampleRate)
    }
}
