import Combine
import Foundation
import MuseoCore
import Observation

/// The ring, for every screen: one small `status` that changes only when something on
/// screen would.
///
/// ```swift
/// @Environment(RingModel.self) private var ring
/// Text(ring.status.shortLine)          // "ring linked", "listening…", "bringing in 3"
/// if ring.status.isLive { ... }        // a muse is streaming in
/// ```
///
/// It folds `RingBLEManager` (many published values, many changes a second while a muse
/// streams) and `RingSetup` (AccessorySetupKit) into one `RingStatus`, a turn later, so a
/// reconnect that touches a dozen values is one redraw. Port of museum's `MuseumRing` status
/// layer. To make the ring do something, use `RingActions`.
@MainActor
@Observable
public final class RingModel {
    public static let shared = RingModel()

    /// Reassigned only when it changes.
    public private(set) var status: RingStatus

    /// A link stuck in "connecting" this long reads as away. The manager has no stall
    /// signal of its own; muse OS uses the same 12 s.
    static let stallAfter: TimeInterval = 12
    /// Right after launch the manager is waking its central: "joining", not "away".
    static let launchGrace: TimeInterval = 4

    @ObservationIgnored private weak var ble: RingBLEManager?
    @ObservationIgnored private var setup: RingSetup?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var connectingSince: Date?
    @ObservationIgnored private var stallCheck: Task<Void, Never>?
    @ObservationIgnored private var graceEndsAt: Date?
    @ObservationIgnored private var graceCheck: Task<Void, Never>?
    /// "waiting" from the last finished file list, and how many files the ring held then.
    /// Held while the manager re-lists (it empties `ringFiles` for up to 2.5 s), when its
    /// own count would fall back to every file on the ring, imported ones too.
    @ObservationIgnored private var lastKnownWaiting: Int?
    @ObservationIgnored private var lastKnownFileCount = 0
    /// At the last fold: the manager had a file list, and was asking for one.
    @ObservationIgnored private var hadFileList = false
    @ObservationIgnored private var wasListing = false

    /// The ring's free storage from its last answer, so the sheet can say it while it's away.
    private static let freeStorageKey = "museo.kit.freeStorage"

    private init(status: RingStatus = .notSetUp, defaults: UserDefaults? = .standard) {
        self.status = status
        self.defaults = defaults
    }

    /// A fixed status for previews and lab screens. Never touches a ring.
    public static func preview(_ status: RingStatus) -> RingModel {
        RingModel(status: status, defaults: nil)
    }

    // MARK: - Attach

    /// Once, at launch (`Museo.start` does it). Starts folding the manager and the setup
    /// into `status`. Attaching the same manager again does nothing.
    func attach(_ ble: RingBLEManager, setup: RingSetup? = nil) {
        guard self.ble !== ble else { return }
        let setup = setup ?? .shared
        self.ble = ble
        self.setup = setup
        subscriptions.removeAll()

        // objectWillChange fires before a value lands: refresh a turn later.
        ble.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &subscriptions)
        observe(setup)

        graceEndsAt = Date(timeIntervalSinceNow: Self.launchGrace)
        graceCheck?.cancel()
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchGrace))
            guard !Task.isCancelled else { return }
            self?.graceEndsAt = nil
            self?.refresh()
        }
        refresh()
    }

    /// Re-reads the ring now instead of a turn later.
    public func refresh() {
        guard let ble else { return }
        let setup = self.setup ?? .shared
        trackConnecting(ble.state)
        let next = makeStatus(ble, setup)
        if next != status { status = next }
    }

    // MARK: - Folding

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshQueued = false
            refresh()
        }
    }

    /// Re-registers after each change: observation tracking fires once.
    private func observe(_ setup: RingSetup) {
        withObservationTracking {
            _ = setup.isReady
            _ = setup.authorizedRingID
            _ = setup.authorizedName
            _ = setup.isPickerInFlight
            _ = setup.pickerFoundNothing
            _ = setup.setupError
            _ = setup.isLinking
            _ = setup.isSearching
            _ = setup.userDisconnected
            _ = setup.canRename
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.setup === setup else { return }
                queueRefresh()
                observe(setup)
            }
        }
    }

    private func makeStatus(_ ble: RingBLEManager, _ setup: RingSetup) -> RingStatus {
        let link = link(ble, setup)
        var next = RingStatus(link: link)
        next.usesAccessorySetup = RingSetup.isEnabled
        next.isFirmwareUpdating = ble.isFirmwareUpdateInProgress
        next.autoSync = ble.autoSyncOfflineRecordings
        next.autoClear = ble.autoClearRingStorage
        next.isSettingUp = setup.isPickerInFlight || setup.isSearching

        guard link != .notSetUp else {
            forgetFileList()
            if defaults?.object(forKey: Self.freeStorageKey) != nil {
                defaults?.removeObject(forKey: Self.freeStorageKey)
            }
            next.setupNote = setupNote(setup)
            return next
        }

        next.name = setup.authorizedName ?? Museo.ringName
        next.advertisedName = Self.isAdvertisedName(ble.deviceName) ? ble.deviceName : nil
        next.userDisconnected = setup.userDisconnected && link != .linked
        next.canRename = setup.canRename

        next.battery = RingStatus.quantized(battery: ble.batteryPercent)
        next.isCharging = ble.batteryIsCharging
        next.batteryIsStale = ble.isBatteryEstimate || link != .linked
        next.batteryReadAt = ble.batteryReadAt

        next.isLive = ble.isCapturing
        next.liveSince = ble.isCapturing ? ble.activeCaptureStartedAt : nil
        next.isRecordingOnRing = ble.ringIsRecordingOffline

        next.isSyncing = ble.isSyncingOffline
        next.waiting = waiting(ble, link: link)
        if ble.isSyncingOffline {
            next.syncProgress = RingStatus.quantized(progress: ble.offlineSyncProgress)
            next.waiting = max(ble.offlineQueueRemaining, 1)
        }
        next.syncError = ble.offlineSyncError.map(\.kitQuiet)
        next.freeStoragePercent = freeStorage(ble)
        if link != .linked { next.setupNote = setupNote(setup) }
        return next
    }

    /// The link, from the manager's public state plus what AccessorySetupKit says.
    private func link(_ ble: RingBLEManager, _ setup: RingSetup) -> RingStatus.Link {
        let usesSetupKit = RingSetup.isEnabled
        if usesSetupKit, setup.isReady {
            // AccessorySetupKit is the truth once it has answered: an authorized ring is set
            // up even when the manager has no remembered id yet (reconcile hands it over).
            if setup.authorizedRingID == nil { return .notSetUp }
        } else if ble.preferredPeripheralID == nil, !ble.isConnected, !setup.isLinking {
            return .notSetUp
        }
        if ble.state == .bluetoothOff { return .bluetoothOff }
        if ble.isConnected { return .linked }
        if setup.userDisconnected { return .away }
        switch ble.state {
        case .connected:
            // GATT is up, the ring's protocol isn't ready yet.
            return .joining
        case .connecting:
            return setup.isLinking || !isStalled ? .joining : .away
        case .idle:
            // Before the central powers on (launch) or AccessorySetupKit activates.
            let waking = graceEndsAt != nil || (usesSetupKit && !setup.isReady)
            return setup.isLinking || waking ? .joining : .away
        case .scanning, .disconnected, .failed:
            return setup.isLinking ? .joining : .away
        case .bluetoothOff:
            return .bluetoothOff
        }
    }

    /// Recordings on the ring that aren't on this iphone yet.
    ///
    /// `offlineMuseCount` is exact only while a file list is in hand. Without one it is the
    /// ring's raw file count, and recordings stay on the ring after they come in (Treaty has
    /// no per-file delete), so it counts every one of them. Use the last exact count instead,
    /// plus anything recorded since: files only pile up until the ring is cleared.
    private func waiting(_ ble: RingBLEManager, link: RingStatus.Link) -> Int {
        guard link == .linked else {
            forgetFileList()
            return ble.offlineMuseCount
        }
        let onRing = ble.ringSystemState?.fileCount
        let listing = ble.isListingRingFiles
        let listed = !ble.ringFiles.isEmpty
        defer {
            hadFileList = listed
            wasListing = listing
        }
        if listed, !listing {
            // A list that just finished sets the mark new recordings are counted from.
            if wasListing || !hadFileList || lastKnownWaiting == nil {
                lastKnownFileCount = max(ble.ringFiles.count, onRing ?? 0)
            }
            lastKnownWaiting = ble.unsyncedRingFiles.count
        } else if !listed, !listing, hadFileList {
            // The list emptied without a new one: the ring was cleared (by hand or after a
            // clean sync). Nothing waits; its own count catches up in a beat.
            lastKnownWaiting = 0
            lastKnownFileCount = onRing ?? 0
        } else if !listing, onRing == 0 {
            lastKnownWaiting = 0
            lastKnownFileCount = 0
        }
        guard let lastKnownWaiting else { return ble.offlineMuseCount }
        return lastKnownWaiting + max(0, (onRing ?? lastKnownFileCount) - lastKnownFileCount)
    }

    /// The link dropped or the ring was removed: the next list starts fresh.
    private func forgetFileList() {
        lastKnownWaiting = nil
        lastKnownFileCount = 0
        hadFileList = false
        wasListing = false
    }

    private var isStalled: Bool {
        guard let connectingSince else { return false }
        return Date.now.timeIntervalSince(connectingSince) >= Self.stallAfter
    }

    /// Starts the 12 s clock when the manager enters `.connecting`, and refreshes when it
    /// runs out so a stuck link turns into "away".
    private func trackConnecting(_ state: RingConnectionState) {
        guard state == .connecting else {
            connectingSince = nil
            stallCheck?.cancel()
            stallCheck = nil
            return
        }
        guard connectingSince == nil else { return }
        connectingSince = .now
        stallCheck?.cancel()
        stallCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallAfter))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func freeStorage(_ ble: RingBLEManager) -> Int? {
        if let live = ble.ringSystemState?.freeStoragePercent {
            if defaults?.object(forKey: Self.freeStorageKey) as? Int != live {
                defaults?.set(live, forKey: Self.freeStorageKey)
            }
            return live
        }
        return defaults?.object(forKey: Self.freeStorageKey) as? Int
    }

    /// A name the ring itself advertised ("Museo_47cf", or "Muse_47cf" before 10.14), not
    /// the manager's "muse ring" placeholder.
    private static func isAdvertisedName(_ name: String) -> Bool {
        name.hasPrefix("Museo_") || name.hasPrefix("Muse_")
    }

    private func setupNote(_ setup: RingSetup) -> String? {
        if let error = setup.setupError { return error }
        guard setup.pickerFoundNothing else { return nil }
        return "no ring answered. click it 6 to 7 times to wake it, then try again."
    }
}
