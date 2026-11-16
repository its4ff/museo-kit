import Foundation

/// How deleting one recording from the ring went.
public enum RingFileDeletion: Equatable, Sendable {
    /// Gone from the ring.
    case deleted
    /// Not sent: the reason, in plain words ("not saved on this device yet").
    case refused(String)
    /// The ring found no recording with that number.
    case notFound
    /// The ring was busy (sending, or recording) and kept it.
    case busy
    /// The ring answered with another error code.
    case failed(UInt8)
    /// No answer came.
    case timedOut
}

/// One recording off the ring (Treaty 0x1B), instead of formatting it all (0x10).
///
/// The ring finds the file by its record and segment number only (`fileName`), and takes the
/// first file with that number. Several recordings can share one (one ring had five empty
/// recordings numbered 00-01), and then the delete could take another, which may not be saved
/// anywhere. So a recording is deleted only when it, and every recording in the last whole
/// list sharing its number, is saved on this device or empty.
extension RingBLEManager {
    /// Deletes `file` from the ring. Never call it from code that runs on its own without the
    /// person having asked for recordings to leave the ring.
    public func deleteRingFile(_ file: RingFile, completion: @escaping (RingFileDeletion) -> Void) {
        if let reason = deletionRefusal(for: file) {
            print("[muse][delete] not deleting \(file.fileName): \(reason)")
            completion(.refused(reason))
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.finishDeletion(.timedOut)
        }
        pendingDeletion = PendingDeletion(file: file, completion: completion, timer: timer)
        var payload = Data([file.recordByte])
        payload.append(contentsOf: file.segmentBytes.prefix(2))
        send(.deleteFile, payload: payload)
        print("[muse][delete] deleting \(file.fileName) (\(file.size) bytes) (0x1B)")
    }

    /// Why `file` can't be deleted now, or nil when it can.
    public func deletionRefusal(for file: RingFile) -> String? {
        guard isProtocolReady else { return "ring not connected" }
        guard canTransferOfflineFiles, !isOfflineSyncBusy, pendingDeletion == nil else { return "the ring is busy" }
        guard hasWholeFileList else { return "no whole file list yet" }
        guard file.size == 0 || syncedOfflineKeys.contains(file.syncKey) else { return "not saved on this device yet" }
        // The ring takes the first file with this number, so every recording sharing it must
        // be safe to lose: empty, or saved here. (A key is "name|size|stamp".)
        let sharing = listedEntryKeys.filter { $0.hasPrefix(file.fileName + "|") }
        let unsafe = sharing.filter { key in
            key.split(separator: "|").dropFirst().first != "0" && !syncedOfflineKeys.contains(key)
        }
        guard unsafe.isEmpty else { return "shares its number with a recording not saved here" }
        return nil
    }

    /// The ring's answer to a delete, when one is waiting. True when it was one.
    func handleDeletionReply(_ code: UInt8) -> Bool {
        guard pendingDeletion != nil else { return false }
        switch code {
        case 0x00: finishDeletion(.deleted)
        case 0x02, 0x03: finishDeletion(.busy)
        case 0x04: finishDeletion(.notFound)
        default: finishDeletion(.failed(code))
        }
        return true
    }

    private func finishDeletion(_ result: RingFileDeletion) {
        guard let pending = pendingDeletion else { return }
        pending.timer.invalidate()
        pendingDeletion = nil
        if result == .deleted {
            // The list is stale now: drop the file from it, and ask the ring for its count.
            ringFiles.removeAll { $0.syncKey == pending.file.syncKey }
            listedEntryKeys.remove(pending.file.syncKey)
            requestSystemState()
        }
        print("[muse][delete] \(pending.file.fileName): \(result)")
        pending.completion(result)
    }
}

/// A delete waiting for the ring's answer.
struct PendingDeletion {
    let file: RingFile
    let completion: (RingFileDeletion) -> Void
    let timer: Timer
}
