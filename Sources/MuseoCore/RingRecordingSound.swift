import Foundation

/// The ring's stored noise reduction and AGC values, raw, as it reports them (`0x1E`). For
/// tools like a console. In testing (2026-10-14) neither changed a recording, so the kit
/// keeps noise reduction at 0 and apps don't set either. The bitrate isn't here: it's always
/// 24 kbps.
public struct RingRecordingSound: Equatable, Sendable {
    /// The firmware's noise reduction level, 0 to 2.
    public let noiseReduction: UInt8
    /// The firmware's AGC byte. Its unit and default aren't documented.
    public let gain: UInt8

    public init(noiseReduction: UInt8, gain: UInt8) {
        self.noiseReduction = noiseReduction
        self.gain = gain
    }
}
