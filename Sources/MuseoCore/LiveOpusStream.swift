import AVFoundation
import Foundation

/// A hold's audio as it arrives: the ring's BLE notifications in, 16 kHz mono 16-bit PCM out,
/// a few frames at a time. It feeds words while you speak; the finished capture is still
/// decoded from all of its notifications at once, as before.
///
/// Frames are found the way a finished capture finds them (24 kbps CBR frames that start with
/// the streaming marker, a 4-byte stream header stripped when a notification carries one), but
/// only in bytes not yet used, so a long hold costs the same per notification as a short one.
/// One converter decodes the whole hold, so the Opus decoder's state carries from frame to
/// frame. Not thread-safe: one queue owns it.
package final class LiveOpusStream {
    private let frameSize = OpusFormat.cbrFrameByteCount
    private let marker = OpusFormat.streamingFrameMarker
    /// Frames in a row, each starting with the marker, before the stream counts as found.
    private let framesToSync = 3
    /// Payload bytes not yet cut into frames.
    private var pending = Data()
    private var isSynced = false

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    package init?() {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(OpusFormat.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(OpusFormat.sampleRate),
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: input, to: output) else {
            return nil
        }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    /// Feeds one notification. Returns the samples it completed, often none.
    package func append(_ notification: Data) -> [Int16] {
        guard !notification.isEmpty else { return [] }
        pending.append(OggOpusWriter.stripLeadingStreamHeader(from: notification, frameSize: frameSize))
        let frames = takeFrames()
        guard !frames.isEmpty else { return [] }
        return decode(frames)
    }

    // MARK: - Frames

    /// Whole frames from the front of `pending`. Keeps a partial frame for the next call.
    private func takeFrames() -> [Data] {
        var frames: [Data] = []
        while true {
            if !isSynced {
                guard let start = syncPoint() else {
                    // Nothing that looks like the stream yet: keep only enough bytes to find
                    // it once the next notification lands.
                    let keep = frameSize * framesToSync
                    if pending.count > keep * 2 { pending = Data(pending.suffix(keep)) }
                    break
                }
                pending = Data(pending.dropFirst(start))
                isSynced = true
            }
            guard pending.count >= frameSize else { break }
            if pending.first == marker {
                frames.append(Data(pending.prefix(frameSize)))
                pending = Data(pending.dropFirst(frameSize))
            } else {
                // Lost the stream (a dropped notification): look for it again.
                isSynced = false
                pending = Data(pending.dropFirst())
            }
        }
        return frames
    }

    /// Where `framesToSync` marker-led frames in a row begin, if they do.
    private func syncPoint() -> Int? {
        let bytes = [UInt8](pending)
        let needed = frameSize * framesToSync
        guard bytes.count >= needed else { return nil }
        for start in 0...(bytes.count - needed) where bytes[start] == marker {
            if (1..<framesToSync).allSatisfy({ bytes[start + $0 * frameSize] == marker }) {
                return start
            }
        }
        return nil
    }

    // MARK: - Decode

    /// Decodes frames with the hold's one converter. The input block hands them over once,
    /// then says "no data now" rather than "end of stream", so the decoder keeps its state
    /// for the next call.
    private func decode(_ frames: [Data]) -> [Int16] {
        guard let input = compressedBuffer(frames),
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount((frames.count + 4) * OpusFormat.samplesPerFrame)
              ) else {
            return []
        }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error,
              let channel = output.int16ChannelData, output.frameLength > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    private func compressedBuffer(_ frames: [Data]) -> AVAudioCompressedBuffer? {
        let buffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: AVAudioPacketCount(frames.count),
            maximumPacketSize: frameSize
        )
        guard buffer.packetDescriptions != nil else { return nil }
        var offset = 0
        for (index, frame) in frames.enumerated() {
            frame.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.data.advanced(by: offset).copyMemory(from: base, byteCount: frame.count)
                }
            }
            buffer.packetDescriptions?[index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset),
                mVariableFramesInPacket: UInt32(OpusFormat.samplesPerFrame),
                mDataByteSize: UInt32(frame.count)
            )
            offset += frame.count
        }
        buffer.byteLength = UInt32(offset)
        buffer.packetCount = AVAudioPacketCount(frames.count)
        return buffer
    }
}
