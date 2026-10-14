import Foundation

/// What the ring is doing, as it happens. Listen with `Museo.onEvent` or `Museo.events()`.
///
/// For what's on screen, read `RingModel.status` instead: it holds the current state
/// (linked, battery, live, syncing), where these are the moments it changes.
public enum RingEvent: Equatable, Sendable {
    /// A muse started streaming in (hold the ring), at this time.
    case liveStarted(Date)
    /// The ring stopped streaming. The finished muse reaches `Museo.onCapture` next.
    case liveEnded
    /// Bringing in recordings made on the ring's own storage (double click), this many.
    case syncStarted(count: Int)
    /// This many still to come in. Zero mid-sync means it stopped early.
    case syncProgress(remaining: Int)
    /// The sync stopped. Each recording that came in already reached `Museo.onCapture`.
    case syncEnded
}

/// Owns the ring manager's single-slot callbacks and hands each event to every listener.
@MainActor
final class RingEvents {
    static let shared = RingEvents()

    private var handlers: [(RingEvent) -> Void] = []
    private var continuations: [UUID: AsyncStream<RingEvent>.Continuation] = [:]

    private init() {}

    func attach(_ ble: RingBLEManager) {
        ble.onCaptureStateChange = { capturing, startedAt in
            RingEvents.deliver(capturing ? .liveStarted(startedAt ?? .now) : .liveEnded)
        }
        ble.onSyncStarted = { total in RingEvents.deliver(.syncStarted(count: total)) }
        ble.onSyncProgress = { remaining in RingEvents.deliver(.syncProgress(remaining: remaining)) }
        ble.onSyncEnded = { RingEvents.deliver(.syncEnded) }
    }

    /// The manager fires its callbacks from property observers, almost always on the main
    /// queue (its central runs there). Anything that isn't hops over, in order.
    nonisolated private static func deliver(_ event: RingEvent) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.send(event) }
        } else {
            DispatchQueue.main.async { shared.send(event) }
        }
    }

    func add(_ handler: @escaping (RingEvent) -> Void) {
        handlers.append(handler)
    }

    func stream() -> AsyncStream<RingEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RingEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { _ in
            Task { @MainActor in RingEvents.shared.continuations[id] = nil }
        }
        continuations[id] = continuation
        return stream
    }

    private func send(_ event: RingEvent) {
        for handler in handlers { handler(event) }
        for continuation in continuations.values { continuation.yield(event) }
    }
}
