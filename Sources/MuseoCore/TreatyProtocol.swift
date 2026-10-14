import Foundation

/// BLE framing for Treaty commands. Internal to MuseRing — not part of the app API.

enum TreatyCommand: UInt8 {
    case getFileList = 0x01
    case sendFileList = 0x02
    case getFile = 0x03
    case getFileAck = 0x04
    case getFileSetAddress = 0x05
    case getFileEnd = 0x06
    case sendFileData = 0x07
    case sendFileSize = 0x08
    case getMAC = 0x09
    case sendMAC = 0x0A
    case getVersion = 0x0B
    case sendVersion = 0x0C
    case getTime = 0x0D
    case sendTime = 0x0E
    case setTime = 0x0F
    case format = 0x10
    case bindSet = 0x11
    case bindGet = 0x12
    case bindApply = 0x13
    case bindCheck = 0x14
    case bindCheckAck = 0x15
    case endBLERateHigh = 0x16
    case setRecord = 0x17
    case setPowerOff = 0x18
    case touchStartSecurity = 0x19
    /// Query current Opus recording bitrate (payload response: 0=16, 1=20, 2=24 kbps).
    case getRecordBitrate = 0x1C
    /// Set Opus recording bitrate (payload: 0=16, 1=20, 2=24 kbps). Frame duration stays 10 ms.
    /// Two optional bytes follow: noise reduction (0 to 2) and the AGC byte.
    case setRecordBitrate = 0x1D
    /// The ring's answer to `getRecordBitrate`: bitrate code, noise reduction, AGC.
    case recordParams = 0x1E
    case errorState = 0xE0
    case systemState = 0xE1
    case getSystemState = 0xE2
}

struct TreatyFrame {
    let sequence: UInt16
    let command: UInt8
    let payload: Data
}

enum TreatyProtocolCodec {
    static let frameDelimiter: UInt8 = 0x7E
    static let escapeByte: UInt8 = 0x7D

    static func build(command: TreatyCommand, payload: Data = Data(), sequence: UInt16) -> Data {
        var raw = Data()
        raw.append(0x01)
        raw.append(UInt8((sequence >> 8) & 0xFF))
        raw.append(UInt8(sequence & 0xFF))
        raw.append(0x00)
        raw.append(command.rawValue)
        raw.append(payload)

        let crc = modbusCRC16(raw)
        raw.append(UInt8((crc >> 8) & 0xFF))
        raw.append(UInt8(crc & 0xFF))

        var framed = Data([frameDelimiter])
        for byte in raw {
            switch byte {
            case frameDelimiter:
                framed.append(contentsOf: [escapeByte, 0x02])
            case escapeByte:
                framed.append(contentsOf: [escapeByte, 0x01])
            default:
                framed.append(byte)
            }
        }
        framed.append(frameDelimiter)
        return framed
    }

    static func hex(_ data: Data, limit: Int = 80) -> String {
        let bytes = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        if data.count > limit {
            return "\(bytes) ... (\(data.count) bytes)"
        }
        return bytes
    }

    /// Validates and parses a frame body that has already been un-escaped
    /// (version..CRC), matching the firmware's `process_frame` checks.
    static func parseUnescapedFrame(_ raw: [UInt8]) -> TreatyFrame? {
        guard raw.count >= 7, raw[0] == 0x01 else {
            return nil
        }
        let n = raw.count
        // Firmware transmits CRC low byte first; our bitwise CRC is the byte-swap
        // of the firmware's table CRC, so a big-endian read of the trailing two
        // bytes equals our computed value. Accept both orders for safety.
        let sequence = (UInt16(raw[1]) << 8) | UInt16(raw[2])
        let command = raw[4]
        let bigEndianCRC = (UInt16(raw[n - 2]) << 8) | UInt16(raw[n - 1])
        let littleEndianCRC = UInt16(raw[n - 2]) | (UInt16(raw[n - 1]) << 8)
        let computed = modbusCRC16(Data(raw[0..<(n - 2)]))
        let crcMatches = computed == bigEndianCRC || computed == littleEndianCRC

        guard crcMatches || canTolerateFileDataCRC(raw, command: command) else {
            return nil
        }

        let payload = n > 7 ? Data(raw[5..<(n - 2)]) : Data()
        return TreatyFrame(sequence: sequence, command: command, payload: payload)
    }

    private static func canTolerateFileDataCRC(_ raw: [UInt8], command: UInt8) -> Bool {
        // Current 54L15 firmware sends complete, escaped 0x07 file-data frames
        // whose CRC bytes do not match the same CRC routine used by short Treaty
        // frames. BLE notifications already have link-layer integrity, so accept
        // structurally valid file-data frames while firmware fixes the data-frame
        // CRC calculation.
        guard command == TreatyCommand.sendFileData.rawValue, raw.count >= 14 else {
            return false
        }
        let payloadLength = raw.count - 5 - 2
        return payloadLength >= 8
    }

    static func modbusCRC16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 0x0001 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}

/// Byte-by-byte Treaty frame decoder. Survives BLE fragmentation and the
/// fast 0x07 file-data stream.
final class TreatyFrameDecoder {
    private enum State {
        case head
        case data
    }

    private static let maxFrameLength = 4096

    private var state: State = .head
    private var buffer: [UInt8] = []
    private var escapeNext = false

    func reset() {
        state = .head
        buffer.removeAll(keepingCapacity: true)
        escapeNext = false
    }

    func feed(_ data: Data) -> [TreatyFrame] {
        var frames: [TreatyFrame] = []
        for byte in data {
            switch state {
            case .head:
                if byte == TreatyProtocolCodec.frameDelimiter {
                    buffer.removeAll(keepingCapacity: true)
                    escapeNext = false
                    state = .data
                }

            case .data:
                if escapeNext {
                    escapeNext = false
                    switch byte {
                    case 0x02:
                        appendByte(TreatyProtocolCodec.frameDelimiter)
                    case 0x01:
                        appendByte(TreatyProtocolCodec.escapeByte)
                    default:
                        state = .head // illegal escape sequence
                    }
                } else if byte == TreatyProtocolCodec.escapeByte {
                    escapeNext = true
                } else if byte == TreatyProtocolCodec.frameDelimiter {
                    let frame = TreatyProtocolCodec.parseUnescapedFrame(buffer)
                    if let frame {
                        frames.append(frame)
                    }
                    buffer.removeAll(keepingCapacity: true)
                    state = .head
                } else {
                    appendByte(byte)
                }
            }
        }
        return frames
    }

    private func appendByte(_ byte: UInt8) {
        if buffer.count < Self.maxFrameLength {
            buffer.append(byte)
        } else {
            state = .head // overflow guard, matches firmware
        }
    }
}
