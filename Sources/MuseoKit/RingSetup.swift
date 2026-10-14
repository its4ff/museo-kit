import AccessorySetupKit
import Combine
// CBUUID only, to build the AccessorySetupKit descriptor (ASDiscoveryDescriptor.bluetoothServiceUUID
// is a CBUUID). Never CBCentralManager, GATT, Treaty or raw BLE here: RingBLEManager owns all of that.
import CoreBluetooth
import Foundation
import MuseoCore
import Observation
import UIKit

/// Sets the ring up with iOS's own accessory sheet (AccessorySetupKit), and keeps what iOS
/// says this app may use in step with `RingBLEManager`.
///
/// Port of muse OS / museum `MuseAccessorySetup`, to `@Observable`, talking to the ring only
/// through `RingBLEManager`'s public API (`connect(ringID:)`, `connect(to:)`, `reconnectPreferred()`,
/// `disconnect()`, `forgetPreferredRing()`, `stopPickerScan()`).
///
/// How a ring gets set up:
/// 1. `showPicker()` opens the system sheet (service `0004`, name `Muse_`).
/// 2. iOS pairs the ring and sends `accessoryAdded`. The id is held until the sheet is gone,
///    so the link never races the system pair UI.
/// 3. On `pickerDidDismiss`, the id goes to `ble.connect(ringID:)`. If CoreBluetooth can't
///    retrieve it yet, the manager scans; this class watches `discoveredRings` and connects
///    when it shows, for up to 20 s.
///
/// AccessorySetupKit puts the app in "ASK mode": no bluetooth prompt, and CoreBluetooth only
/// sees rings set up through the sheet. Rings paired the old way are not migrated: a known ring
/// with no accessory behind it is forgotten and the app asks to set it up again.
///
/// Without AccessorySetupKit (remove the three `NSAccessorySetup*` keys from `Info.plist`),
/// `isEnabled` is false and `showPicker()` falls back to a plain scan: `ble.scan()`, then it
/// connects the closest ring that answers within 20 s. A known ring reconnects with
/// `ble.reconnectPreferred()`. The app then asks for bluetooth permission the usual way.
@MainActor
@Observable
public final class RingSetup {
    public static let shared = RingSetup()

    /// The Info.plist declares AccessorySetupKit (`NSAccessorySetupKitSupports` has `Bluetooth`).
    nonisolated public static var isEnabled: Bool { declaresAccessorySetup }

    /// What the picker matches. Both must also be in Info.plist
    /// (`NSAccessorySetupBluetoothServices`, `NSAccessorySetupBluetoothNames`) or iOS refuses.
    nonisolated static let ringService = "0004"
    nonisolated static let ringNamePrefix = "Muse_"
    /// How long a handoff or "look for it" watches a scan for the ring before giving up.
    nonisolated static let lookWindow: TimeInterval = 20

    /// AccessorySetupKit has said which rings this app may use. Before this, "not set up"
    /// and "set up" can't be told apart.
    public private(set) var isReady = false
    /// The system sheet is on screen.
    public private(set) var isPickerVisible = false
    /// The last picker (or plain scan) closed with no ring set up.
    public private(set) var pickerFoundNothing = false
    /// Why the last setup, removal or rename didn't happen, in the house voice.
    public internal(set) var setupError: String?
    /// The ring iOS lets this app use, as CoreBluetooth knows it.
    public private(set) var authorizedRingID: UUID?
    /// Its name in iOS ("muse ring", or what the person renamed it to).
    public private(set) var authorizedName: String?
    /// The last 50 setup events, "HH:mm:ss.SSS event detail", for the ring console.
    public private(set) var events: [String] = []

    /// A handoff or "look for it" is waiting for the ring to answer.
    public private(set) var isLinking = false
    /// Plain mode only: scanning for a ring to set up.
    public private(set) var isSearching = false
    /// "disconnect" was tapped. Nothing reconnects until "look for it" or "set up".
    public private(set) var userDisconnected = false
    /// iOS showed its rename sheet and the ring turned the name down.
    public private(set) var renameUnsupported = false
    /// Asked for, not on screen yet.
    public private(set) var expectingPicker = false

    /// The picker is asked for or on screen.
    public var isPickerInFlight: Bool { isPickerVisible || expectingPicker }

    /// iOS can rename the ring: it was set up through AccessorySetupKit by this app.
    public var canRename: Bool { Self.isEnabled && authorizedAccessory != nil && !renameUnsupported }

    /// The event log as one block of text, for copying.
    public var logText: String { events.joined(separator: "\n") }

    @ObservationIgnored private weak var ble: RingBLEManager?
    @ObservationIgnored private var session: ASAccessorySession?
    @ObservationIgnored private var accessories: [ASAccessory] = []
    /// Added while the sheet was up: handed to the ring manager when it's gone.
    @ObservationIgnored private var pendingAddedID: UUID?
    /// After an empty picker, the next one matches service `0004` only.
    @ObservationIgnored private var dropNameFilterNext = false
    /// The ring a scan should connect to when it shows up.
    @ObservationIgnored private var pendingConnectID: UUID?
    @ObservationIgnored private var lookTask: Task<Void, Never>?
    @ObservationIgnored private var pickTask: Task<Void, Never>?
    @ObservationIgnored private var lastState: RingConnectionState?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    /// Asked for while AccessorySetupKit was down (invalidated, or not activated yet).
    /// Runs on the next `.activated`, so nothing falls back to a local-only forget.
    @ObservationIgnored private var pendingAction: PendingAction?
    /// Fresh sessions started right after an invalidation, since the last `.activated`.
    /// One at most, so a session that can't activate never loops.
    @ObservationIgnored private var quickReactivations = 0

    private enum PendingAction { case setUp, remove, rename }

    private init() {}

    // MARK: - Start

    /// Once, at launch (`Museo.start` does it). Activates AccessorySetupKit and starts
    /// watching the ring manager. Calling it again with the same manager does nothing.
    func start(with ble: RingBLEManager) {
        guard self.ble !== ble else { return }
        self.ble = ble
        subscriptions.removeAll()
        lastState = ble.state

        // @Published fires before the change lands, so read the manager a turn later.
        ble.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &subscriptions)
        ble.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in if connected { self?.linkCameUp() } }
            .store(in: &subscriptions)
        ble.$discoveredRings
            .map { $0.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.ringsChanged() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.becameActive() }
            .store(in: &subscriptions)

        if Self.isEnabled {
            activate()
        } else {
            log("plain bluetooth", "no accessory setup keys in Info.plist")
        }
    }

    // MARK: - Actions

    /// "set up your ring". Opens iOS's accessory sheet, or the plain scan when
    /// AccessorySetupKit is off. A ring that's already set up is looked for instead:
    /// the sheet can't list a ring this app already has.
    func showPicker() {
        if let ble, ble.isFirmwareUpdateInProgress { return }
        guard Self.isEnabled else {
            startPlainSetup()
            return
        }
        // Until AccessorySetupKit answers, "not set up" and "set up" look alike. Wait for
        // it; `.activated` carries on from here. (Not `lookForRing()`: with the session
        // down it waits too, and the two must never call each other.)
        guard isReady else {
            waitForSession(.setUp)
            return
        }
        if authorizedRingID != nil {
            lookForRing()
            return
        }
        // One sheet at a time; a second ask would drop a ring added in the first.
        guard !isPickerInFlight else { return }
        activate()
        let matchName = !dropNameFilterNext
        dropNameFilterNext = false
        setupError = nil
        pickerFoundNothing = false
        pendingAddedID = nil
        userDisconnected = false
        stopLooking()
        expectingPicker = true
        if let ble, ble.state == .scanning { ble.stopPickerScan() }
        log("picker", "uuid=\(Self.ringService) name=\(matchName ? Self.ringNamePrefix : "any") hid=true pairingLE=true")
        presentPicker(matchName: matchName, retryOnBusy: true)
    }

    /// "look for it": a ring that's set up but away, slow, or disconnected by hand.
    func lookForRing() {
        guard let ble, !ble.isFirmwareUpdateInProgress else { return }
        // Already linked: reconnecting would tear down a working session.
        guard !ble.isConnected else { return }
        userDisconnected = false
        setupError = nil
        if Self.isEnabled, isReady, let id = authorizedRingID, ble.preferredPeripheralID != id {
            handOff(id)
            return
        }
        guard let id = ble.preferredPeripheralID else {
            if Self.isEnabled, authorizedRingID != nil || !isReady {
                waitForSession(.setUp)
                return
            }
            showPicker()
            return
        }
        log("look", Self.short(id))
        ble.reconnectPreferred()
        watch(id)
    }

    /// "disconnect": drops the link and keeps the ring set up. Nothing reconnects on its
    /// own until "look for it" (or the next launch).
    func disconnect() {
        guard let ble else { return }
        stopLooking()
        userDisconnected = true
        log("disconnect")
        ble.disconnect()
    }

    /// "remove ring": takes the ring off this iphone for every app (iOS asks first when
    /// another app shares it), then forgets it in the ring manager.
    func remove() {
        stopLooking()
        userDisconnected = false
        pickerFoundNothing = false
        setupError = nil
        guard Self.isEnabled else {
            log("forget", "plain bluetooth")
            ble?.forgetPreferredRing()
            return
        }
        // Forgetting it here alone would leave it authorized in iOS, and the next
        // `.activated` would hand it straight back. Remove it for real once the session's up.
        guard isReady, let session else {
            waitForSession(.remove)
            return
        }
        guard let accessory = authorizedAccessory else {
            log("forget", "no accessory behind it")
            ble?.forgetPreferredRing()
            return
        }
        log("remove", accessory.bluetoothIdentifier.map(Self.short) ?? accessory.displayName)
        Task {
            do {
                try await session.removeAccessory(accessory)
                refreshAccessories()
                ble?.forgetPreferredRing()
                log("removed")
            } catch {
                log("remove failed", Self.describe(error))
                if Self.code(of: error) == .userCancelled { return }
                setupError = "couldn't remove the ring · \(error.localizedDescription.kitQuiet)"
            }
        }
    }

    /// iOS's rename sheet. The new name shows in Settings › Bluetooth and here.
    func rename() {
        guard Self.isEnabled else { return }
        guard isReady, let session else {
            waitForSession(.rename)
            return
        }
        guard let accessory = authorizedAccessory else { return }
        log("rename")
        Task {
            do {
                try await session.renameAccessory(accessory, options: [])
                setupError = nil
                refreshAccessories()
                log("renamed", authorizedName ?? "")
            } catch {
                log("rename failed", Self.describe(error))
                if Self.code(of: error) == .userCancelled { return }
                renameUnsupported = true
                setupError = "this ring can't be renamed here"
            }
        }
    }

    /// The one place that keeps AccessorySetupKit and the ring manager agreeing. Runs when
    /// AccessorySetupKit activates, when the picker closes, on every return to the app and
    /// when bluetooth comes back.
    ///
    /// - A ring set up the old way (known to the manager, no accessory behind it) is forgotten.
    /// - The accessory's id goes to the manager when it isn't the one it remembers.
    /// Everything else (reconnecting a known ring) the manager does on its own.
    func reconcile() {
        guard Self.isEnabled, isReady, !isPickerInFlight else { return }
        guard let ble, !ble.isFirmwareUpdateInProgress else { return }
        guard let id = authorizedRingID else {
            if let known = ble.preferredPeripheralID {
                log("forget", "\(Self.short(known)) was set up without accessory setup")
                ble.forgetPreferredRing()
            }
            return
        }
        if ble.preferredPeripheralID != id {
            handOff(id)
        }
    }

    /// Back in the app. If iOS invalidated the AccessorySetupKit session while we were away,
    /// start a new one (its `.activated` reconciles); otherwise reconcile now.
    private func becameActive() {
        if Self.isEnabled, session == nil, ble != nil {
            activate()
        } else {
            reconcile()
        }
    }

    // MARK: - AccessorySetupKit

    private func activate() {
        guard Self.isEnabled, session == nil else { return }
        let session = ASAccessorySession()
        self.session = session
        log("activate")
        // Events arrive on the main queue.
        session.activate(on: .main) { [weak self] event in
            self?.handle(event)
        }
    }

    /// AccessorySetupKit is down or still activating: start it if needed and run `action`
    /// once it says `.activated`. The latest ask wins.
    private func waitForSession(_ action: PendingAction) {
        pendingAction = action
        log("waiting for accessory setup", "\(action)")
        activate()
    }

    /// Runs what was asked for while the session was down, then keeps the ring in step.
    private func sessionActivated() {
        let action = pendingAction
        pendingAction = nil
        switch action {
        case .remove:
            // Not reconcile first: it would hand the ring back before it's removed.
            remove()
        case .rename:
            rename()
            reconcile()
        case .setUp:
            reconcile()
            if authorizedRingID == nil {
                showPicker()
            } else if !isLinking {
                lookForRing()
            }
        case nil:
            reconcile()
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        var detail = "accessories=\(session?.accessories.count ?? 0)"
        if let accessory = event.accessory {
            detail += " name=\(accessory.displayName) state=\(Self.describe(accessory.state))"
            if let id = accessory.bluetoothIdentifier { detail += " id=\(Self.short(id))" }
        }
        if let error = event.error { detail += " err=\(Self.describe(error))" }
        log(Self.describe(event.eventType), detail)

        switch event.eventType {
        case .activated:
            refreshAccessories()
            isReady = true
            quickReactivations = 0
            sessionActivated()

        case .accessoryChanged, .migrationComplete:
            refreshAccessories()

        case .accessoryAdded:
            refreshAccessories()
            renameUnsupported = false
            setupError = nil
            pickerFoundNothing = false
            if let id = event.accessory?.bluetoothIdentifier {
                if isPickerInFlight {
                    // Never start the link while the system pair UI is up.
                    pendingAddedID = id
                } else {
                    handOff(id)
                }
            }

        case .accessoryRemoved:
            refreshAccessories()
            if let id = event.accessory?.bluetoothIdentifier, let ble, ble.preferredPeripheralID == id {
                // Removed here, in Settings, or by another app: forget it so nothing relinks.
                stopLooking()
                ble.forgetPreferredRing()
            }

        case .pickerDidPresent:
            isPickerVisible = true

        case .pickerDidDismiss:
            isPickerVisible = false
            pickerClosed()

        case .pickerSetupFailed:
            if let error = event.error, Self.code(of: error) != .userCancelled {
                setupError = "setup didn't finish · \(error.localizedDescription.kitQuiet)"
            }

        case .invalidated:
            session = nil
            isReady = false
            if expectingPicker || isPickerVisible {
                isPickerVisible = false
                pickerClosed()
            }
            // What the dead session said no longer holds: no ring to rename or remove
            // through it. The next `.activated` restores it.
            accessories = []
            refreshAccessories()
            // Still in the app: start a new session now instead of waiting for the next
            // return to it (`becameActive`).
            if UIApplication.shared.applicationState == .active, ble != nil, quickReactivations < 1 {
                quickReactivations += 1
                activate()
            }

        default:
            break
        }
    }

    /// The sheet is gone (dismissed, cancelled or failed). Hands over a ring added during it,
    /// or notes that nothing was set up so the next sheet drops the name filter.
    private func pickerClosed() {
        expectingPicker = false
        if let id = pendingAddedID {
            pendingAddedID = nil
            handOff(id)
            return
        }
        if authorizedRingID == nil {
            pickerFoundNothing = true
            dropNameFilterNext = true
        }
        reconcile()
    }

    private func refreshAccessories() {
        accessories = session?.accessories ?? []
        let accessory = authorizedAccessory
        let id = accessory?.bluetoothIdentifier
        if authorizedRingID != id { authorizedRingID = id }
        let name = accessory.map(\.displayName).flatMap { $0.isEmpty ? nil : $0 }
        if authorizedName != name { authorizedName = name }
    }

    /// The ring iOS lets this app use: an authorized one first.
    private var authorizedAccessory: ASAccessory? {
        accessories.first { $0.state == .authorized && $0.bluetoothIdentifier != nil }
            ?? accessories.first { $0.bluetoothIdentifier != nil }
    }

    private func presentPicker(matchName: Bool, retryOnBusy: Bool) {
        guard let session else { return }
        let items = Self.pickerItems(matchName: matchName)
        Task {
            do {
                try await session.showPicker(for: items)
            } catch {
                pickerFailed(error, matchName: matchName, retryOnBusy: retryOnBusy)
                return
            }
            // Shown without an error. If the sheet never says it appeared, stop waiting for
            // it so returning to the app keeps the ring in step.
            try? await Task.sleep(for: .seconds(5))
            if expectingPicker, !isPickerVisible {
                log("picker", "never appeared")
                pickerClosed()
            }
        }
    }

    private func pickerFailed(_ error: any Error, matchName: Bool, retryOnBusy: Bool) {
        log("picker error", Self.describe(error))
        switch Self.code(of: error) {
        case .pickerRestricted where retryOnBusy:
            // The app wasn't frontmost yet, or a bluetooth central was still settling.
            // Both clear within a beat.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                presentPicker(matchName: matchName, retryOnBusy: false)
            }
        case .pickerAlreadyActive:
            // A sheet is already up. That one carries on.
            break
        case .userCancelled:
            // May arrive without pickerDidDismiss.
            if !isPickerVisible { pickerClosed() }
        case .pickerRestricted:
            expectingPicker = false
            setupError = "the ring sheet couldn't open. close the app, open it again, then set up."
        case .userRestricted:
            expectingPicker = false
            setupError = "ring setup is restricted on this iphone"
        default:
            expectingPicker = false
            setupError = "the ring sheet didn't open · \(error.localizedDescription.kitQuiet)"
        }
    }

    private static func pickerItems(matchName: Bool) -> [ASPickerDisplayItem] {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(string: ringService)
        // LE pairing plus HID (play and pause on a tap). Never `.confirmAuthorization` with
        // LE pairing, and never HID service 1812: iOS keeps it from apps.
        descriptor.supportedOptions = [.bluetoothPairingLE, .bluetoothHID]
        if matchName { descriptor.bluetoothNameSubstring = ringNamePrefix }
        // iOS shows another app's name and picture instead when that app set the ring up first.
        return [ASPickerDisplayItem(name: Museo.ringName, productImage: productImage, descriptor: descriptor)]
    }

    private static var productImage: UIImage {
        if let image = UIImage(named: "MuseRingAccessory", in: .module, with: nil) { return image }
        let config = UIImage.SymbolConfiguration(pointSize: 96, weight: .ultraLight)
        return UIImage(systemName: "circle.circle", withConfiguration: config) ?? UIImage()
    }

    // MARK: - Handing the ring to RingBLEManager

    /// Gives the ring manager the ring iOS authorized. `connect(ringID:)` remembers it and
    /// connects, or scans when CoreBluetooth can't retrieve it yet; the scan is watched.
    private func handOff(_ id: UUID) {
        guard let ble, !ble.isFirmwareUpdateInProgress else { return }
        userDisconnected = false
        log("handoff", Self.short(id))
        ble.connect(ringID: id)
        watch(id)
    }

    /// Connects `id` when a scan finds it, for up to `lookWindow` seconds, then stops the scan.
    private func watch(_ id: UUID) {
        pendingConnectID = id
        isLinking = true
        lookTask?.cancel()
        lookTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lookWindow))
            guard !Task.isCancelled else { return }
            self?.lookEnded(id)
        }
        connectIfFound()
    }

    private func lookEnded(_ id: UUID) {
        guard pendingConnectID == id || isLinking else { return }
        pendingConnectID = nil
        isLinking = false
        lookTask = nil
        if let ble, ble.state == .scanning, !isSearching {
            ble.stopPickerScan()
            log("no answer", "stopped looking after \(Int(Self.lookWindow))s")
        }
    }

    private func stopLooking() {
        pendingConnectID = nil
        isLinking = false
        isSearching = false
        lookTask?.cancel()
        lookTask = nil
        pickTask?.cancel()
        pickTask = nil
    }

    private func connectIfFound() {
        guard let ble, let id = pendingConnectID, ble.state == .scanning,
              let ring = ble.discoveredRings.first(where: { $0.id == id }) else { return }
        pendingConnectID = nil
        log("found", "\(ring.name) in a scan, connecting")
        ble.connect(to: ring)
    }

    private func ringsChanged() {
        connectIfFound()
        pickClosestSoon()
    }

    private func stateChanged(_ state: RingConnectionState) {
        let was = lastState
        lastState = state
        switch state {
        case .bluetoothOff:
            if isLinking || isSearching { stopLooking() }
        case .scanning:
            // The manager scans when it can't retrieve a known ring, and never connects
            // from that scan by itself. Watch it for the ring we know.
            if pendingConnectID == nil, !isSearching, !userDisconnected, let ble, let id = ble.preferredPeripheralID {
                watch(id)
            } else {
                connectIfFound()
            }
        default:
            break
        }
        if was == .bluetoothOff, state != .bluetoothOff {
            log("bluetooth back")
            reconcile()
        }
    }

    private func linkCameUp() {
        stopLooking()
        pickerFoundNothing = false
        setupError = nil
        if let ble { log("linked", ble.deviceName) }
    }

    // MARK: - Plain mode (no AccessorySetupKit)

    private func startPlainSetup() {
        guard let ble else { return }
        userDisconnected = false
        if ble.preferredPeripheralID != nil {
            lookForRing()
            return
        }
        stopLooking()
        isSearching = true
        pickerFoundNothing = false
        setupError = nil
        log("plain scan")
        ble.scan()
        lookTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lookWindow))
            guard !Task.isCancelled else { return }
            self?.plainSearchEnded()
        }
        pickClosestSoon()
    }

    /// Once a ring answers, wait a beat for others nearby, then take the closest.
    private func pickClosestSoon() {
        guard isSearching, pickTask == nil, let ble, !ble.discoveredRings.isEmpty else { return }
        pickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.pickClosest()
        }
    }

    private func pickClosest() {
        pickTask = nil
        guard isSearching, let ble, let ring = ble.discoveredRings.max(by: { $0.rssi < $1.rssi }) else { return }
        isSearching = false
        log("plain pick", "\(ring.name) rssi=\(ring.rssi)")
        ble.connect(to: ring)
        watch(ring.id)
    }

    private func plainSearchEnded() {
        guard isSearching else { return }
        stopLooking()
        ble?.stopPickerScan()
        pickerFoundNothing = true
        log("plain scan", "nothing answered")
    }

    // MARK: - Log

    private func log(_ name: String, _ detail: String = "") {
        let line = detail.isEmpty ? name : "\(name) \(detail)"
        print("[museo][setup] \(line)")
        events.append("\(Self.stamp.string(from: .now)) \(line)")
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private nonisolated static let declaresAccessorySetup: Bool = {
        let kinds = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") as? [String] ?? []
        return kinds.contains("Bluetooth")
    }()

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func code(of error: any Error) -> ASError.Code? {
        let error = error as NSError
        guard error.domain == ASError.errorDomain else { return nil }
        return ASError.Code(rawValue: error.code)
    }

    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        guard let code = code(of: error) else { return "\(ns.domain) \(ns.code)" }
        let name: String
        switch code {
        case .success: name = "success"
        case .unknown: name = "unknown"
        case .activationFailed: name = "activationFailed"
        case .connectionFailed: name = "connectionFailed"
        case .discoveryTimeout: name = "discoveryTimeout"
        case .extensionNotFound: name = "extensionNotFound"
        case .invalidated: name = "invalidated"
        case .invalidRequest: name = "invalidRequest"
        case .pickerAlreadyActive: name = "pickerAlreadyActive"
        case .pickerRestricted: name = "pickerRestricted"
        case .userCancelled: name = "userCancelled"
        case .userRestricted: name = "userRestricted"
        @unknown default: name = "code"
        }
        return "\(ns.code) \(name)"
    }

    private static func describe(_ type: ASAccessoryEventType) -> String {
        switch type {
        case .activated: "activated"
        case .invalidated: "invalidated"
        case .accessoryAdded: "accessoryAdded"
        case .accessoryRemoved: "accessoryRemoved"
        case .accessoryChanged: "accessoryChanged"
        case .accessoryDiscovered: "accessoryDiscovered"
        case .migrationComplete: "migrationComplete"
        case .pickerDidPresent: "pickerDidPresent"
        case .pickerDidDismiss: "pickerDidDismiss"
        case .pickerSetupBridging: "pickerSetupBridging"
        case .pickerSetupFailed: "pickerSetupFailed"
        case .pickerSetupPairing: "pickerSetupPairing"
        case .pickerSetupRename: "pickerSetupRename"
        case .unknown: "unknown"
        @unknown default: "event \(type.rawValue)"
        }
    }

    private static func describe(_ state: ASAccessory.AccessoryState) -> String {
        switch state {
        case .unauthorized: "unauthorized"
        case .awaitingAuthorization: "awaitingAuthorization"
        case .authorized: "authorized"
        @unknown default: "other"
        }
    }
}
