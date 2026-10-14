import AVFoundation
import AudioToolbox
import Foundation

enum OpusWavDecoder {
    private static let sampleRate = Double(OpusFormat.sampleRate)

    static func decodeToWav(packets: [Data], outputSampleRate: Double = sampleRate) -> Data? {
        guard let pcmBytes = decodeToPCM(packets: packets, outputSampleRate: outputSampleRate) else {
            return nil
        }
        return wavData(pcmBytes: pcmBytes, sampleRate: UInt32(outputSampleRate), channels: 1, bitsPerSample: 16)
    }

    static func wav(fromPCM pcmBytes: Data, sampleRate: Double = sampleRate) -> Data {
        wavData(pcmBytes: pcmBytes, sampleRate: UInt32(sampleRate), channels: 1, bitsPerSample: 16)
    }

    static func pcm(fromWav url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return pcm(fromWav: data)
    }

    static func pcm(fromWav data: Data) -> Data? {
        let riff = Array("data".utf8)
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        var i = 12
        while i + 8 <= bytes.count {
            let id = Array(bytes[i..<i+4])
            let size = Int(bytes[i+4]) | (Int(bytes[i+5]) << 8) | (Int(bytes[i+6]) << 16) | (Int(bytes[i+7]) << 24)
            let bodyStart = i + 8
            if id == riff {
                let end = min(bodyStart + size, bytes.count)
                guard end > bodyStart else { return nil }
                return data.subdata(in: bodyStart..<end)
            }
            i = bodyStart + size + (size & 1)
        }
        return nil
    }

    static func filterDecodablePackets(_ packets: [Data]) -> [Data] {
        packets.filter { isDecodablePacket($0) }
    }

    static func isDecodablePacket(_ packet: Data) -> Bool {
        guard let pcm = decodeSinglePacketPCM(packet) else { return false }
        return pcm.count >= OpusFormat.samplesPerFrame * MemoryLayout<Int16>.size
    }

    static func decodeToPCM(packets: [Data], outputSampleRate: Double = sampleRate) -> Data? {
        let opusPackets = packets.filter { !$0.isEmpty }
        guard !opusPackets.isEmpty else { return nil }

        if let pcm = decodeBatch(packets: opusPackets, outputSampleRate: outputSampleRate) {
            return pcm
        }

        let (pcm, decodedCount) = decodePerPacket(packets: opusPackets, outputSampleRate: outputSampleRate)
        if decodedCount > 0 {
            if decodedCount < opusPackets.count {
                NSLog("[muse] Opus decode recovered %d/%d packets via per-packet fallback", decodedCount, opusPackets.count)
            }
            return pcm
        }

        return nil
    }

    private static func decodeSinglePacketPCM(_ packet: Data, outputSampleRate: Double = sampleRate) -> Data? {
        guard let inputFormat = makeOpusInputFormat(),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )

        packet.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                compressedBuffer.data.copyMemory(from: baseAddress, byteCount: packet.count)
            }
        }
        if compressedBuffer.packetDescriptions != nil {
            compressedBuffer.packetDescriptions?[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: UInt32(OpusFormat.samplesPerFrame),
                mDataByteSize: UInt32(packet.count)
            )
        }
        compressedBuffer.byteLength = UInt32(packet.count)
        compressedBuffer.packetCount = 1

        return runConverter(converter, outputFormat: outputFormat, inputProvider: {
            compressedBuffer
        })
    }

    /// Packets handed to Apple's Opus decoder at once: one second of 10 ms frames.
    ///
    /// One buffer of about 1,000 packets can make `AVAudioConverter` spin forever on its
    /// first call (993 to 1,008 in a desktop test on macOS 26, so about a 10 s recording;
    /// museum hit the same thing on 2026-10-07). That wedged the decode queue: offline sync
    /// stopped for good and live takes were lost. 100 at a time stays far from it.
    static let chunkPackets = 100

    /// One converter for the whole recording, so the decoder's state carries from packet to
    /// packet, fed `chunkPackets` at a time.
    private static func decodeBatch(packets: [Data], outputSampleRate: Double) -> Data? {
        guard let inputFormat = makeOpusInputFormat(),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        var next = 0
        var failed = false
        var pcmBytes = Data()
        pcmBytes.reserveCapacity(packets.count * OpusFormat.samplesPerFrame * MemoryLayout<Int16>.size)

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_000) else {
                return nil
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                guard next < packets.count else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let end = min(next + chunkPackets, packets.count)
                guard let chunk = compressedBuffer(packets[next..<end], format: inputFormat) else {
                    failed = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                next = end
                outStatus.pointee = .haveData
                return chunk
            }

            if let conversionError {
                NSLog("%@", "[muse] Opus decode failed: \(conversionError.localizedDescription)")
                return nil
            }
            if failed { return nil }

            appendPCM(from: outputBuffer, to: &pcmBytes)

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                return pcmBytes.isEmpty ? nil : pcmBytes
            case .error:
                return nil
            @unknown default:
                return nil
            }
        }
    }

    /// One chunk of packets as the converter wants them. Without packet descriptions it
    /// produces nothing, so a buffer without them is refused.
    private static func compressedBuffer(_ packets: ArraySlice<Data>, format: AVAudioFormat) -> AVAudioCompressedBuffer? {
        let maxPacketSize = packets.map(\.count).max() ?? OpusFormat.cbrFrameByteCount
        let buffer = AVAudioCompressedBuffer(
            format: format,
            packetCapacity: AVAudioPacketCount(packets.count),
            maximumPacketSize: maxPacketSize
        )
        guard buffer.packetDescriptions != nil else { return nil }
        var offset = 0
        for (index, packet) in packets.enumerated() {
            packet.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    buffer.data.advanced(by: offset).copyMemory(from: baseAddress, byteCount: packet.count)
                }
            }
            buffer.packetDescriptions?[index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset),
                mVariableFramesInPacket: UInt32(OpusFormat.samplesPerFrame),
                mDataByteSize: UInt32(packet.count)
            )
            offset += packet.count
        }
        buffer.byteLength = UInt32(offset)
        buffer.packetCount = AVAudioPacketCount(packets.count)
        return buffer
    }

    private static func decodePerPacket(packets: [Data], outputSampleRate: Double) -> (Data, Int) {
        var pcmBytes = Data()
        var decodedCount = 0

        for packet in packets {
            guard let chunk = decodeSinglePacketPCM(packet, outputSampleRate: outputSampleRate) else { continue }
            pcmBytes.append(chunk)
            decodedCount += 1
        }

        return (pcmBytes, decodedCount)
    }

    private static func makeOpusInputFormat() -> AVAudioFormat? {
        var inputDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &inputDescription)
    }

    private static func runConverter(
        _ converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        inputProvider: @escaping () -> AVAudioCompressedBuffer
    ) -> Data? {
        var didProvideInput = false
        var pcmBytes = Data()

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                return nil
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return inputProvider()
            }

            if let conversionError {
                NSLog("%@", "[muse] Opus decode failed: \(conversionError.localizedDescription)")
                return nil
            }

            appendPCM(from: outputBuffer, to: &pcmBytes)

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                return pcmBytes.isEmpty ? nil : pcmBytes
            case .error:
                return nil
            @unknown default:
                return nil
            }
        }
    }

    private static func appendPCM(from buffer: AVAudioPCMBuffer, to data: inout Data) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.int16ChannelData else {
            return
        }

        data.append(contentsOf:
            UnsafeRawBufferPointer(
                start: channelData[0],
                count: frameLength * Int(buffer.format.channelCount) * MemoryLayout<Int16>.size
            )
        )
    }

    private static func wavData(pcmBytes: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        var data = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + pcmBytes.count))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(pcmBytes.count))
        data.append(pcmBytes)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
