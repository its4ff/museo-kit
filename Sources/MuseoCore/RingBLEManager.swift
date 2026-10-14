import AVFoundation
import Combine
import CoreBluetooth
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Ring hardware kit (MuseRing). App code should use RingBLEManager's public API
// only — do not send Treaty frames or add a second BLE stack.

public enum RingConnectionState: String {
    case idle
    case scanning
    case connecting
    case connected
    case disconnected
    case bluetoothOff
    case failed
}

enum MuseCaptureConstants {
    static let opusSampleRate = OpusFormat.sampleRate
    static let opusFrameDuration = Double(OpusFormat.frameDurationMs) / 1000.0
}

public enum CaptureSource: String, Codable {
    /// Streamed live over BLE while the phone was in range.
    case stream
    /// Recorded to the ring's flash and downloaded later.
    case offline
}

/// A finished capture — natural Opus-decoded WAV on disk.
public struct CompletedCapture: Identifiable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let fileName: String
    public let wavFileName: String?
    public let byteCount: Int
    public let packetCount: Int
    public let duration: TimeInterval
    public let sampleRate: Int
    public var source: CaptureSource = .stream
    /// For offline recordings: the ring file this came from. Reported back once
    /// the muse is saved so the recording is only retired when it was kept.
    public var offlineSyncKey: String?
}

public struct DiscoveredRing: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let lastSeen: Date
    let peripheral: CBPeripheral
    /// True when seeded from CoreBluetooth memory / system link rather than a live advertisement.
    public var isKnownLink: Bool = false

    public static func == (lhs: DiscoveredRing, rhs: DiscoveredRing) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.rssi == rhs.rssi
            && lhs.lastSeen == rhs.lastSeen
            && lhs.isKnownLink == rhs.isKnownLink
            && lhs.peripheral.identifier == rhs.peripheral.identifier
    }

    static func isAllowedName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("muse") || lowered.contains("memo")
    }
}

/// Ring BLE, sync, and capture. App code should use this type — not Treaty frames.
public final class RingBLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceUUID = CBUUID(string: "0004")
    private static let opusServiceUUID = CBUUID(string: "0007")
    private static let txUUID = CBUUID(string: "0005")
    private static let rxUUID = CBUUID(string: "0006")
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryCharUUID = CBUUID(string: "2A19")
    private static let preferredKey = "preferredMuseBuildPeripheralID"
    private static let centralRestoreIdentifier = "com.4ff.muse-build.bluetooth-central"
    static let syncedOfflineKeysDefault = "muse.offline.syncedKeys"
    static let autoSyncOfflineDefault = "muse.offline.autoSync"
    static let autoClearRingDefault = "muse.offline.autoClearRing"
    private static let batteryCacheKey = "muse.battery.lastReading"
    /// How long a cached level is worth showing before we'd rather show nothing.
    private static let batteryCacheLifetime: TimeInterval = 60 * 60

    @Published public private(set) var state: RingConnectionState = .idle
    @Published public private(set) var deviceName = "muse ring"
    @Published public private(set) var connectedRingID: UUID?
    @Published public private(set) var rssi: Int?
    @Published public private(set) var batteryPercent: Int?
    @Published public private(set) var batteryIsCharging = false
    /// When the shown level came from the cache rather than a live read this session.
    @Published public private(set) var isBatteryEstimate = false
    @Published public private(set) var batteryReadAt: Date?
    @Published public private(set) var isCapturing = false {
        didSet {
            guard isCapturing != oldValue else { return }
            onCaptureStateChange?(isCapturing, captureStartedAt)
        }
    }
    @Published public private(set) var packetCount = 0
    @Published public private(set) var byteCount = 0
    @Published public private(set) var captureElapsed: TimeInterval = 0
    @Published public private(set) var discoveredRings: [DiscoveredRing] = []
    @Published public private(set) var isScanningNearby = false
    /// Last successfully paired ring — kept across soft disconnect so we can reconnect
    /// even when the ring stops advertising because iOS still holds the link.
    @Published public private(set) var preferredPeripheralID: UUID?
    /// Finished captures waiting to become muses. A queue rather than a single
    /// value because an offline sync can deliver several recordings in a row.
    @Published public private(set) var completedCaptures: [CompletedCapture] = []

    // MARK: Offline sync (ring flash storage)

    // Settable within the module so RingOfflineSync.swift can drive the transfer.
    @Published public var ringSystemState: RingSystemState?
    @Published public var ringIsRecordingOffline = false
    @Published public var ringFiles: [RingFile] = []
    @Published public var isListingRingFiles = false
    @Published public var isSyncingOffline = false {
        didSet {
            guard isSyncingOffline != oldValue else { return }
            if isSyncingOffline {
                onSyncStarted?(max(unsyncedRingFiles.count, 1))
            } else {
                onSyncEnded?()
            }
        }
    }
    @Published public var isDecodingOffline = false
    @Published public var offlineSyncProgress: Double = 0
    @Published public var offlineQueueRemaining = 0 {
        didSet {
            guard offlineQueueRemaining != oldValue, isSyncingOffline else { return }
            onSyncProgress?(offlineQueueRemaining)
        }
    }
    @Published public var activeOfflineFileName: String?
    @Published public var offlineSyncError: String?
    @Published public var autoSyncOfflineRecordings = true {
        didSet {
            guard autoSyncOfflineRecordings != oldValue else { return }
            UserDefaults.standard.set(autoSyncOfflineRecordings, forKey: Self.autoSyncOfflineDefault)
        }
    }
    /// Treaty has no per-file delete, so reclaiming space means formatting the
    /// whole flash — only ever done automatically after a fully clean sync.
    @Published public var autoClearRingStorage = true {
        didSet {
            guard autoClearRingStorage != oldValue else { return }
            UserDefaults.standard.set(autoClearRingStorage, forKey: Self.autoClearRingDefault)
        }
    }

    static var sharedAutoSync: Bool {
        if UserDefaults.standard.object(forKey: autoSyncOfflineDefault) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoSyncOfflineDefault)
    }

    static var sharedPreferredRingID: String? {
        UserDefaults.standard.string(forKey: preferredKey)
    }

    /// Last paired ring id, stored in UserDefaults.
    static func setSharedPreferredRingID(_ id: String) {
        UserDefaults.standard.set(id, forKey: preferredKey)
    }

    /// SMP / MCUboot OTA owns the radio. Treaty must not reconnect until it ends.
    @Published public private(set) var isFirmwareUpdateInProgress = false

    /// Treaty TX/RX are ready. Stored + published so SwiftUI notices when
    /// characteristics arrive (they aren't @Published themselves).
    @Published public private(set) var isConnected = false

    /// Link is up (or coming up) — don't start a fresh discovery that can fight the session.
    public var hasActiveLink: Bool {
        switch state {
        case .connected, .connecting: return true
        default: return false
        }
    }

    /// Show battery chrome whenever the peripheral link is up, even before Treaty settles.
    public var showsBattery: Bool {
        state == .connected || isConnected
    }

    private func refreshConnectionFlags() {
        let ready = state == .connected
            && peripheral != nil
            && txCharacteristic != nil
            && rxCharacteristic != nil
        if isConnected != ready {
            isConnected = ready
        }
    }

    /// When true, live audio still runs but no muse is saved.
    @Published public var suppressMuseCardCaptures = false
    /// Fired when a live capture ends after about 1.4s of silence.
    package var onLiveCaptureEnd: (() -> Void)?
    /// App-owned Live Activity hooks. Hardware never imports WidgetKit.
    package var onCaptureStateChange: ((Bool, Date?) -> Void)?
    package var onSyncStarted: ((Int) -> Void)?
    package var onSyncEnded: (() -> Void)?
    package var onSyncProgress: ((Int) -> Void)?
    /// Extra listeners on the Opus stream. Keyed so more than one can share it. MuseoKit's
    /// `Museo.liveAudio()` is the one that uses it; apps never add a tap themselves.
    private var audioTaps: [String: (_ packet: Data, _ isCaptureStart: Bool) -> Void] = [:]

    package func addAudioTap(id: String, _ tap: @escaping (_ packet: Data, _ isCaptureStart: Bool) -> Void) {
        audioTaps[id] = tap
    }

    package func removeAudioTap(id: String) {
        audioTaps.removeValue(forKey: id)
    }

    public static var capturesDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MuseBuildCaptures", isDirectory: true)
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var sequence: UInt16 = 1
    private let frameDecoder = TreatyFrameDecoder()
    private var didRunProtocolStartup = false
    /// Reset per connection — see `handleRecordBitratePayload`.
    private var didCorrectBitrate = false
    /// Reset per connection — see `handleRecordParams`.
    private var didResetNoiseReduction = false

    /// The ring's stored noise reduction and AGC values, as it last said (`0x1C`, answered by
    /// `0x1E`). Nil until it answers. For tools like a console: in testing (2026-10-14) neither
    /// value changed a recording, so the kit keeps noise reduction at 0 and leaves AGC alone.
    @Published public private(set) var recordingSound: RingRecordingSound?
    private var userRequestedDisconnect = false
    private var firmwareDisconnectContinuations: [CheckedContinuation<Void, Never>] = []
    private var scanFallbackWorkItem: DispatchWorkItem?
    private var didDiscoverDuringCurrentScan = false
    /// Caps SwiftUI updates while a ring is advertising. New rings still
    /// publish immediately; RSSI churn waits a beat.
    private var lastDiscoveryPublishAt = Date.distantPast
    private static let discoveryPublishInterval: TimeInterval = 0.35
    private static let rssiPublishDelta = 4

    // Opus capture state
    private var captureByStream: [String: [Data]] = [:]
    private var captureStartedAt: Date?

    /// When the live capture began, for the Live Activity that mirrors it.
    public var activeCaptureStartedAt: Date? { captureStartedAt }
    private var isAutoCapturing = false
    private var autoCaptureStopTimer: Timer?
    private var captureTimer: Timer?
    private var rssiTimer: Timer?
    private var batteryTimer: Timer?
    private var nearbyScanTimer: Timer?
    private var recordingStartedAt: Date?
    private var ringIsRecording = false
    let decodeQueue = DispatchQueue(label: "muse.build.opus.decode", qos: .userInitiated)
    private let opusStreamID = "0007/0009"

    // Offline transfer state. Internal so RingOfflineSync.swift can drive it.
    var offlineDownloads: [String: OfflineDownload] = [:]
    var offlineQueue: [RingFile] = []
    var activeOfflineKey: String?
    var expectedRingFileCount = 0
    var pendingOfflineSync = false
    var awaitingTransferEndStatus = false
    var syncedOfflineKeys: Set<String> = []
    /// Recordings that failed to decode this session — skipped so they can't
    /// block the queue, but deliberately not persisted as synced.
    var undecodableOfflineKeys: Set<String> = []
    var offlineTimeoutTimer: Timer?
    var fileListTimer: Timer?
    var autoSyncWorkItem: DispatchWorkItem?
    var lastAutoSyncAt: Date?
    #if canImport(UIKit)
    var offlineBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    public override init() {
        super.init()
        preferredPeripheralID = UserDefaults.standard.string(forKey: Self.preferredKey).flatMap(UUID.init(uuidString:))
        syncedOfflineKeys = Set(UserDefaults.standard.stringArray(forKey: Self.syncedOfflineKeysDefault) ?? [])
        if UserDefaults.standard.object(forKey: Self.autoSyncOfflineDefault) != nil {
            autoSyncOfflineRecordings = UserDefaults.standard.bool(forKey: Self.autoSyncOfflineDefault)
        }
        if UserDefaults.standard.object(forKey: Self.autoClearRingDefault) != nil {
            autoClearRingStorage = UserDefaults.standard.bool(forKey: Self.autoClearRingDefault)
        }
        if preferredPeripheralID != nil {
            startCentral()
        }
    }
    /// A scan asked for while the central was still waking up (first run:
    /// right as the permission prompt appears). Resumed on poweredOn.
    private var scanPending = false

    private func startCentral() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
    }

    /// True when the central is powered on. Nil before `startCentral()` —
    /// that is "not started yet", not "bluetooth off".
    private var centralPoweredOn: Bool {
        central?.state == .poweredOn
    }

    // MARK: - Connection

    public func scan() {
        // First BLE use creates the central, which also shows the permission prompt.
        startCentral()
        guard let central else {
            state = .idle
            return
        }
        guard central.state != .unknown else {
            // Just created: the state callback lands in a beat (after the
            // permission answer on first run) — scan when it does.
            scanPending = true
            return
        }
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            return
        }

        if hasActiveLink {
            scanNearbyWhileConnected()
            return
        }

        if state != .scanning {
            discoveredRings.removeAll()
        }
        seedKnownPeripherals()
        state = .scanning
        isScanningNearby = false
        stopNearbyScanTimer()
        startDiscoveryScan()
    }

    private func scanNearbyWhileConnected() {
        discoveredRings.removeAll { $0.id != connectedRingID }
        seedKnownPeripherals()
        isScanningNearby = true
        startDiscoveryScan()
        stopNearbyScanTimer()
        nearbyScanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.finishNearbyScan()
        }
    }

    /// Rings already linked at the system level often stop advertising, so a
    /// normal scan can't see them. Pull them from CoreBluetooth memory instead.
    private func seedKnownPeripherals() {
        guard let central, centralPoweredOn else { return }

        let connected = central.retrieveConnectedPeripherals(withServices: [
            Self.serviceUUID,
            Self.opusServiceUUID,
            Self.batteryServiceUUID
        ])
        for peripheral in connected {
            upsertKnown(
                peripheral,
                name: peripheral.name ?? "muse ring",
                rssi: -45
            )
        }

        if let preferredPeripheralID {
            for peripheral in central.retrievePeripherals(withIdentifiers: [preferredPeripheralID]) {
                upsertKnown(
                    peripheral,
                    name: peripheral.name ?? deviceName,
                    rssi: peripheral.state == .connected ? -40 : -60
                )
            }
        }
    }

    private func upsertKnown(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        if let connectedRingID, peripheral.identifier == connectedRingID { return }
        let displayName = name.isEmpty ? "muse ring" : name
        let ring = DiscoveredRing(
            id: peripheral.identifier,
            name: displayName,
            rssi: rssi,
            lastSeen: Date(),
            peripheral: peripheral,
            isKnownLink: true
        )
        if let index = discoveredRings.firstIndex(where: { $0.id == ring.id }) {
            // Prefer a live advertisement RSSI if we already have one.
            if discoveredRings[index].isKnownLink {
                discoveredRings[index] = ring
            }
        } else {
            discoveredRings.append(ring)
        }
        discoveredRings.sort { $0.rssi > $1.rssi }
    }

    /// Prefer Treaty service discovery, but fall back because current 54L15
    /// advertising data has not been proven to include service 0x0004.
    /// Do not use AllowDuplicates: every advert republishes `discoveredRings`
    /// and that firehose has crashed SwiftUI while the picker sheet presents.
    private func startDiscoveryScan() {
        guard let central else { return }
        scanFallbackWorkItem?.cancel()
        didDiscoverDuringCurrentScan = false
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)

        let fallback = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.didDiscoverDuringCurrentScan,
                  self.state == .scanning || self.isScanningNearby,
                  let central = self.central else { return }
            central.stopScan()
            central.scanForPeripherals(withServices: nil, options: nil)
            print("[muse][ble] Treaty service scan found nothing; using broad discovery fallback")
        }
        scanFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
    }

    private func finishNearbyScan() {
        guard isScanningNearby else { return }
        central?.stopScan()
        isScanningNearby = false
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
        stopNearbyScanTimer()
    }

    func finishNearbyScanIfActive() {
        finishNearbyScan()
    }

    /// Stop a scan started by the device picker. A linked session only drops
    /// the nearby look; a discovery scan goes back to idle or disconnected.
    public func stopPickerScan() {
        if hasActiveLink {
            finishNearbyScanIfActive()
            return
        }
        guard state == .scanning else { return }
        central?.stopScan()
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
        isScanningNearby = false
        stopNearbyScanTimer()
        state = preferredPeripheralID != nil ? .disconnected : .idle
    }

    private func stopNearbyScanTimer() {
        nearbyScanTimer?.invalidate()
        nearbyScanTimer = nil
    }

    public func connect(to ring: DiscoveredRing) {
        connect(to: ring.peripheral, name: ring.name, rssi: ring.rssi, remember: true)
    }

    /// Connect by identifier when the peripheral object is not in hand yet.
    public func connect(ringID: UUID) {
        // Central may not exist yet. Remember the ring; poweredOn reconnects.
        if central == nil {
            preferredPeripheralID = ringID
            UserDefaults.standard.set(ringID.uuidString, forKey: Self.preferredKey)
            startCentral()
            return
        }
        guard let central, centralPoweredOn else {
            state = .bluetoothOff
            return
        }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [ringID]).first else {
            print("[muse][ble] authorized ring \(ringID) not retrievable yet; scanning")
            preferredPeripheralID = ringID
            UserDefaults.standard.set(ringID.uuidString, forKey: Self.preferredKey)
            scan()
            return
        }
        connect(to: peripheral, name: peripheral.name ?? deviceName, rssi: nil, remember: true)
    }

    public func reconnectPreferred() {
        guard let central, centralPoweredOn else {
            state = self.central == nil ? .idle : .bluetoothOff
            return
        }
        guard let preferredPeripheralID else {
            scan()
            return
        }

        // Prefer an already-system-connected peripheral — common after an app-level disconnect.
        let systemLinked = central.retrieveConnectedPeripherals(withServices: [
            Self.serviceUUID,
            Self.opusServiceUUID,
            Self.batteryServiceUUID
        ])
        if let linked = systemLinked.first(where: { $0.identifier == preferredPeripheralID })
            ?? systemLinked.first {
            connect(to: linked, name: linked.name ?? deviceName, rssi: nil, remember: true)
            return
        }

        let peripherals = central.retrievePeripherals(withIdentifiers: [preferredPeripheralID])
        guard let peripheral = peripherals.first else {
            scan()
            return
        }
        connect(to: peripheral, name: peripheral.name ?? deviceName, rssi: nil, remember: false)
    }

    private func connect(to peripheral: CBPeripheral, name: String, rssi: Int?, remember: Bool) {
        finishNearbyScan()
        guard let central else { return }
        central.stopScan()
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
        userRequestedDisconnect = false
        if let current = self.peripheral, current.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(current)
        }
        self.peripheral = peripheral
        self.rssi = rssi
        deviceName = name
        state = .connecting
        isConnected = false
        peripheral.delegate = self
        frameDecoder.reset()
        didRunProtocolStartup = false
        didCorrectBitrate = false
        didResetNoiseReduction = false
        txCharacteristic = nil
        rxCharacteristic = nil
        central.connect(
            peripheral,
            options: [CBConnectPeripheralOptionEnableAutoReconnect: true]
        )
        if remember {
            preferredPeripheralID = peripheral.identifier
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.preferredKey)
        }
    }

    /// Drop Treaty so Nordic's McuMgr central can take the SMP service.
    /// Returns the ring UUID the updater should reconnect to.
    public func prepareForFirmwareUpdate() async -> UUID? {
        let ringID = connectedRingID ?? peripheral?.identifier ?? preferredPeripheralID
        isFirmwareUpdateInProgress = true
        userRequestedDisconnect = true
        autoSyncWorkItem?.cancel()
        abortOfflineSync()

        let linkUp: Bool = {
            if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
                return true
            }
            switch state {
            case .connected, .connecting: return true
            default: return false
            }
        }()

        if linkUp {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                firmwareDisconnectContinuations.append(continuation)
                disconnect()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.resumeFirmwareDisconnectWaiters()
                }
            }
        }

        return ringID
    }

    public func finishFirmwareUpdate() {
        isFirmwareUpdateInProgress = false
        userRequestedDisconnect = false
        reconnectPreferred()
    }

    private func resumeFirmwareDisconnectWaiters() {
        guard !firmwareDisconnectContinuations.isEmpty else { return }
        let waiters = firmwareDisconnectContinuations
        firmwareDisconnectContinuations.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Soft disconnect — drops the app session but keeps the preferred ring so
    /// reconnect works even when the ring is still held by iOS and not advertising.
    public func disconnect() {
        userRequestedDisconnect = true
        finishNearbyScan()
        if isCapturing {
            stopAudioCapture(saveCard: !suppressMuseCardCaptures)
        }
        abortOfflineSync()

        let connectedPeripheral = peripheral
        if isProtocolReady {
            send(.setRecord, payload: Data([0x00]))
            print("[muse][ble] recording stopped before disconnect (0x17=0)")
        }

        if let connectedPeripheral {
            // Give the queued Treaty write a brief chance to reach the ring before
            // CoreBluetooth tears down the link.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, connectedPeripheral] in
                guard let self else { return }
                self.central?.cancelPeripheralConnection(connectedPeripheral)
            }
        }
        stopTimers()
        peripheral = nil
        connectedRingID = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        isConnected = false
        state = .disconnected
        seedKnownPeripherals()
    }

    /// Forget the remembered ring. Also drops any connect request iOS is still
    /// holding for it, which would otherwise silently re-link the ring later.
    public func forgetPreferredRing() {
        userRequestedDisconnect = true
        if let ringID = preferredPeripheralID {
            clearBondMark(for: ringID)
        }
        UserDefaults.standard.removeObject(forKey: Self.preferredKey)
        preferredPeripheralID = nil
        if hasActiveLink {
            disconnect()
        } else if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
    }

    // MARK: - Treaty

    var isProtocolReady: Bool {
        peripheral != nil && txCharacteristic != nil && rxCharacteristic != nil
    }

    // MARK: - Pairing (Treaty 0x19 + bind check 0x14/0x15)

    /// Rings this phone has bonded. The LE bond (needed for HID play/pause/skip)
    /// only forms after Treaty 0x19 asks iOS to pair, and only counts once the
    /// ring confirms it. A mark here means bonded at some point, not still bonded.
    private static let bondedRingsKey = "muse.bondedRings"

    private var bondedRingIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.bondedRingsKey) ?? [])
    }

    /// The ring confirmed the LE bond this connection (bindCheckAck).
    @Published private(set) var isBondConfirmed = false

    /// The iOS bond record is dead. More 0x19 asks will not fix it.
    /// Forget the ring in the picker and pair again.
    @Published private(set) var needsHardRepair = false

    /// A pairing ask is in flight right now.
    @Published private(set) var isBondLinking = false

    private var bondAsksThisConnection = 0
    private var bindCheckAnswered = false

    /// Ask the ring whether it considers itself bound. The ack (0x15) is the
    /// only bond signal the firmware gives us; a firmware that never answers
    /// falls back to the persisted mark after a grace period.
    private func queryBondState() {
        send(.bindCheck)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.bindCheckAnswered, self.isProtocolReady else { return }
            let ringID = self.connectedRingID?.uuidString ?? self.preferredPeripheralID?.uuidString
            self.isBondConfirmed = ringID.map { self.bondedRingIDs.contains($0) } ?? false
        }
    }

    /// Ask up to three times across about 15 seconds. The pairing prompt can be
    /// missed on a locked phone. If none produce a bond, iOS likely holds a
    /// dead record. Forget the ring and pair again.
    private func triggerPairingIfNeeded() {
        guard !isBondConfirmed, !needsHardRepair, bondAsksThisConnection < 3 else { return }
        guard let ringID = connectedRingID?.uuidString ?? preferredPeripheralID?.uuidString else { return }
        // A prior mark with no contradiction yet: wait for the bindCheckAck
        // verdict instead of re-asking blindly.
        if bondedRingIDs.contains(ringID), bondAsksThisConnection == 0, !bindCheckAnswered { return }
        bondAsksThisConnection += 1
        isBondLinking = true
        send(.touchStartSecurity)
        print("[muse][ble] triggered encrypted pairing (0x19, attempt \(bondAsksThisConnection))")
        // The handshake takes a beat — re-query once it has had time to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.isProtocolReady, !self.isBondConfirmed else { return }
            self.send(.bindCheck)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self, self.isProtocolReady, !self.isBondConfirmed, !self.needsHardRepair else { return }
            if self.bondAsksThisConnection < 3 {
                self.triggerPairingIfNeeded()
            } else {
                self.isBondLinking = false
                self.needsHardRepair = true
                self.logBond("ring still not bound after 3 asks, forget and pair again")
            }
        }
    }

    private func handleBindCheckAck(_ payload: Data) {
        bindCheckAnswered = true
        print("[muse][ble] bind check ack: \(TreatyProtocolCodec.hex(payload))")
        // Nonzero first byte means the firmware holds a bond. See RING.md.
        let bound = payload.first.map { $0 != 0 } ?? false
        if bound {
            if !isBondConfirmed { logBond("bonded") }
            isBondConfirmed = true
            isBondLinking = false
            needsHardRepair = false
            if let ringID = connectedRingID?.uuidString ?? preferredPeripheralID?.uuidString {
                UserDefaults.standard.set(Array(bondedRingIDs.union([ringID])), forKey: Self.bondedRingsKey)
            }
        } else {
            isBondConfirmed = false
            logBond("ring reports not bound")
            if let ringID = connectedRingID { clearBondMark(for: ringID) }
            // Only ask here if nothing has asked yet this connection — the
            // post-0x19 re-query will catch an in-flight handshake.
            if bondAsksThisConnection == 0 { triggerPairingIfNeeded() }
        }
    }

    /// Forgetting a ring (here or in iOS settings) retires its bond mark.
    func clearBondMark(for ringID: UUID) {
        var ids = bondedRingIDs
        ids.remove(ringID.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: Self.bondedRingsKey)
        if connectedRingID == ringID || preferredPeripheralID == ringID {
            isBondConfirmed = false
        }
    }

    /// Drop the local bond mark and ask 0x19 again.
    func repairMediaControls() {
        if let ringID = connectedRingID { clearBondMark(for: ringID) }
        bondAsksThisConnection = 0
        triggerPairingIfNeeded()
    }

    /// Clears hard-repair flags before the picker forgets and re-pairs the ring.
    func noteRelinkStarted() {
        needsHardRepair = false
        isBondLinking = false
        logBond("re-pair started")
    }

    /// Encryption errors mean the iOS bond is dead. Drop the mark and stop asking.
    private func notePossibleBondFailure(_ error: Error?) {
        guard let nsError = error as NSError? else { return }
        let isBondFailure =
            (nsError.domain == CBErrorDomain && [
                CBError.encryptionTimedOut.rawValue,
                CBError.peerRemovedPairingInformation.rawValue,
            ].contains(nsError.code)) ||
            (nsError.domain == CBATTErrorDomain && [
                CBATTError.insufficientEncryption.rawValue,
                CBATTError.insufficientAuthentication.rawValue,
            ].contains(nsError.code))
        guard isBondFailure else { return }
        print("[muse][ble] bond failure signal: \(nsError.localizedDescription)")
        isBondConfirmed = false
        isBondLinking = false
        needsHardRepair = true
        logBond("bond failure signal: \(nsError.localizedDescription)")
        if let ringID = connectedRingID ?? preferredPeripheralID {
            clearBondMark(for: ringID)
        }
    }

    private func logBond(_ summary: String) {
        print("[muse][ble] \(summary)")
    }

    /// Treaty write. Hardware-only — not part of the app-facing API.
    func send(_ command: TreatyCommand, payload: Data = Data()) {
        guard let peripheral, let characteristic = txCharacteristic else { return }
        let frame = TreatyProtocolCodec.build(command: command, payload: payload, sequence: sequence)
        sequence &+= 1
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(frame, for: characteristic, type: writeType)
    }

    private func setCurrentTime() {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        var payload = Data()
        payload.append(bcdByte(from: (components.year ?? 2000) % 100))
        payload.append(bcdByte(from: components.month ?? 1))
        payload.append(bcdByte(from: components.day ?? 1))
        payload.append(bcdByte(from: components.hour ?? 0))
        payload.append(bcdByte(from: components.minute ?? 0))
        payload.append(bcdByte(from: components.second ?? 0))
        send(.setTime, payload: payload)
    }

    public func requestSystemState() {
        send(.getSystemState)
    }

    // MARK: - Capture delivery

    /// Publishes a finished capture for `drainCaptures()` to pick up.
    func enqueueCapture(_ capture: CompletedCapture) {
        completedCaptures.append(capture)
    }

    /// Hands over every pending capture and clears the queue in one step, so a
    /// re-entrant observer can't hand the same capture out twice.
    package func drainCaptures() -> [CompletedCapture] {
        let pending = completedCaptures
        completedCaptures.removeAll()
        return pending
    }

    // MARK: - Recording bitrate (Treaty 0x1C / 0x1D)

    func requestRecordingBitrate() {
        guard isProtocolReady else { return }
        send(.getRecordBitrate)
    }

    /// muse records at one bitrate, so the ring is simply told what it is.
    private func applyRecordingBitrateToDevice() {
        guard isProtocolReady else { return }
        send(.setRecordBitrate, payload: Data([OpusFormat.activeBitrate.firmwareCode]))
    }

    /// `0x1E`: bitrate code, then noise reduction and AGC when the firmware sends them.
    ///
    /// Noise reduction stays at 0. In testing (2026-10-14) levels 1 and 2 changed nothing
    /// measurable, so a ring left at another level by an earlier app or test goes back to 0,
    /// once per connection, like the bitrate. Its AGC byte is sent back as it was: its default
    /// and meaning aren't known, and it didn't change a recording either.
    private func handleRecordParams(_ payload: Data) {
        let bytes = [UInt8](payload)
        if bytes.count >= 3 {
            let sound = RingRecordingSound(noiseReduction: bytes[1], gain: bytes[2])
            if recordingSound != sound { recordingSound = sound }
            print("[muse][ble] ring records with bitrate code \(bytes[0]), noise reduction \(bytes[1]), agc \(bytes[2])")
            if bytes[1] != 0, !didResetNoiseReduction, isProtocolReady {
                didResetNoiseReduction = true
                print("[muse][ble] noise reduction \(bytes[1]) -> 0, agc kept at \(bytes[2])")
                send(.setRecordBitrate, payload: Data([OpusFormat.activeBitrate.firmwareCode, 0, bytes[2]]))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.requestRecordingBitrate()
                }
            }
        }
        handleRecordBitratePayload(payload)
    }

    private func handleRecordBitratePayload(_ payload: Data) {
        guard let code = payload.first, let bitrate = RecordingBitrate.from(firmwareCode: code) else { return }
        guard bitrate != OpusFormat.activeBitrate else { return }
        // One correction per connection. Firmware that clamps to a rate it prefers
        // gets to keep it rather than being argued with forever.
        guard !didCorrectBitrate else {
            print("[muse][ble] ring is holding \(bitrate.label); leaving it")
            return
        }
        didCorrectBitrate = true
        print("[muse][ble] ring reported \(bitrate.label); re-applying \(OpusFormat.activeBitrate.label)")
        applyRecordingBitrateToDevice()
    }

    private func reapplyBitrateIfIdle() {
        guard isProtocolReady, !isCapturing else { return }
        applyRecordingBitrateToDevice()
    }

    // MARK: - Opus capture

    private func noteKnownOpusNotification(_ data: Data) {
        let isCaptureStart = !isCapturing
        for tap in audioTaps.values {
            tap(data, isCaptureStart)
        }

        if suppressMuseCardCaptures {
            trackLiveCaptureActivity(packetBytes: data.count, isCaptureStart: isCaptureStart)
            captureByStream[opusStreamID, default: []].append(data)
            return
        }

        if !isCapturing {
            startAudioCapture()
        }

        packetCount += 1
        byteCount += data.count
        captureByStream[opusStreamID, default: []].append(data)

        scheduleAutoCaptureStop(after: 1.4)
    }

    private func startAudioCapture() {
        captureByStream.removeAll(keepingCapacity: true)
        captureStartedAt = Date()
        isAutoCapturing = true
        isCapturing = true
        packetCount = 0
        byteCount = 0
        captureElapsed = 0
        startCaptureTimer()
        print("[muse][capture] started (Opus 0x0009)")
    }

    private func scheduleAutoCaptureStop(after interval: TimeInterval) {
        autoCaptureStopTimer?.invalidate()
        autoCaptureStopTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.isCapturing, self.isAutoCapturing else { return }
            self.stopAudioCapture(saveCard: !self.suppressMuseCardCaptures)
        }
    }

    private func trackLiveCaptureActivity(packetBytes: Int, isCaptureStart: Bool) {
        if isCaptureStart {
            captureStartedAt = Date()
            packetCount = 0
            byteCount = 0
            captureElapsed = 0
            startCaptureTimer()
        }
        isCapturing = true
        packetCount += 1
        byteCount += packetBytes
        autoCaptureStopTimer?.invalidate()
        autoCaptureStopTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.endLiveCaptureUI()
        }
    }

    private func endLiveCaptureUI() {
        isCapturing = false
        isAutoCapturing = false
        captureTimer?.invalidate()
        captureTimer = nil
        autoCaptureStopTimer = nil
        captureByStream.removeAll(keepingCapacity: true)
        onLiveCaptureEnd?()
    }

    private func stopAudioCapture(saveCard: Bool) {
        autoCaptureStopTimer?.invalidate()
        autoCaptureStopTimer = nil
        captureTimer?.invalidate()
        captureTimer = nil

        let startedAt = captureStartedAt ?? Date()
        let endedAt = Date()
        let notifications = captureByStream[opusStreamID] ?? []
        let stamp = Self.fileStamp.string(from: startedAt)
        let priorPacketCount = packetCount
        let priorByteCount = byteCount

        isCapturing = false
        isAutoCapturing = false
        captureStartedAt = nil
        ringIsRecording = false
        captureElapsed = 0
        captureByStream.removeAll(keepingCapacity: true)

        guard saveCard, !notifications.isEmpty else {
            if notifications.isEmpty {
                print("[muse][capture] stopped with no Opus packets")
            }
            reapplyBitrateIfIdle()
            return
        }

        let oggFileName = "muse-\(stamp).ogg"
        let rawWavFileName = "muse-\(stamp)-raw.wav"

        decodeQueue.async { [weak self] in
            let packets = OggOpusWriter.extractPackets(from: notifications)
            print("[muse][capture] \(OggOpusWriter.lastExtractionSummary)")

            guard !packets.isEmpty else {
                print("[muse][capture] no Opus frames extracted")
                return
            }

            do {
                try FileManager.default.createDirectory(at: Self.capturesDirectory, withIntermediateDirectories: true)

                if let oggData = OggOpusWriter.write(packets: packets, inputSampleRate: UInt32(MuseCaptureConstants.opusSampleRate)) {
                    try oggData.write(to: Self.capturesDirectory.appendingPathComponent(oggFileName), options: .atomic)
                }

                // Decode once and wrap those same bytes — decodeToWav would run the
                // whole Opus decode a second time over identical audio.
                guard let pcm = OpusWavDecoder.decodeToPCM(packets: packets) else {
                    print("[muse][capture] Opus decode failed")
                    return
                }
                let wavData = OpusWavDecoder.wav(fromPCM: pcm)

                let wavURL = Self.capturesDirectory.appendingPathComponent(rawWavFileName)
                try wavData.write(to: wavURL, options: .atomic)

                let sampleCount = pcm.count / 2
                let audioDuration = Double(sampleCount) / Double(MuseCaptureConstants.opusSampleRate)
                let estimatedDuration = Double(packets.count) * MuseCaptureConstants.opusFrameDuration

                print(
                    "[muse][capture] saved \(rawWavFileName) @ \(MuseCaptureConstants.opusSampleRate)Hz, " +
                    "\(packets.count) frames (~\(String(format: "%.1f", estimatedDuration))s), " +
                    "\(priorByteCount)b BLE, \(priorPacketCount) notifications"
                )

                DispatchQueue.main.async {
                    self?.enqueueCapture(
                        CompletedCapture(
                            id: UUID(),
                            startedAt: startedAt,
                            endedAt: endedAt,
                            fileName: oggFileName,
                            wavFileName: rawWavFileName,
                            byteCount: priorByteCount,
                            packetCount: packets.count,
                            duration: audioDuration > 0 ? audioDuration : estimatedDuration,
                            sampleRate: MuseCaptureConstants.opusSampleRate,
                            source: .stream
                        )
                    )
                    self?.reapplyBitrateIfIdle()
                }
            } catch {
                print("[muse][capture] save failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleSystemState(_ payload: Data) {
        guard let state = RingSystemState.parse(payload) else { return }
        let wasRecording = ringIsRecording
        ringSystemState = state
        ringIsRecording = state.isRecording
        ringIsRecordingOffline = state.isRecording

        if state.isRecording && !wasRecording {
            recordingStartedAt = Date()
            print("[muse][ble] ring recording started (\(state.fileCount) file(s) stored)")
        } else if !state.isRecording && wasRecording {
            print("[muse][ble] ring recording stopped (\(state.fileCount) file(s) stored)")
            if isAutoCapturing {
                scheduleAutoCaptureStop(after: 1.4)
            }
            // The ring just closed a flash recording — pull it down while we're
            // still in range, whether or not the app is in the foreground. Nothing to
            // pull when it holds no files (a list would only wake its fast link); a file
            // count that catches up later arrives as its own E1 and syncs from there.
            if state.fileCount > 0 {
                scheduleAutoOfflineSync(after: 1.5)
            }
        } else if !state.isRecording, state.fileCount > 0, !isSyncingOffline {
            // Reconnected (or just checked in) with recordings waiting. Throttled
            // because synced recordings stay on the ring until it's cleared.
            scheduleAutoOfflineSync(after: 1.0, throttled: true)
        }
    }

    private func handle(_ frame: TreatyFrame) {
        guard let command = TreatyCommand(rawValue: frame.command) else { return }

        if handleOfflineFrame(frame) { return }

        switch command {
        case .systemState:
            handleSystemState(frame.payload)
        case .bindCheckAck:
            handleBindCheckAck(frame.payload)
        case .getRecordBitrate:
            if !frame.payload.isEmpty {
                handleRecordBitratePayload(frame.payload)
            }
        case .recordParams:
            // The ring answers 0x1C with 0x1E. Before this case, that answer was dropped,
            // so the bitrate check never ran.
            if !frame.payload.isEmpty {
                handleRecordParams(frame.payload)
            }
        case .setRecordBitrate:
            // The ack payload is a status byte, not a bitrate code — reading it as
            // one and "correcting" it is how you get an endless write loop.
            break
        default:
            break
        }
    }

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.captureStartedAt else { return }
            self.captureElapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        }
    }

    private func startRSSITimer() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
        peripheral?.readRSSI()
    }

    /// The ring only notifies battery on change, so a first read can be missed entirely.
    /// Poll until we have a level, then keep a slow refresh going.
    private func startBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.batteryPercent != nil || self.batteryIsCharging {
                self.startSlowBatteryTimer()
                return
            }
            self.readBatteryLevel()
        }
        readBatteryLevel()
    }

    private func startSlowBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.readBatteryLevel()
        }
    }

    public func readBatteryLevel() {
        guard let peripheral, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    // MARK: - Battery cache

    /// Shows the last known level for this ring while we wait on a live read, so a
    /// reconnect doesn't blank the indicator. Only trusted for an hour.
    private func restoreCachedBattery(for ringID: UUID) {
        guard batteryPercent == nil, !batteryIsCharging else { return }
        guard let cache = UserDefaults.standard.dictionary(forKey: Self.batteryCacheKey),
              let cachedRingID = cache["ring"] as? String,
              cachedRingID == ringID.uuidString,
              let stamp = cache["at"] as? Double
        else { return }

        let readAt = Date(timeIntervalSince1970: stamp)
        guard Date().timeIntervalSince(readAt) < Self.batteryCacheLifetime else { return }

        if let level = cache["percent"] as? Int, (0...100).contains(level) {
            batteryPercent = level
        }
        batteryIsCharging = cache["charging"] as? Bool ?? false
        batteryReadAt = readAt
        isBatteryEstimate = true
    }

    private func applyBatteryReading(percent: Int?, isCharging: Bool) {
        batteryPercent = percent
        batteryIsCharging = isCharging
        batteryReadAt = Date()
        isBatteryEstimate = false

        guard let ringID = connectedRingID ?? preferredPeripheralID else { return }
        var cache: [String: Any] = [
            "ring": ringID.uuidString,
            "charging": isCharging,
            "at": Date().timeIntervalSince1970
        ]
        if let percent { cache["percent"] = percent }
        UserDefaults.standard.set(cache, forKey: Self.batteryCacheKey)
    }

    private func stopTimers() {
        rssiTimer?.invalidate()
        batteryTimer?.invalidate()
        captureTimer?.invalidate()
        autoCaptureStopTimer?.invalidate()
        offlineTimeoutTimer?.invalidate()
        fileListTimer?.invalidate()
        scanFallbackWorkItem?.cancel()
        stopNearbyScanTimer()
        rssiTimer = nil
        batteryTimer = nil
        captureTimer = nil
        autoCaptureStopTimer = nil
        scanFallbackWorkItem = nil
    }

    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func isKnownOpusCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        uuidString(characteristic.uuid.uuidString, matchesShortUUID: "0009")
    }

    private func uuidString(_ value: String, matchesShortUUID shortUUID: String) -> Bool {
        let normalized = value.uppercased()
        let short = shortUUID.uppercased()
        return normalized == short || normalized.hasPrefix("0000\(short)-")
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanPending {
                scanPending = false
                scan()
                return
            }
            if let peripheral {
                if peripheral.state == .connected {
                    adoptRestoredPeripheral(peripheral)
                    return
                }
                if peripheral.state == .connecting {
                    state = .connecting
                    return
                }
            }
            if preferredPeripheralID != nil, !userRequestedDisconnect, !isFirmwareUpdateInProgress {
                reconnectPreferred()
            } else {
                state = .idle
            }
        case .poweredOff, .unauthorized, .unsupported:
            state = .bluetoothOff
        default:
            state = .idle
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              !restored.isEmpty else {
            print("[muse][ble] central restored without peripherals")
            return
        }

        let selected = preferredPeripheralID.flatMap { preferredID in
            restored.first { $0.identifier == preferredID }
        } ?? restored.first!

        // Restoration runs before the manager reports .poweredOn, and issuing
        // commands that early logs API MISUSE. Stash it; didUpdateState adopts it.
        guard central.state == .poweredOn else {
            peripheral = selected
            selected.delegate = self
            return
        }
        adoptRestoredPeripheral(selected)
    }

    private func adoptRestoredPeripheral(_ restored: CBPeripheral) {
        guard !isFirmwareUpdateInProgress else { return }
        if peripheral?.identifier == restored.identifier,
           state == .connected || state == .connecting {
            restored.delegate = self
            return
        }

        scanFallbackWorkItem?.cancel()
        central?.stopScan()
        peripheral = restored
        restored.delegate = self
        preferredPeripheralID = restored.identifier
        UserDefaults.standard.set(restored.identifier.uuidString, forKey: Self.preferredKey)
        deviceName = restored.name ?? deviceName
        userRequestedDisconnect = false
        frameDecoder.reset()
        didRunProtocolStartup = false
        didCorrectBitrate = false
        didResetNoiseReduction = false
        txCharacteristic = nil
        rxCharacteristic = nil

        switch restored.state {
        case .connected:
            state = .connected
            connectedRingID = restored.identifier
            refreshConnectionFlags()
            restoreCachedBattery(for: restored.identifier)
            discoverRequiredServices(on: restored)
            startRSSITimer()
            print("[muse][ble] restored connected ring \(restored.name ?? restored.identifier.uuidString)")
        case .connecting:
            state = .connecting
            isConnected = false
            print("[muse][ble] restored pending ring connection")
        default:
            connect(to: restored, name: restored.name ?? "muse ring", rssi: nil, remember: true)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisesTreaty = advertisedServices.contains(Self.serviceUUID)
        guard advertisesTreaty || DiscoveredRing.isAllowedName(name) else { return }

        didDiscoverDuringCurrentScan = true
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil

        let displayName = name.isEmpty ? "muse ring" : name
        let ring = DiscoveredRing(
            id: peripheral.identifier,
            name: displayName,
            rssi: RSSI.intValue,
            lastSeen: Date(),
            peripheral: peripheral,
            isKnownLink: false
        )

        if let index = discoveredRings.firstIndex(where: { $0.id == ring.id }) {
            let previous = discoveredRings[index]
            let elapsed = Date().timeIntervalSince(lastDiscoveryPublishAt)
            let rssiDelta = abs(previous.rssi - ring.rssi)
            guard elapsed >= Self.discoveryPublishInterval || rssiDelta >= Self.rssiPublishDelta else {
                return
            }
            discoveredRings[index] = ring
        } else {
            discoveredRings.append(ring)
        }
        discoveredRings.sort { $0.rssi > $1.rssi }
        lastDiscoveryPublishAt = Date()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        connectedRingID = peripheral.identifier
        preferredPeripheralID = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.preferredKey)
        if let name = peripheral.name, !name.isEmpty {
            deviceName = name
        }
        refreshConnectionFlags()
        restoreCachedBattery(for: peripheral.identifier)
        discoverRequiredServices(on: peripheral)
        startRSSITimer()
        print("[muse][ble] connected to \(peripheral.name ?? "ring")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(peripheral, isReconnecting: false, error: error)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handleDisconnect(peripheral, isReconnecting: isReconnecting, error: error)
    }

    private func handleDisconnect(_ disconnected: CBPeripheral, isReconnecting: Bool, error: Error?) {
        notePossibleBondFailure(error)
        if isCapturing {
            stopAudioCapture(saveCard: !suppressMuseCardCaptures)
        }
        abortOfflineSync()
        ringSystemState = nil
        ringIsRecordingOffline = false
        ringFiles.removeAll()
        connectedRingID = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        didRunProtocolStartup = false
        didCorrectBitrate = false
        didResetNoiseReduction = false
        isConnected = false
        isBondConfirmed = false
        bondAsksThisConnection = 0
        bindCheckAnswered = false
        // Whatever level we last saw is now history until the ring answers again.
        if batteryPercent != nil || batteryIsCharging { isBatteryEstimate = true }
        stopTimers()

        resumeFirmwareDisconnectWaiters()

        if isReconnecting && !userRequestedDisconnect && !isFirmwareUpdateInProgress {
            peripheral = disconnected
            disconnected.delegate = self
            state = .connecting
            print("[muse][ble] link dropped; iOS is automatically reconnecting")
            return
        }

        state = .disconnected
        print("[muse][ble] disconnected: \(error?.localizedDescription ?? "clean")")
        armPendingReconnect(to: disconnected)
    }

    /// CoreBluetooth holds an outstanding connect request indefinitely and retries
    /// it in the controller, so one request replaces app-side retry polling. It
    /// survives suspension; state restoration covers termination.
    private func armPendingReconnect(to candidate: CBPeripheral?) {
        guard !userRequestedDisconnect, !isFirmwareUpdateInProgress, let central, centralPoweredOn else { return }

        let target = candidate ?? preferredPeripheralID.flatMap {
            central.retrievePeripherals(withIdentifiers: [$0]).first
        }
        guard let target, target.state != .connected, target.state != .connecting else { return }

        peripheral = target
        target.delegate = self
        central.connect(
            target,
            options: [CBConnectPeripheralOptionEnableAutoReconnect: true]
        )
        print("[muse][ble] reconnect pending with iOS for \(target.name ?? target.identifier.uuidString)")
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed
        print("[muse][ble] failed to connect: \(error?.localizedDescription ?? "unknown")")
        notePossibleBondFailure(error)
        armPendingReconnect(to: peripheral)
    }

    // MARK: - CBPeripheralDelegate

    private func discoverRequiredServices(on peripheral: CBPeripheral) {
        peripheral.discoverServices([
            Self.serviceUUID,
            Self.opusServiceUUID,
            Self.batteryServiceUUID
        ])
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.txUUID {
                txCharacteristic = characteristic
            } else if characteristic.uuid == Self.rxUUID {
                rxCharacteristic = characteristic
            } else if characteristic.uuid == Self.batteryCharUUID {
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                startBatteryTimer()
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        refreshConnectionFlags()

        if isProtocolReady && !didRunProtocolStartup {
            didRunProtocolStartup = true
            queryBondState()
            triggerPairingIfNeeded()
            setCurrentTime()
            requestSystemState()
            applyRecordingBitrateToDevice()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.requestRecordingBitrate()
            }
            print("[muse][ble] protocol ready")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == Self.batteryCharUUID {
            if let raw = data.first {
                let level = Int(raw)
                if level > 100 {
                    // Some firmwares encode charging as >100; keep a usable percent when possible.
                    let inferred = level - 128
                    if (0...100).contains(inferred) {
                        applyBatteryReading(percent: inferred, isCharging: true)
                    } else if (0...100).contains(level - 100) {
                        applyBatteryReading(percent: level - 100, isCharging: true)
                    } else {
                        applyBatteryReading(percent: batteryPercent, isCharging: true)
                    }
                } else {
                    applyBatteryReading(percent: level, isCharging: false)
                }
            }
            return
        }

        if characteristic.uuid == Self.rxUUID {
            let frames = frameDecoder.feed(data)
            for frame in frames {
                handle(frame)
            }
            return
        }

        if isKnownOpusCharacteristic(characteristic) {
            noteKnownOpusNotification(data)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        rssi = RSSI.intValue
    }
}

private func bcdByte(from value: Int) -> UInt8 {
    UInt8(((value / 10) << 4) | (value % 10))
}
