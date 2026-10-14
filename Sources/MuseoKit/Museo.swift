import Foundation
@_exported import MuseoCore

/// The one door into the museo ring.
///
/// ```swift
/// // once, at launch, in the app delegate (never in a view)
/// Museo.start(name: "museo")
///
/// // where your app keeps recordings: save first, then say so
/// Museo.onCapture { capture, seenBefore in
///     guard !seenBefore else { return true }   // brought in before (maybe you deleted it)
///     return save(capture)                     // true once it's on disk: the ring may let go
/// }
///
/// // anything that wants to know what the ring is doing
/// Museo.onEvent { event in
///     if case .liveStarted = event { print("listening") }
/// }
///
/// // words while you speak: the audio of a hold, as it arrives
/// for await piece in Museo.liveAudio() { … }
///
/// // screens
/// @Environment(RingModel.self) private var ring   // ring.status.isLinked, .battery, .isLive
/// ```
///
/// Everything below this door (bluetooth, the ring's protocol, decoding, sync, setup with
/// iOS's accessory sheet, firmware) lives in this package and is never edited by an app.
/// Recordings are always 24 kbps; there is no setting for it.
public enum Museo {
    /// What iOS's accessory sheet calls the ring. The first app to set a ring up names it
    /// for every app, so keep it plain.
    nonisolated(unsafe) public private(set) static var ringName = "museo"

    /// The ring manager, once `start` has run. Screens read `RingModel.status` instead:
    /// the manager publishes many times a second while a muse streams. Reach for it for
    /// low-level tools like a console.
    public private(set) static var manager: RingBLEManager?

    /// The firmware updater, with the firmware bundled in this package.
    public static let firmware = RingFirmwareUpdater()

    /// Streamed captures shorter than this (seconds) are accidental presses. They're dropped
    /// with their files and never reach `onCapture`.
    nonisolated public static let shortestCapture: TimeInterval = 1.0

    // MARK: - Start

    /// Starts the ring: the manager, first-run defaults, the status screens read, setup
    /// with iOS's accessory sheet, recordings and events, the firmware updater.
    ///
    /// Call it once, in `application(_:didFinishLaunchingWithOptions:)`, so iOS can wake the
    /// app for the ring in the background and recordings still come in with no screen up.
    /// Calling it again returns the same manager.
    ///
    /// - Parameters:
    ///   - name: what iOS's accessory sheet calls the ring.
    ///   - clearsRingAfterSync: wipe the ring after every clean sync. Off by default, so a
    ///     second ring app on the phone (or a reinstall) never loses a recording. Applied
    ///     on the first launch only; after that the ring sheet's switch decides.
    @discardableResult
    public static func start(name: String = "museo", clearsRingAfterSync: Bool = false) -> RingBLEManager {
        if let manager { return manager }
        ringName = name
        let ble = RingBLEManager()
        manager = ble
        applyFirstRunDefaults(ble, clearsRingAfterSync: clearsRingAfterSync)
        RingModel.shared.attach(ble, setup: .shared)
        RingSetup.shared.start(with: ble)
        RingEvents.shared.attach(ble)
        LiveAudioTap.shared.attach(ble)
        CaptureInbox.shared.attach(ble)
        firmware.attach(ble)
        return ble
    }

    // MARK: - Recordings

    /// Your app's one place to keep finished recordings. Every capture the ring finishes
    /// (streamed live, or brought in from the ring's storage) comes here once.
    ///
    /// Return true when the recording is safe on this phone: saved now, or already saved.
    /// A memory recording (from the ring's storage) stays on the ring until you do, and
    /// comes back with the next sync. A live recording has no copy on the ring: when you
    /// return false the kit keeps it and offers it again at the next `takeWaitingCaptures()`
    /// (and whenever a new capture arrives), so keep returning false until it's saved.
    ///
    /// `seenBefore` is true when this phone brought the same ring recording in before (the
    /// ring downloaded it again, or you deleted its muse). Keep your existing copy, skip
    /// it, and return true. The capture's files are in `RingBLEManager.capturesDirectory`.
    ///
    /// One handler: setting a new one replaces the old. Captures that finished before you
    /// set it wait in the manager and arrive as soon as you do.
    public static func onCapture(_ save: @escaping (CompletedCapture, _ seenBefore: Bool) -> Bool) {
        CaptureInbox.shared.setHandler(save)
    }

    /// Hands over any finished captures still waiting. They also arrive on their own; call
    /// this from a foreground sweep to be sure.
    public static func takeWaitingCaptures() {
        CaptureInbox.shared.takeWaiting()
    }

    // MARK: - Events

    /// Calls `handler` on the main actor for every ring event, for the life of the app.
    /// Any number of listeners.
    public static func onEvent(_ handler: @escaping (RingEvent) -> Void) {
        RingEvents.shared.add(handler)
    }

    /// Ring events as an async sequence. Each call gets its own stream.
    public static func events() -> AsyncStream<RingEvent> {
        RingEvents.shared.stream()
    }

    // MARK: - Live audio

    /// The ring's audio while it streams (a hold), as it arrives: `.began`, then 16 kHz mono
    /// samples about every 100 ms, then `.ended`. For words while you speak. Memory recordings
    /// never come through here; they arrive whole, through `onCapture`.
    ///
    /// Decoding only runs while at least one stream is open, so end the loop (or cancel its
    /// task) when nothing is listening. Each call gets its own stream.
    public static func liveAudio() -> AsyncStream<LiveAudio> {
        LiveAudioTap.shared.stream()
    }

    // MARK: - Defaults

    private static let didApplyDefaultsKey = "museo.kit.didApplyDefaults"
    /// Set by earlier builds of this kit. Either key means defaults were applied once.
    private static let earlierDefaultsKey = "muse.build.didApplyRingDefaults"

    private static func applyFirstRunDefaults(_ ble: RingBLEManager, clearsRingAfterSync: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didApplyDefaultsKey), !defaults.bool(forKey: earlierDefaultsKey) else { return }
        ble.autoClearRingStorage = clearsRingAfterSync
        defaults.set(true, forKey: didApplyDefaultsKey)
    }
}
