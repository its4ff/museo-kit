import Foundation

enum OggOpusWriter {
    /// Preferred CBR frame size for the currently selected bitrate.
    static var fixedFrameByteCount: Int { OpusFormat.cbrFrameByteCount }
    static private(set) var lastExtractionSummary = "No Opus packets extracted"

    static func extractPackets(from notifications: [Data]) -> [Data] {
        guard !notifications.isEmpty else { return [] }

        if notifications.count == 1, let single = extractSingleBlob(notifications[0]) {
            lastExtractionSummary = single.summary
            return single.packets
        }

        let result = extractStreamingNotifications(notifications)
        lastExtractionSummary = result.summary
        return result.packets
    }

    static func write(packets: [Data], inputSampleRate: UInt32) -> Data? {
        let opusPackets = packets.filter { !$0.isEmpty }
        guard !opusPackets.isEmpty else {
            return nil
        }

        var output = Data()
        let serial = UInt32.random(in: 1...UInt32.max)
        var sequence: UInt32 = 0
        var granulePosition: UInt64 = 0

        output.append(page(packet: opusHead(inputSampleRate: inputSampleRate), headerType: 0x02, granulePosition: 0, serial: serial, sequence: sequence))
        sequence += 1
        output.append(page(packet: opusTags(), headerType: 0x00, granulePosition: 0, serial: serial, sequence: sequence))
        sequence += 1

        for (index, packet) in opusPackets.enumerated() {
            granulePosition += UInt64(opusSamplesAt48k(packet))
            let headerType: UInt8 = index == opusPackets.count - 1 ? 0x04 : 0x00
            output.append(page(packet: packet, headerType: headerType, granulePosition: granulePosition, serial: serial, sequence: sequence))
            sequence += 1
        }

        return output
    }

    // MARK: - Streaming (many BLE notifications)

    private static func extractStreamingNotifications(_ notifications: [Data]) -> (packets: [Data], summary: String) {
        var bestPackets: [Data] = []
        var bestFrameSize = OpusFormat.cbrFrameByteCount
        var bestStripped = 0

        for frameSize in OpusFormat.cbrFrameByteCandidates {
            var buffer = Data()
            buffer.reserveCapacity(notifications.reduce(0) { $0 + $1.count })
            var strippedHeaders = 0
            for notification in notifications where !notification.isEmpty {
                let payload = stripLeadingStreamHeader(from: notification, frameSize: frameSize)
                if payload.count != notification.count {
                    strippedHeaders += 1
                }
                buffer.append(payload)
            }

            let packets = extractMarkerAnchoredFrames(
                from: buffer,
                frameSize: frameSize,
                marker: OpusFormat.streamingFrameMarker
            )
            if packets.count > bestPackets.count {
                bestPackets = packets
                bestFrameSize = frameSize
                bestStripped = strippedHeaders
            }
            if frameSize == OpusFormat.cbrFrameByteCount, packets.count >= 8 {
                break
            }
        }

        let probeCount = min(5, bestPackets.count)
        let probePass = bestPackets.prefix(probeCount).filter { OpusWavDecoder.isDecodablePacket($0) }.count
        let decodeNote = probeCount > 0 ? "; decode probe \(probePass)/\(probeCount)" : ""
        let bitrateNote = RecordingBitrate.from(frameByteCount: bestFrameSize).map { " \($0.label)" } ?? ""

        let duration = OpusFormat.durationSeconds(packetCount: bestPackets.count)
        let summary = "Extracted \(bestPackets.count) Opus frames (\(String(format: "%.1fs", duration))) from \(notifications.count) BLE notifications (marker 0x\(String(format: "%02X", OpusFormat.streamingFrameMarker)) every \(bestFrameSize)B\(bitrateNote))\(decodeNote); \(bestStripped) chunk(s) had 4-byte prefix stripped"
        if probeCount > 0 && probePass == 0 {
            NSLog("[muse] Opus frame sync probe failed (0/%d) — check BLE 0x0009 payload layout", probeCount)
        }
        return (bestPackets, summary)
    }

    // MARK: - Offline / single blob

    private static func extractSingleBlob(_ data: Data) -> (packets: [Data], summary: String)? {
        guard !data.isEmpty else { return nil }

        for frameSize in OpusFormat.cbrFrameByteCandidates {
            let buffer = stripLeadingStreamHeader(from: data, frameSize: frameSize)
            var packets = extractMarkerAnchoredFrames(
                from: buffer,
                frameSize: frameSize,
                marker: OpusFormat.streamingFrameMarker
            )
            if packets.count < 4 {
                packets = extractCBRFrames(from: buffer, frameSize: frameSize, allowLegacySize: false)
            }
            if packets.count >= 4 {
                let duration = OpusFormat.durationSeconds(packetCount: packets.count)
                let label = RecordingBitrate.from(frameByteCount: frameSize)?.label ?? "\(frameSize)-byte"
                return (packets, "Extracted \(packets.count) Opus frames (\(String(format: "%.1fs", duration))) from offline blob (\(buffer.count) bytes, \(label) CBR)")
            }
        }

        let legacyPackets = extractCBRFrames(from: data, frameSize: OpusFormat.legacyFrameByteCount, allowLegacySize: true)
        guard !legacyPackets.isEmpty else { return nil }
        let duration = Double(legacyPackets.count * OpusFormat.legacySamplesPerFrame) / Double(OpusFormat.sampleRate)
        return (legacyPackets, "Extracted \(legacyPackets.count) legacy Opus frames (\(String(format: "%.1fs", duration))) from offline blob (\(data.count) bytes, 10-byte CBR)")
    }

    private static func extractMarkerAnchoredFrames(from data: Data, frameSize: Int, marker: UInt8) -> [Data] {
        guard data.count >= frameSize * 3 else { return [] }

        guard var offset = findMarkerSync(in: data, frameSize: frameSize, marker: marker, minimumFrames: 4) else {
            return []
        }

        var packets: [Data] = []
        packets.reserveCapacity(data.count / frameSize)

        while offset + frameSize <= data.count {
            guard let slice = packetSlice(in: data, offset: offset, length: frameSize) else { break }

            if slice.first == marker {
                packets.append(Data(slice))
                offset += frameSize
                continue
            }

            offset += 1
            if let resync = findMarkerSync(in: data, frameSize: frameSize, marker: marker, minimumFrames: 3, searchStart: offset, searchLimit: min(offset + frameSize * 4, data.count)) {
                offset = resync
            }
        }

        return packets
    }

    private static func findMarkerSync(
        in data: Data,
        frameSize: Int,
        marker: UInt8,
        minimumFrames: Int,
        searchStart: Int = 0,
        searchLimit: Int? = nil
    ) -> Int? {
        guard data.count >= frameSize * minimumFrames else { return nil }

        let upper = min(searchLimit ?? data.count, data.count - frameSize * minimumFrames + 1)
        guard searchStart < upper else { return nil }

        for start in searchStart..<upper {
            guard byteAt(data, start) == marker else { continue }

            var matched = true
            for index in 0..<minimumFrames {
                let position = start + index * frameSize
                if position + frameSize > data.count || byteAt(data, position) != marker {
                    matched = false
                    break
                }
            }
            if matched {
                return start
            }
        }
        return nil
    }

    /// Drops the 4-byte stream header some notifications start with. `LiveOpusStream` uses it
    /// too, so live audio finds frames exactly the way a finished capture does.
    static func stripLeadingStreamHeader(from data: Data, frameSize: Int) -> Data {
        guard data.count > frameSize + 4 else { return data }

        let head = data.prefix(frameSize)
        if looksLikeCBRPacket(head, frameSize: frameSize) {
            return data
        }

        let afterHeader = data.dropFirst(4)
        if afterHeader.count >= frameSize,
           looksLikeCBRPacket(afterHeader.prefix(frameSize), frameSize: frameSize) {
            return Data(afterHeader)
        }

        return data
    }

    private static func extractCBRFrames(from data: Data, frameSize: Int, allowLegacySize: Bool) -> [Data] {
        var buffer = Data(data)
        var packets: [Data] = []
        packets.reserveCapacity(max(1, buffer.count / frameSize))

        if let sync = findFrameSync(in: buffer, frameSize: frameSize), sync > 0 {
            buffer = buffer.dropFirst(sync)
        }

        while buffer.count >= frameSize {
            let candidate = buffer.prefix(frameSize)
            if looksLikeCBRPacket(candidate, frameSize: frameSize, allowLegacySize: allowLegacySize) {
                packets.append(Data(candidate))
                buffer = buffer.dropFirst(frameSize)
            } else {
                buffer = buffer.dropFirst(1)
                if buffer.count >= frameSize * 3,
                   let sync = findFrameSync(in: buffer, frameSize: frameSize), sync > 0 {
                    buffer = buffer.dropFirst(sync)
                }
            }
        }

        return packets
    }

    private static func findFrameSync(in data: Data, frameSize: Int, minimumFrames: Int = 3) -> Int? {
        guard data.count >= frameSize * minimumFrames else { return nil }

        let maxStart = min(frameSize, data.count - frameSize * minimumFrames)
        for start in 0...maxStart {
            var matches = true
            for index in 0..<minimumFrames {
                let offset = start + index * frameSize
                guard let slice = packetSlice(in: data, offset: offset, length: frameSize) else {
                    matches = false
                    break
                }
                if !looksLikeCBRPacket(slice, frameSize: frameSize) {
                    matches = false
                    break
                }
            }
            if matches {
                return start
            }
        }
        return nil
    }

    private static func byteAt(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    private static func packetSlice(in data: Data, offset: Int, length: Int) -> Data.SubSequence? {
        guard offset >= 0, length > 0, offset + length <= data.count else { return nil }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: length)
        return data[start..<end]
    }

    private static func looksLikeCBRPacket(_ packet: Data.SubSequence, frameSize: Int, allowLegacySize: Bool = false) -> Bool {
        guard packet.count == frameSize else { return false }
        guard looksLikeSingleOpusPacket(Data(packet)) else { return false }

        if RecordingBitrate.from(frameByteCount: frameSize) != nil {
            return packet.first == OpusFormat.streamingFrameMarker
        }

        return allowLegacySize && frameSize == OpusFormat.legacyFrameByteCount
    }

    private static func looksLikeSingleOpusPacket(_ packet: Data) -> Bool {
        guard let toc = packet.first, (2...400).contains(packet.count) else {
            return false
        }

        let config = toc >> 3
        let code = toc & 0x03
        if config > 31 {
            return false
        }
        if code == 0 {
            return true
        }
        if code == 1 || code == 2 {
            return packet.count >= 2
        }
        guard packet.count >= 2 else {
            return false
        }
        let frameCount = packet[1] & 0x3F
        return (1...48).contains(frameCount)
    }

    private static func opusHead(inputSampleRate: UInt32) -> Data {
        var data = Data("OpusHead".utf8)
        data.append(0x01)
        data.append(0x01)
        data.appendLittleEndian(UInt16(640))
        data.appendLittleEndian(inputSampleRate)
        data.appendLittleEndian(UInt16(0))
        data.append(0x00)
        return data
    }

    private static func opusTags() -> Data {
        let vendor = "muse-os"
        var data = Data("OpusTags".utf8)
        data.appendLittleEndian(UInt32(vendor.utf8.count))
        data.append(contentsOf: vendor.utf8)
        data.appendLittleEndian(UInt32(0))
        return data
    }

    private static func page(packet: Data, headerType: UInt8, granulePosition: UInt64, serial: UInt32, sequence: UInt32) -> Data {
        let lacing = lacingValues(for: packet.count)
        var data = Data("OggS".utf8)
        data.append(0x00)
        data.append(headerType)
        data.appendLittleEndian(granulePosition)
        data.appendLittleEndian(serial)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(UInt32(0))
        data.append(UInt8(lacing.count))
        data.append(contentsOf: lacing)
        data.append(packet)

        let checksum = oggCRC(data)
        data.replaceSubrange(22..<26, with: Data(littleEndianBytes: checksum))
        return data
    }

    private static func lacingValues(for byteCount: Int) -> [UInt8] {
        var remaining = byteCount
        var values: [UInt8] = []
        while remaining >= 255 {
            values.append(255)
            remaining -= 255
        }
        values.append(UInt8(remaining))
        return values
    }

    private static func opusSamplesAt48k(_ packet: Data) -> Int {
        guard let toc = packet.first else {
            return 960
        }

        let config = Int(toc >> 3)
        let code = Int(toc & 0x03)
        let frameCount: Int
        switch code {
        case 0:
            frameCount = 1
        case 1, 2:
            frameCount = 2
        default:
            if packet.count > 1 {
                frameCount = max(1, Int(packet[1] & 0x3F))
            } else {
                frameCount = 1
            }
        }

        let frameSamples: Int
        if config < 12 {
            frameSamples = [480, 960, 1_920, 2_880][config % 4]
        } else if config < 16 {
            frameSamples = [480, 960][config % 2]
        } else {
            frameSamples = [120, 240, 480, 960][config % 4]
        }

        return min(frameSamples * frameCount, 5_760)
    }

    private static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                if crc & 0x8000_0000 != 0 {
                    crc = (crc << 1) ^ 0x04C1_1DB7
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}

private extension Data {
    init(littleEndianBytes value: UInt32) {
        self.init([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

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

    mutating func appendLittleEndian(_ value: UInt64) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 56) & 0xFF))
    }
}
