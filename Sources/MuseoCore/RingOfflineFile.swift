import Foundation

/// One recording sitting in the ring's flash storage, as reported by Treaty 0x02.
public struct RingFile: Identifiable, Equatable {
    public let entryIndex: UInt16
    public let totalEntries: UInt16
    public let size: UInt32
    public let recordByte: UInt8
    public let segmentBytes: [UInt8]
    public let timestamp: Date?

    public var id: String { fileName }

    public var fileName: String {
        let segments = segmentBytes.prefix(2).map { RingByte.bcdString($0) }.joined()
        return "\(RingByte.bcdString(recordByte))-\(segments).ops"
    }

    /// Identity used to remember which recordings were already imported. Record
    /// numbers restart after a format, so size and timestamp are folded in.
    public var syncKey: String {
        let stamp = timestamp.map { String(Int($0.timeIntervalSince1970)) } ?? "no-date"
        return "\(fileName)|\(size)|\(stamp)"
    }

    static func parse(_ payload: Data) -> RingFile? {
        let bytes = Data(payload)
        guard bytes.count >= 17 else { return nil }
        return RingFile(
            entryIndex: RingByte.le16(bytes, at: 0),
            totalEntries: RingByte.le16(bytes, at: 2),
            size: RingByte.le32(bytes, at: 4),
            recordByte: bytes[8],
            segmentBytes: [bytes[9], bytes[10]],
            timestamp: RingByte.date(
                year: bytes[11],
                month: bytes[12],
                day: bytes[13],
                hour: bytes[14],
                minute: bytes[15],
                second: bytes[16]
            )
        )
    }
}

/// Ring status from Treaty 0xE1. Firmware pushes this when recording state or
/// file count changes, so an offline capture ending is noticed without polling.
public struct RingSystemState: Equatable {
    public let fileCount: Int
    public let isRecording: Bool
    public let freeStoragePercent: Int

    static func parse(_ payload: Data) -> RingSystemState? {
        let bytes = Data(payload)
        guard bytes.count >= 4 else { return nil }
        return RingSystemState(
            fileCount: Int(RingByte.le16(bytes, at: 0)),
            isRecording: bytes[2] != 0,
            freeStoragePercent: Int(bytes[3])
        )
    }
}

/// In-flight offline transfer. `received` tracks which byte ranges actually
/// arrived so gaps can be repaired with a breakpoint resume.
struct OfflineDownload {
    let file: RingFile
    var expectedSize: Int
    var bytes = Data()
    var received = IndexSet()
    var startedAt = Date()
    var didFinalize = false
    var lastResumeReceived = 0
    var stalledResumes = 0

    var isComplete: Bool {
        expectedSize > 0 && received.count >= expectedSize
    }

    var firstMissingOffset: Int? {
        guard expectedSize > 0 else { return nil }
        return IndexSet(integersIn: 0..<expectedSize).subtracting(received).first
    }

    var progress: Double {
        guard expectedSize > 0 else { return 0 }
        return min(1, Double(received.count) / Double(expectedSize))
    }
}

/// Byte helpers for Treaty payloads. Namespaced so they don't collide with the
/// BCD helper already used for the set-time command.
enum RingByte {
    static func le16(_ data: Data, at offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func le32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func bcdInt(_ byte: UInt8) -> Int {
        Int((byte >> 4) & 0x0F) * 10 + Int(byte & 0x0F)
    }

    static func bcdString(_ byte: UInt8) -> String {
        String(format: "%02d", bcdInt(byte))
    }

    static func date(year: UInt8, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8) -> Date? {
        var components = DateComponents()
        components.year = 2_000 + bcdInt(year)
        components.month = bcdInt(month)
        components.day = bcdInt(day)
        components.hour = bcdInt(hour)
        components.minute = bcdInt(minute)
        components.second = bcdInt(second)
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day) else { return nil }
        return Calendar.current.date(from: components)
    }
}
