import AVFoundation
import Foundation

/// The ring's audio while it streams (a hold), as it arrives. For words while you speak:
/// hand it to a recognizer. The finished recording still reaches `Museo.onCapture`, as before.
///
/// ```swift
/// for await piece in Museo.liveAudio() {
///     switch piece {
///     case .began(let at): startRecognizer()
///     case .samples(let chunk): if let buffer = chunk.buffer() { feed(buffer) }
///     case .ended: finishRecognizer()
///     }
/// }
/// ```
nonisolated public enum LiveAudio: Sendable {
    /// A hold began, at this time.
    case began(Date)
    /// About 100 ms more of it.
    case samples(LiveAudioChunk)
    /// The hold ended. Its recording is on its way to `Museo.onCapture`.
    case ended
}

/// A stretch of a hold's audio: 16 kHz, mono, 16-bit.
nonisolated public struct LiveAudioChunk: Sendable {
    public static let sampleRate: Double = 16_000

    public let samples: [Int16]

    /// The format `buffer()` fills: 16 kHz mono 16-bit, interleaved.
    public static func format() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    }

    /// The samples as a buffer in `format()`, for a recognizer or an `AVAudioConverter`.
    public func buffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format = Self.format(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData else {
            return nil
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel[0].update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// Owns the manager's audio tap while anyone listens, and turns each hold into `LiveAudio`.
///
/// The tap is only on while a `Museo.liveAudio()` stream is open, so nobody pays for decoding
/// they don't use. Decoding runs on its own queue, never the main thread. A hold begins with
/// its first notification (the manager says so) and ends with `RingEvent.liveEnded`.
nonisolated final class LiveAudioTap: @unchecked Sendable {
    static let shared = LiveAudioTap()

    private static let tapID = "museo.kit.live-audio"
    /// 100 ms at 16 kHz: small enough for words to keep up, large enough not to chatter.
    private static let chunkSamples = 1_600

    /// Owns everything below. Never the main queue.
    private let queue = DispatchQueue(label: "museo.kit.live-audio", qos: .userInitiated)
    private var continuations: [UUID: AsyncStream<LiveAudio>.Continuation] = [:]
    private var decoder: LiveOpusStream?
    private var held: [Int16] = []

    /// Main actor only: the manager reads its taps on the main queue.
    @MainActor private weak var ble: RingBLEManager?
    @MainActor private var isTapped = false

    private init() {}

    @MainActor
    func attach(_ ble: RingBLEManager) {
        self.ble = ble
        RingEvents.shared.add { event in
            if case .liveEnded = event { LiveAudioTap.shared.endHold() }
        }
    }

    @MainActor
    func stream() -> AsyncStream<LiveAudio> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LiveAudio>.makeStream(bufferingPolicy: .bufferingNewest(100))
        continuation.onTermination = { _ in
            LiveAudioTap.shared.remove(id)
        }
        queue.async { self.continuations[id] = continuation }
        setTapped(true)
        return stream
    }

    // MARK: - Listeners

    private func remove(_ id: UUID) {
        queue.async {
            self.continuations[id] = nil
            guard self.continuations.isEmpty else { return }
            self.decoder = nil
            self.held = []
            DispatchQueue.main.async { MainActor.assumeIsolated { LiveAudioTap.shared.setTapped(false) } }
        }
    }

    @MainActor
    private func setTapped(_ on: Bool) {
        guard on != isTapped, let ble else { return }
        isTapped = on
        if on {
            ble.addAudioTap(id: Self.tapID) { packet, isCaptureStart in
                LiveAudioTap.shared.receive(packet, isCaptureStart: isCaptureStart)
            }
        } else {
            ble.removeAudioTap(id: Self.tapID)
        }
    }

    // MARK: - Holds

    private func receive(_ packet: Data, isCaptureStart: Bool) {
        queue.async {
            guard !self.continuations.isEmpty else { return }
            if isCaptureStart || self.decoder == nil {
                self.decoder = LiveOpusStream()
                self.held = []
                self.send(.began(.now))
            }
            guard let samples = self.decoder?.append(packet), !samples.isEmpty else { return }
            self.held.append(contentsOf: samples)
            if self.held.count >= Self.chunkSamples {
                self.send(.samples(LiveAudioChunk(samples: self.held)))
                self.held = []
            }
        }
    }

    private func endHold() {
        queue.async {
            guard self.decoder != nil else { return }
            if !self.held.isEmpty {
                self.send(.samples(LiveAudioChunk(samples: self.held)))
            }
            self.held = []
            self.decoder = nil
            self.send(.ended)
        }
    }

    private func send(_ piece: LiveAudio) {
        for continuation in continuations.values { continuation.yield(piece) }
    }
}
