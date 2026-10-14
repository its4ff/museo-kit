import Foundation
import OSLog

/// Every ring recording ever brought onto this phone, by the manager's key for it
/// (`CompletedCapture.offlineSyncKey`). Append only, never trimmed: a few thousand short
/// lines in `Application Support/MuseoKit/imported-keys.json`.
///
/// The manager keeps its own list of recordings already brought in, but only 500 of them
/// across launches. With "clear the ring once they're safe" off, recordings stay on the
/// ring, and one the manager forgot would come in again as a second muse. So
/// `CaptureInbox` hands these keys back to the manager for every file the ring lists, and
/// flags a recording already here as `seenBefore`. A key stays after its muse is deleted,
/// so a deleted muse never comes back.
@MainActor
final class RingImportLedger {
    private(set) var keys: Set<String> = []
    private let fileURL: URL

    nonisolated private static let log = Logger(subsystem: "museo.kit", category: "ledger")
    /// The manager's own list in UserDefaults. Read once, to start this ledger with what
    /// it already knew. Never written.
    private static let kitListKey = "muse.offline.syncedKeys"

    /// False while imported-keys.json is there but can't be read yet (the ring can wake the
    /// app before the iphone is first unlocked). Nothing is written until it's read, so the
    /// real ledger is never replaced by a partial one.
    private var isLoaded = false

    init(fileURL: URL = KitFiles.support.appendingPathComponent("imported-keys.json")) {
        self.fileURL = fileURL
        load()
    }

    func contains(_ key: String) -> Bool {
        if !isLoaded { load() }
        return keys.contains(Self.zoneFree(key)) || keys.contains(key)
    }

    /// Remembers a key for good. True when the ledger is on disk with it.
    @discardableResult
    func add(_ key: String) -> Bool {
        if !isLoaded { load() }
        let inserted = keys.insert(Self.zoneFree(key)).inserted
        // Kept in memory meanwhile, and merged in when the file can be read.
        guard isLoaded else { return false }
        guard inserted else { return true }
        return save()
    }

    /// The manager's key ("0001-0102.ops|48000|1791546000") ends in seconds since 1970,
    /// made from the ring's own clock read in the iphone's time zone, so it changes when the
    /// iphone changes zone. The ledger keeps the ring's wall clock instead
    /// ("…|w20261008141500"), which a trip doesn't move. "no-date" keys stay as they are.
    static func zoneFree(_ key: String) -> String {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let seconds = Double(parts[2]) else { return key }
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: seconds)
        )
        let wall = String(
            format: "%04d%02d%02d%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        return "\(parts[0])|\(parts[1])|w\(wall)"
    }

    private func load() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                // There, but not readable right now. Try again on the next use; never start over.
                Self.log.error("imported-keys.json can't be read yet: \(error.localizedDescription, privacy: .public)")
                return
            }
            if !data.isEmpty, let rows = try? JSONDecoder().decode([Lossy<String>].self, from: data) {
                let stored = Self.withZoneFree(rows.compactMap(\.value))
                let merged = keys.union(stored)
                keys = merged
                isLoaded = true
                // Keys remembered while the file couldn't be read join it now.
                if merged.count > stored.count { save() }
                return
            }
        }
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            // Never write over a file we couldn't read. Set it aside and start again.
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            Self.log.error("imported-keys.json could not be read, kept it at \(aside.lastPathComponent, privacy: .public)")
        }
        // First launch with the ledger: start from what the manager remembers.
        keys.formUnion(Self.withZoneFree(UserDefaults.standard.stringArray(forKey: Self.kitListKey) ?? []))
        isLoaded = true
        if !keys.isEmpty { save() }
    }

    /// Stored keys, each also in its zone-free form (older ledgers kept the raw key).
    private static func withZoneFree(_ stored: [String]) -> Set<String> {
        Set(stored.flatMap { [$0, zoneFree($0)] })
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(keys.sorted())
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Self.log.error("couldn't save imported-keys.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
