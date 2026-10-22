//
//  NetworkPathWatch.swift
//  M1K3Avatar
//
//  The shells' one observable answer to "is this device offline right now?" — the input
//  behind Offline AI Flight Club (`SeasonalLook.now(enabled:offline:)`). A single NWPathMonitor
//  starts lazily with `shared` and PUBLISHES changes (Observation), so the avatar never polls
//  path state at 30 Hz: a view that reads `isOffline` in its body / update closure re-runs
//  only when the network actually changes.
//
//  Honest by design: only `.unsatisfied` is offline. `.requiresConnection` (an on-demand VPN,
//  a sleeping cellular radio) counts as ONLINE, and so does a captive portal (in-flight Wi-Fi
//  joined but unpaid reports `.satisfied`): a missed offline moment goes unnoticed, a false
//  "you're offline" greeting is a lie. Starts online so the first frame is never wrongly in
//  flight colours. This is its own monitor, independent of the brain-upgrade ladder's
//  (AppEnvironment+BrainUpgrade.swift): one monitor per concern, two lifecycles not coupled.
//
//  Signed: Kev + claude-sonnet-5.5, 2026-10-22, Confidence 0.8 (the status mapping is pinned by
//  tests; the live monitor needs real Airplane Mode on a device — the Simulator follows the Mac's
//  network). Prior: none (new file).
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — review fold: path updates flow through ONE AsyncStream and
//  one consumer, so two quick flips apply in order (`updatesApplyInOrder`); the `.unsatisfied`-only rule is
//  kept on purpose (header) and named in the PR body as a departure from the spec. Confidence 0.85.
//

import Network
import Observation

@MainActor
@Observable
public final class NetworkPathWatch {
    /// The one watch per process.
    public static let shared = NetworkPathWatch()

    /// True while there is no usable network path. False until the first path update says otherwise.
    public private(set) var isOffline = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var consumer: Task<Void, Never>?

    /// `monitoring: false` builds an inert watch for tests (drive it with `apply(offline:)`).
    convenience init(monitoring: Bool = true) {
        guard monitoring else {
            self.init(updates: AsyncStream<Bool> { $0.finish() })
            return
        }
        // The handler runs on the monitor's own queue: reduce the path to a Bool there and yield it
        // into one stream. A single consumer applies the Bools in arrival order, so two quick flips
        // can never land reversed (a Task per update gives no such guarantee).
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .unbounded)
        self.init(updates: updates)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            continuation.yield(Self.isOffline(path.status))
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "app.m1k3.network-path-watch"))
        self.monitor = monitor
    }

    /// The seam: applies each Bool from `updates`, in order, on the main actor.
    init(updates: AsyncStream<Bool>) {
        consumer = Task { @MainActor [weak self] in
            for await offline in updates {
                guard let self else { return }
                apply(offline: offline)
            }
        }
    }

    isolated deinit {
        monitor?.cancel()
        consumer?.cancel()
    }

    /// Returns once the update stream has finished and every update is applied (tests only).
    func drained() async {
        await consumer?.value
    }

    /// Only an unsatisfied path is offline; see the file header for why `.requiresConnection` is not.
    public nonisolated static func isOffline(_ status: NWPath.Status) -> Bool {
        status == .unsatisfied
    }

    func apply(offline: Bool) {
        if isOffline != offline { isOffline = offline }
    }
}
