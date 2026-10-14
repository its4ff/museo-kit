import Foundation

/// Everything a ring screen can ask for, as closures, so ring views stay previewable and
/// lab screens never need a ring.
///
/// ```swift
/// RingSheet(status: ring.status,
///           actions: .live(openFirmware: { router.open(.firmware) }),
///           events: RingSetup.shared.events)
/// RingSheet(status: .syncing, actions: .preview, events: [])   // lab
/// ```
public struct RingActions {
    /// "set up your ring": iOS's accessory sheet. With AccessorySetupKit off (the
    /// `NSAccessorySetup*` keys removed from the app's Info.plist) it falls back to a plain
    /// scan and connects the closest ring that answers.
    public var setUp: () -> Void
    /// "look for it": reconnect a ring that's set up but away or disconnected.
    public var lookForIt: () -> Void
    /// "disconnect": drop the link, keep the ring set up.
    public var disconnect: () -> Void
    /// "remove ring": off this iphone for every app, then forgotten here.
    public var remove: () -> Void
    /// iOS's rename sheet (only when `status.canRename`).
    public var rename: () -> Void
    /// "bring them in": sync recordings waiting on the ring.
    public var syncNow: () -> Void
    /// Wipe the ring's storage. Confirm first: it can't be undone.
    public var clearStorage: () -> Void
    /// Open the firmware updater (your app decides how).
    public var openFirmware: () -> Void
    /// "bring recordings in on their own".
    public var setAutoSync: (Bool) -> Void
    /// "clear the ring once they're safe".
    public var setAutoClear: (Bool) -> Void
    /// Ask the ring for a fresh battery level, storage state and file list (a ring sheet
    /// calls it on appear).
    public var refresh: () -> Void

    public init(
        setUp: @escaping () -> Void = {},
        lookForIt: @escaping () -> Void = {},
        disconnect: @escaping () -> Void = {},
        remove: @escaping () -> Void = {},
        rename: @escaping () -> Void = {},
        syncNow: @escaping () -> Void = {},
        clearStorage: @escaping () -> Void = {},
        openFirmware: @escaping () -> Void = {},
        setAutoSync: @escaping (Bool) -> Void = { _ in },
        setAutoClear: @escaping (Bool) -> Void = { _ in },
        refresh: @escaping () -> Void = {}
    ) {
        self.setUp = setUp
        self.lookForIt = lookForIt
        self.disconnect = disconnect
        self.remove = remove
        self.rename = rename
        self.syncNow = syncNow
        self.clearStorage = clearStorage
        self.openFirmware = openFirmware
        self.setAutoSync = setAutoSync
        self.setAutoClear = setAutoClear
        self.refresh = refresh
    }

    /// The real thing, once `Museo.start` has run. Before that (lab screens, previews) it
    /// does nothing, like `.preview`.
    public static func live(openFirmware: @escaping () -> Void) -> RingActions {
        guard let ble = Museo.manager else { return RingActions(openFirmware: openFirmware) }
        let setup = RingSetup.shared
        return RingActions(
            setUp: { setup.showPicker() },
            lookForIt: { setup.lookForRing() },
            disconnect: { setup.disconnect() },
            remove: { setup.remove() },
            rename: { setup.rename() },
            syncNow: { ble.syncOfflineRecordings() },
            clearStorage: { ble.clearRingStorage() },
            openFirmware: openFirmware,
            setAutoSync: { on in
                ble.autoSyncOfflineRecordings = on
                if on { ble.startOfflineSyncIfNeeded() }
            },
            setAutoClear: { on in ble.autoClearRingStorage = on },
            refresh: {
                guard ble.isConnected else { return }
                ble.readBatteryLevel()
                ble.requestSystemState()
                // A fresh list makes "waiting" exact: without one it counts recordings that
                // already came in. Auto sync lists on its own check-in, and a second list
                // in flight would make it skip that sync.
                if !ble.autoSyncOfflineRecordings, ble.canTransferOfflineFiles, !ble.isOfflineSyncBusy {
                    ble.requestRingFileList()
                }
            }
        )
    }

    /// Does nothing. For lab screens and previews.
    public static let preview = RingActions()
}
