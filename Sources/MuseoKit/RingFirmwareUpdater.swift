import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import iOSMcuManagerLibrary
import MuseoCore

/// The MCUboot zip for the 54L15 ring, bundled in this package. To ship new firmware, replace
/// `Resources/MuseRing.zip` (manifest.json + signed image), set `stamp`, and tag a new version.
public enum BundledFirmware {
    static let zipName = "MuseRing"
    /// The build date of the bundled image (the manifest's `time`), yyyyMMdd. Update it
    /// when you drop in a new zip.
    public static let stamp = "20261014"

    /// What the firmware is called: month and day of the stamp, "10.14".
    public static var version: String {
        let digits = Array(stamp)
        guard digits.count == 8, let month = Int(String(digits[4...5])) else { return stamp }
        return "\(month).\(String(digits[6...7]))"
    }

    static var packageURL: URL? {
        Bundle.module.url(forResource: zipName, withExtension: "zip")
    }
}

/// SMP / MCUboot OTA via Nordic's iOS Device Manager library.
/// Treaty uses its own CBCentralManager, so we drop that link first and let
/// McuMgrBleTransport open a second central against the same ring UUID.
@MainActor
public final class RingFirmwareUpdater: NSObject, ObservableObject {
    public enum Phase: Equatable {
        case idle
        case preparing
        case sending(progress: Double)
        case confirming
        case resetting
        case success
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .preparing, .sending, .confirming, .resetting: return true
            default: return false
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var status: String = ""
    /// When the whole update should be done, sending through restart. Nil when idle or
    /// settled. Seeded from the last update's speed, then from the measured speed while
    /// sending; it only creeps later a little at a time, so a countdown never jumps back.
    @Published public private(set) var estimatedFinishAt: Date?

    private weak var ble: RingBLEManager?
    private var transport: McuMgrBleTransport?
    private var manager: FirmwareUpgradeManager?
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    // MARK: Time left
    private var sendClock: Date?
    private var smoothedRate: Double = 0
    private var imageBytes = 0
    /// Confirming and restarting after the last byte.
    private static let afterSendSlack: TimeInterval = 18
    /// Bytes a second before this phone has sent an update (muse OS measured about this).
    private static let firstSendRate: Double = 28_000
    private static let sendRateKey = "museo.kit.firmware.sendRate"

    /// `Museo.firmware` is the app's one updater. Lab screens and previews may make their own.
    public override init() {
        super.init()
    }

    func attach(_ ble: RingBLEManager) {
        self.ble = ble
    }

    public func resetIfSettled() {
        switch phase {
        case .success, .failed, .idle:
            phase = .idle
            status = ""
        default:
            break
        }
    }

    public func start() {
        guard !phase.isBusy else { return }
        guard let ble else {
            fail("link your ring first")
            return
        }
        guard BundledFirmware.packageURL != nil else {
            fail("the firmware file is missing from this build")
            return
        }
        guard ble.preferredPeripheralID != nil || ble.connectedRingID != nil else {
            fail("link your ring first")
            return
        }

        phase = .preparing
        status = "bring the ring close"
        Task { await run(using: ble) }
    }

    private func run(using ble: RingBLEManager) async {
        beginBackgroundTask()
        let ringID = await ble.prepareForFirmwareUpdate()
        guard let ringID else {
            fail("couldn't find the ring")
            ble.finishFirmwareUpdate()
            return
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        guard let packageURL = BundledFirmware.packageURL else {
            fail("the firmware file is missing from this build")
            ble.finishFirmwareUpdate()
            return
        }

        do {
            let package = try McuMgrPackage(from: packageURL)
            let transport = McuMgrBleTransport(ringID)
            self.transport = transport
            let manager = FirmwareUpgradeManager(transport: transport, delegate: self)
            self.manager = manager

            var configuration = FirmwareUpgradeConfiguration()
            configuration.estimatedSwapTime = 15
            configuration.eraseAppSettings = false
            configuration.pipelineDepth = 2
            configuration.upgradeMode = .confirmOnly

            status = "sending firmware"
            phase = .sending(progress: 0)
            seedEstimate()
            manager.start(package: package, using: configuration)
        } catch {
            fail(error.localizedDescription)
            finishTransport()
            ble.finishFirmwareUpdate()
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message.kitQuiet)
        status = ""
        resetTiming()
        endBackgroundTask()
    }

    // MARK: Estimate

    private var rememberedSendRate: Double {
        let stored = UserDefaults.standard.double(forKey: Self.sendRateKey)
        return stored > 6_000 ? stored : Self.firstSendRate
    }

    private func seedEstimate() {
        sendClock = nil
        smoothedRate = 0
        imageBytes = 0
        // Close to the bundled image's size; the first progress report corrects it.
        estimatedFinishAt = Date().addingTimeInterval(430_000 / rememberedSendRate + Self.afterSendSlack)
    }

    private func updateEstimate(bytesSent: Int, imageSize: Int, at time: Date) {
        imageBytes = imageSize
        if sendClock == nil, bytesSent > 0 { sendClock = time }
        var rate = rememberedSendRate
        if let start = sendClock {
            let elapsed = time.timeIntervalSince(start)
            if elapsed >= 0.9, bytesSent >= 12_000 {
                let measured = Double(bytesSent) / elapsed
                smoothedRate = smoothedRate == 0 ? measured : smoothedRate * 0.65 + measured * 0.35
                rate = smoothedRate
            }
        }
        let sendLeft = Double(max(0, imageSize - bytesSent)) / max(rate, 6_000)
        let candidate = time.addingTimeInterval(sendLeft + Self.afterSendSlack)
        if let current = estimatedFinishAt, candidate > current {
            estimatedFinishAt = min(candidate, current.addingTimeInterval(1.8))
        } else {
            estimatedFinishAt = candidate
        }
    }

    /// After the image is sent, at least `floor` and at most `ceiling` seconds remain.
    private func keepEstimate(atLeast floor: TimeInterval, atMost ceiling: TimeInterval, else fallback: TimeInterval) {
        let left = estimatedFinishAt?.timeIntervalSinceNow ?? 0
        if left < floor || left > ceiling {
            estimatedFinishAt = Date().addingTimeInterval(fallback)
        }
    }

    /// The next update starts from this phone's real speed.
    private func rememberSendRate() {
        guard let start = sendClock, imageBytes > 0 else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 2 else { return }
        UserDefaults.standard.set(Double(imageBytes) / elapsed, forKey: Self.sendRateKey)
    }

    private func resetTiming() {
        sendClock = nil
        smoothedRate = 0
        estimatedFinishAt = nil
    }

    private func finishTransport() {
        transport?.close()
        transport = nil
        manager = nil
    }

    /// Keeps the screen on and asks for background time: a phone that locks mid-send can
    /// suspend the app before the ring has the whole image.
    private func beginBackgroundTask() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "museo.firmware") { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }
}

extension RingFirmwareUpdater: FirmwareUpgradeDelegate {
    nonisolated public func upgradeDidStart(controller: FirmwareUpgradeController) {
        Task { @MainActor [weak self] in
            self?.status = "sending firmware"
            self?.phase = .sending(progress: 0)
        }
    }

    nonisolated public func upgradeStateDidChange(
        from previousState: FirmwareUpgradeState,
        to newState: FirmwareUpgradeState
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch newState {
            case .validate, .requestMcuMgrParameters, .bootloaderInfo:
                self.status = "checking the ring"
            case .upload:
                self.status = "sending firmware"
            case .confirm, .test, .eraseAppSettings:
                self.phase = .confirming
                self.status = "confirming image"
                self.keepEstimate(atLeast: 4, atMost: .infinity, else: 20)
            case .reset, .resetIntoFirmwareLoader:
                self.phase = .resetting
                self.status = "restarting ring"
                self.keepEstimate(atLeast: 10, atMost: 22, else: 16)
            case .success, .none:
                break
            }
        }
    }

    nonisolated public func upgradeDidComplete() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.phase = .success
            self.status = "firmware updated"
            self.rememberSendRate()
            self.resetTiming()
            self.finishTransport()
            self.endBackgroundTask()
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.ble?.finishFirmwareUpdate()
        }
    }

    nonisolated public func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fail(error.localizedDescription)
            self.finishTransport()
            self.ble?.finishFirmwareUpdate()
        }
    }

    nonisolated public func upgradeDidCancel(state: FirmwareUpgradeState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fail("the update was stopped")
            self.finishTransport()
            self.ble?.finishFirmwareUpdate()
        }
    }

    nonisolated public func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        Task { @MainActor [weak self] in
            guard let self, imageSize > 0 else { return }
            let progress = min(max(Double(bytesSent) / Double(imageSize), 0), 1)
            self.phase = .sending(progress: progress)
            self.status = "sending firmware"
            self.updateEstimate(bytesSent: bytesSent, imageSize: imageSize, at: timestamp)
        }
    }
}
