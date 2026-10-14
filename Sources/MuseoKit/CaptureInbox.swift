import Combine
import Foundation
import OSLog

/// Hands each finished capture to the app's `Museo.onCapture` once, and lets the ring
/// retire its copy only after the app says the recording is safe.
///
/// - Streamed captures under `Museo.shortestCapture` are presses, not muses: their files go.
/// - A recording the ledger already has arrives with `seenBefore`, so the app keeps (or
///   skips) its own copy. A deleted muse never comes back as a new one.
/// - Whenever the ring lists its files, every one already brought in is handed back to the
///   manager first, so its "waiting" count is right and its sync skips them.
/// - A live capture has no copy on the ring. When the app couldn't save one (`false`), it's
///   kept here and offered again on the next `takeWaiting()`, until the app takes it.
@MainActor
final class CaptureInbox {
    static let shared = CaptureInbox()

    private weak var ble: RingBLEManager?
    private var save: ((CompletedCapture, Bool) -> Bool)?
    private var subscriptions = Set<AnyCancellable>()
    /// Keys already handed back to the manager this launch.
    private var handedBack: Set<String> = []
    /// Live captures the app couldn't save yet. Offered again before anything new.
    private var unsaved: [CompletedCapture] = []
    private lazy var ledger = RingImportLedger()

    nonisolated private static let log = Logger(subsystem: "museo.kit", category: "captures")

    private init() {}

    func attach(_ ble: RingBLEManager) {
        guard self.ble !== ble else { return }
        self.ble = ble
        subscriptions.removeAll()
        ble.$completedCaptures
            .receive(on: DispatchQueue.main)
            .sink { [weak self] captures in
                guard !captures.isEmpty else { return }
                self?.takeWaiting()
            }
            .store(in: &subscriptions)
        // The manager lists the ring's files a beat before it downloads any: in that beat,
        // remind it of every one already here, so none comes in twice.
        ble.$ringFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] files in self?.handBack(files) }
            .store(in: &subscriptions)
        takeWaiting()
    }

    func setHandler(_ save: @escaping (CompletedCapture, Bool) -> Bool) {
        self.save = save
        takeWaiting()
    }

    /// Delivers everything the manager is holding. Waits (leaving them queued in the
    /// manager) until the app has set its handler.
    func takeWaiting() {
        guard let ble, save != nil else { return }
        let again = unsaved
        unsaved = []
        for capture in again + ble.drainCaptures() {
            deliver(capture)
        }
    }

    private func deliver(_ capture: CompletedCapture) {
        guard let save else { return }
        if capture.source == .stream, capture.duration < Museo.shortestCapture {
            Self.log.info("dropped a \(capture.duration, format: .fixed(precision: 2)) s press · \(capture.fileName, privacy: .public)")
            discardFiles(of: capture)
            return
        }
        let key = capture.offlineSyncKey
        let seenBefore = key.map(ledger.contains) ?? false
        let safe = save(capture, seenBefore)
        guard let key else {
            // Live: the ring kept nothing, so this copy is the only one.
            if !safe {
                Self.log.error("not saved yet; keeping live capture \(capture.fileName, privacy: .public) to offer again")
                unsaved.append(capture)
            }
            return
        }
        guard safe else {
            Self.log.error("not saved yet; the ring keeps \(capture.fileName, privacy: .public) for the next sync")
            return
        }
        ledger.add(key)
        ble?.markOfflineSynced(key)
    }

    private func handBack(_ files: [RingFile]) {
        guard let ble, !files.isEmpty else { return }
        for file in files {
            let key = file.syncKey
            guard !handedBack.contains(key), ledger.contains(key) else { continue }
            handedBack.insert(key)
            ble.markOfflineSynced(key)
        }
    }

    private func discardFiles(of capture: CompletedCapture) {
        for name in [capture.wavFileName, capture.fileName].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: RingBLEManager.capturesDirectory.appendingPathComponent(name))
        }
    }
}
