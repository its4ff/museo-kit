import Foundation

/// Everything the ring icon, the ring sheet and the home status line show, in one
/// `Equatable` value.
///
/// `RingBLEManager` publishes byte counts and timers many times a second while a muse
/// streams. This value only changes when something on screen would, so views that read
/// `RingModel.status` never redraw for a packet. Port of museum's `MuseumRingStatus`.
///
/// Read it anywhere: `@Environment(RingModel.self) var ring` then `ring.status.isLive`.
/// Lab screens and previews use the fixtures at the bottom (`.linked`, `.syncing`, ...).
public nonisolated struct RingStatus: Equatable, Sendable {
    public enum Link: String, Sendable, CaseIterable {
        /// No ring set up on this iphone for this app yet.
        case notSetUp
        case bluetoothOff
        /// Set up, and the link is coming up (or a look for it is running).
        case joining
        /// Set up, not in reach. iOS keeps a connect request open and links when it's back.
        case away
        /// The ring answers: muses can stream and sync.
        case linked
    }

    public var link: Link

    public init(link: Link) {
        self.link = link
    }
    /// The ring's name in iOS (AccessorySetupKit), `Museo.ringName` until renamed.
    public var name: String = Museo.ringName
    /// What the ring advertises, like "Museo_47cf". Nil until it has linked once.
    public var advertisedName: String?

    /// 0 to 100 in steps of 5. Nil until the ring has answered once.
    public var battery: Int?
    public var isCharging = false
    /// The level is the last one read (cached, or the ring is away), not a live one.
    public var batteryIsStale = false
    public var batteryReadAt: Date?

    /// A muse is streaming in right now (hold the ring).
    public var isLive = false
    public var liveSince: Date?
    /// The ring is recording into its own storage (double click). Also true during live:
    /// check `isLive` first.
    public var isRecordingOnRing = false

    /// Bringing recordings in from the ring.
    public var isSyncing = false
    /// Share of the recording in flight, 0 to 1 in steps of 0.1. Nil when not syncing.
    public var syncProgress: Double?
    /// Recordings still on the ring that this app hasn't brought in.
    public var waiting = 0
    /// The ring's free storage, 0 to 100, from its last answer (kept while it's away).
    public var freeStoragePercent: Int?
    /// Bring recordings in on their own when the ring links or stops recording.
    public var autoSync = true
    /// Wipe the ring after a clean sync.
    public var autoClear = false
    /// Why the last sync stopped, in the house voice.
    public var syncError: String?

    /// AccessorySetupKit is on (Info.plist declares it). Off, setup is a plain bluetooth scan.
    public var usesAccessorySetup = true
    public var isFirmwareUpdating = false
    /// The firmware the ring says it runs, like "1.64". Nil until it has answered once.
    public var firmwareVersion: String?

    // Beyond the spec, all optional for views:

    /// "disconnect" was tapped. The ring stays set up; nothing links until "look for it".
    public var userDisconnected = false
    /// The setup picker (or the plain scan) is up right now.
    public var isSettingUp = false
    /// Why the last setup didn't happen, in the house voice. Nil once the ring links.
    public var setupNote: String?
    /// iOS can rename this ring (AccessorySetupKit, set up by this app).
    public var canRename = false

    // MARK: Thresholds

    /// Battery at or under this reads as low while linked (clay band on the icon).
    public static let lowBattery = 20
    /// Free storage at or under this reads as nearly full.
    public static let lowStorage = 20
    /// Minutes of recording per percent of free storage: 32 MiB at 24 kbps is about
    /// 3 h 6 min, so each percent is about 1.86 minutes.
    public static let minutesPerStoragePercent = 1.86

    // MARK: Derived

    public var isLinked: Bool { link == .linked }

    /// The ring runs older firmware than the image in this kit (`BundledFirmware`), and no
    /// update is running. Unknown versions never count.
    public var firmwareIsBehind: Bool {
        link != .notSetUp && !isFirmwareUpdating && BundledFirmware.isNewer(than: firmwareVersion)
    }

    /// Something only the person can fix: bluetooth, or a ring that's nearly full.
    public var needsAttention: Bool {
        switch link {
        case .bluetoothOff: return true
        case .linked: return isStorageLow
        default: return false
        }
    }

    public var isLowBattery: Bool {
        guard link == .linked, !isCharging, let battery else { return false }
        return battery <= Self.lowBattery
    }

    public var isStorageLow: Bool {
        guard let freeStoragePercent else { return false }
        return freeStoragePercent <= Self.lowStorage
    }

    /// About how many minutes more the ring can record.
    public var minutesLeft: Int? {
        guard let freeStoragePercent else { return nil }
        return Int((Double(freeStoragePercent) * Self.minutesPerStoragePercent).rounded())
    }

    // MARK: Copy (lowercase house voice)

    /// The line under "your ring." in the sheet.
    public var headline: String {
        if isFirmwareUpdating { return "updating firmware · keep it close" }
        switch link {
        case .notSetUp:
            if isSettingUp {
                return usesAccessorySetup ? "choosing your ring…" : "looking for rings nearby · click yours to wake it"
            }
            return "not set up on this iphone yet"
        case .bluetoothOff:
            return "bluetooth is off"
        case .joining:
            return "joining…"
        case .away:
            return userDisconnected ? "disconnected · look for it to link again" : "looking for your ring · click it to wake it"
        case .linked:
            if isLive { return "linked · listening" }
            if isRecordingOnRing { return "linked · recording on the ring" }
            if isSyncing { return "linked · bringing in \(max(waiting, 1))" }
            return "linked"
        }
    }

    /// The home status line and the pill: "ring linked", "listening…", "bringing in 3".
    public var shortLine: String {
        if isFirmwareUpdating { return "updating firmware" }
        switch link {
        case .notSetUp: return "set up your ring"
        case .bluetoothOff: return "bluetooth is off"
        case .joining: return "ring joining…"
        case .away: return userDisconnected ? "ring disconnected" : "ring away"
        case .linked:
            if isLive { return "listening…" }
            if isSyncing { return "bringing in \(max(waiting, 1))" }
            if isRecordingOnRing { return "recording on the ring" }
            return "ring linked"
        }
    }

    /// "your ring, linked, battery 80 percent, 2 coming in".
    public var accessibilityLabel: String {
        // While syncing the count is said once, at the end, not also in the headline.
        let state = (link == .linked && isSyncing && !isFirmwareUpdating) ? "linked" : Self.spoken(headline)
        var parts = ["your ring", state]
        if link != .notSetUp, let battery {
            parts.append(isCharging ? "battery \(battery) percent, charging" : "battery \(battery) percent")
        }
        if isSyncing {
            parts.append("\(max(waiting, 1)) coming in")
        } else if link == .linked, waiting > 0 {
            parts.append(waiting == 1 ? "1 recording waiting" : "\(waiting) recordings waiting")
        }
        if needsAttention, link == .linked { parts.append("nearly full") }
        if firmwareIsBehind { parts.append("firmware update ready") }
        return parts.joined(separator: ", ")
    }

    /// The device card line: "linked · 80% · Museo_47cf", "away · last read 9:14a".
    public var deviceLine: String {
        switch link {
        case .notSetUp:
            return "set it up to make muses on it"
        case .bluetoothOff:
            return "turn bluetooth on to link"
        case .joining:
            return advertisedName.map { "joining · \($0)" } ?? "joining…"
        case .away:
            let word = userDisconnected ? "disconnected" : "away"
            if let batteryReadAt { return "\(word) · last read \(batteryReadAt.kitClock)" }
            return word
        case .linked:
            var parts = ["linked"]
            if let battery { parts.append("\(battery)%") }
            if let advertisedName { parts.append(advertisedName) }
            return parts.joined(separator: " · ")
        }
    }

    /// The battery row: "80% · charging", "80% · last read 2m ago". Nil before any reading.
    public var batteryLine: String? {
        guard let battery else { return nil }
        if isCharging { return "\(battery)% · charging" }
        if batteryIsStale, let batteryReadAt { return "\(battery)% · last read \(batteryReadAt.kitRelative)" }
        return "\(battery)%"
    }

    /// Ring storage: "about 2 h 40 min left", "nearly full · about 22 min left".
    public var storageLine: String? {
        guard let minutesLeft else { return nil }
        let left = "about \(Self.hoursAndMinutes(minutesLeft)) left"
        return isStorageLow ? "nearly full · \(left)" : left
    }

    // MARK: Helpers

    /// Rounds a battery reading to the icon's 5% steps.
    public static func quantized(battery: Int?) -> Int? {
        guard let battery else { return nil }
        let clamped = min(max(battery, 0), 100)
        return Int((Double(clamped) / 5).rounded()) * 5
    }

    /// Rounds sync progress to 10% steps so the icon doesn't redraw per packet.
    public static func quantized(progress: Double) -> Double {
        (min(max(progress, 0), 1) * 10).rounded() / 10
    }

    /// "2 h 40 min", "45 min", "3 h".
    public static func hoursAndMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Headline for VoiceOver: commas for middle dots, no ellipsis.
    private static func spoken(_ line: String) -> String {
        line.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "…", with: "")
    }
}

// MARK: - Fixtures (lab, previews, the design kit)

public nonisolated extension RingStatus {
    /// Relative to the first time a fixture is read, so "last read" says "2m ago".
    /// Clock text (`kitClock`) follows the run's real time; lab screens that need a fixed
    /// clock set `batteryReadAt` themselves.
    private static var recently: Date { Date(timeIntervalSinceNow: -120) }

    static let notSetUp = RingStatus(link: .notSetUp)

    static let linked: RingStatus = {
        var status = RingStatus(link: .linked)
        status.advertisedName = "Museo_47cf"
        status.battery = 80
        status.batteryReadAt = recently
        status.freeStoragePercent = 86
        status.firmwareVersion = BundledFirmware.imageVersion
        status.canRename = true
        return status
    }()

    /// Linked, on firmware older than the bundled image.
    static let updateReady: RingStatus = {
        var status = linked
        status.firmwareVersion = "1.62"
        return status
    }()

    static let away: RingStatus = {
        var status = linked
        status.link = .away
        status.batteryIsStale = true
        status.batteryReadAt = Date(timeIntervalSinceNow: -32 * 60)
        status.canRename = false
        return status
    }()

    static let linkedLow: RingStatus = {
        var status = linked
        status.battery = 15
        return status
    }()

    static let charging: RingStatus = {
        var status = linked
        status.battery = 55
        status.isCharging = true
        return status
    }()

    static let live: RingStatus = {
        var status = linked
        status.isLive = true
        status.liveSince = Date(timeIntervalSinceNow: -7)
        return status
    }()

    static let syncing: RingStatus = {
        var status = linked
        status.isSyncing = true
        status.syncProgress = 0.4
        status.waiting = 3
        return status
    }()

    static let nearlyFull: RingStatus = {
        var status = linked
        status.freeStoragePercent = 12
        status.waiting = 2
        return status
    }()

    static let joining: RingStatus = {
        var status = linked
        status.link = .joining
        status.batteryIsStale = true
        return status
    }()

    static let bluetoothOff: RingStatus = {
        var status = away
        status.link = .bluetoothOff
        return status
    }()

    /// Every fixture with a name, for glyph sheets and the design kit.
    static let fixtures: [(name: String, status: RingStatus)] = [
        ("notSetUp", .notSetUp),
        ("joining", .joining),
        ("linked", .linked),
        ("linkedLow", .linkedLow),
        ("charging", .charging),
        ("live", .live),
        ("syncing", .syncing),
        ("nearlyFull", .nearlyFull),
        ("updateReady", .updateReady),
        ("away", .away),
        ("bluetoothOff", .bluetoothOff),
    ]
}
