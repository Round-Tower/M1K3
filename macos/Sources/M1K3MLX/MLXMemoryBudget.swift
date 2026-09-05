//
//  MLXMemoryBudget.swift
//  M1K3MLX
//
//  Process-global MLX memory policy. MLX's Metal buffer cache grows to peak
//  usage and never shrinks by default (documented upstream: ml-explore/mlx
//  #742, #2668), which is how an easy query against a ~4GB model was holding
//  ~16GB of footprint. The fix is twofold: a small RAM-scaled cacheLimit so
//  freed buffers are returned instead of hoarded, and a memoryLimit as a
//  back-pressure safety net on small-RAM fleet Macs (allocations near the
//  limit wait on scheduled tasks rather than erroring).
//
//  The policy is a pure, tested function of physical RAM; the MLX.Memory
//  mutations are verify-by-launch (metallib only resolves inside the .app).
//  The limits are process-global and shared by the embedder and the LLM —
//  apply once, before any MLX work.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.7, Prior: Unknown
//  Context: cache-limit bands (32/64/128MB) chosen from Apple's LLMEval
//  example (20MB) scaled up for steady-state decode headroom; tune after the
//  before/after footprint measurement. memoryLimit = min(75% of physical RAM,
//  12 GB) — the 12 GB companion ceiling prevents a large-RAM Mac from letting
//  MLX grow to ~72–96 GB (the observed 73.9 GB Activity Monitor footprint).
//  Deliberately tighter than MLX's default (1.5x the device's recommended
//  working set) because M1K3 shares the machine with the user's real work.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — the ceiling is now a FLOOR the
//  per-tier `limit(accommodatingActiveBytes:)` raises for the brain that loaded
//  (`settle(label:)` after load/release), capped at 75% of RAM, desktop only.
//  Review fold, same day: settle is serialised (NSLock — the LLM and the embedder both
//  reclaim) and the raise is quantised to 512 MB so KV wobble never moves the limit.
//

import Foundation
import MLX
import os

public struct MLXMemoryBudget: Sendable, Equatable {
    /// Metal buffer-cache cap. Freed buffers beyond this are released to the
    /// OS instead of recycled — bounds the "grows to peak, never shrinks" pool.
    public let cacheLimitBytes: Int
    /// Allocator back-pressure threshold: near it, MLX waits on scheduled
    /// tasks instead of growing the footprint.
    public let memoryLimitBytes: Int

    private static let mebibyte = 1_048_576
    private static let gibibyte: UInt64 = 1_073_741_824

    /// Companion-app ceiling: generous enough for a 4B model + embedder +
    /// decode headroom, but NOT 75% of a 128 GB machine. Without this cap
    /// a large-RAM Mac lets MLX's Metal allocator grow to ~72–96 GB — the
    /// freed-buffer cache is bounded by `cacheLimit`, but the allocator's
    /// ACTIVE memory (model weights + KV caches + intermediates) fills
    /// `memoryLimit` because MLX uses back-pressure, not refusal.
    /// Which class of device the budget is for. macOS shares the machine with the
    /// user's real work (the 12 GB companion ceiling); iOS/visionOS must stay well
    /// under a per-app jetsam limit that is a FRACTION of physical RAM, so a far
    /// lower ceiling makes MLX back-pressure engage before the OS jetsams the app.
    public enum DeviceProfile: Sendable, Equatable {
        case desktop
        case mobile
    }

    private static let companionCeilingBytes = 12 * mebibyte * 1024 // 12 GB (macOS)
    /// iOS/visionOS ceiling: a 4-bit 4B brain + KV lives under 4 GB. iPhones stay on
    /// Mini (no MLX footprint), so this only bites on ≥16 GB iPads / Vision Pro.
    /// Tunable — verify against os_proc_available_memory() when the shell lands.
    private static let mobileCeilingBytes = 4 * mebibyte * 1024 // 4 GB (iOS/visionOS)

    /// The budget for a machine with the given physical RAM and device class.
    /// - Parameter overrideLimitGB: an operator escape hatch for measurement
    ///   (`defaults write app.m1k3 mlxMemoryLimitGB -int 24`). A brain whose
    ///   weights exceed the companion ceiling (Qwen3.8-27B-4bit is 14.7 GB
    ///   active against the 12 GB desktop ceiling) makes MLX back-pressure on
    ///   EVERY decode step — measured 2026-09-05 at 0.1–0.4 tok/s where the
    ///   4B sibling ran 49–84. The override lets the ceiling be raised for a
    ///   run without shipping a per-tier budget; clamped to 90% of physical
    ///   RAM so a typo cannot ask for more than the machine has. nil / ≤0 →
    ///   the standard ceiling.
    public static func budget(
        forPhysicalMemory physicalMemoryBytes: UInt64,
        profile: DeviceProfile = .desktop,
        overrideLimitGB: Int? = nil
    ) -> MLXMemoryBudget {
        let physicalGB = Double(physicalMemoryBytes) / Double(gibibyte)
        let cacheMB = switch physicalGB {
        case 32...: 128
        case 12...: 64
        default: 32
        }
        let ceiling = profile == .mobile ? mobileCeilingBytes : companionCeilingBytes
        let threeQuarters = Int(physicalMemoryBytes / 4 * 3)
        if let overrideLimitGB, overrideLimitGB > 0, profile == .desktop {
            // Clamp the GB figure BEFORE the multiply: `Int * Int` traps on overflow, and
            // this value is a human typing a raw integer into `defaults write` (a pasted
            // byte count is the obvious slip). Anything past 1 PB is nonsense and simply
            // resolves to the 90% clamp below.
            let saneGB = min(overrideLimitGB, 1_048_576)
            let requested = saneGB * mebibyte * 1024
            let ninetyPercent = Int(physicalMemoryBytes / 10 * 9)
            return MLXMemoryBudget(
                cacheLimitBytes: cacheMB * mebibyte,
                memoryLimitBytes: min(requested, ninetyPercent)
            )
        }
        return MLXMemoryBudget(
            cacheLimitBytes: cacheMB * mebibyte,
            memoryLimitBytes: min(threeQuarters, ceiling)
        )
    }

    /// The PER-TIER budget: what the process-global limit should be once a brain of
    /// `activeBytes` weights is resident. `budget(...)` is the floor a machine gets before
    /// anything loads (the 12 GB companion ceiling, or the operator override); a brain the
    /// floor cannot hold makes MLX back-pressure on EVERY decode step (Qwen3.8-27B-4bit,
    /// 14.7 GB active: 0.1–0.4 tok/s under the 12 GB ceiling, 10–16 tok/s at 24 GB —
    /// 2026-09-05, AC power). So the limit follows the tier that actually loaded:
    /// 1.5× its active weights (KV + intermediates headroom, the ratio the 24 GB run
    /// validated) rounded up to a 512 MB step, never below the floor, never above 75% of RAM unless the operator
    /// override already floored it higher (that override may reach 90%), and never on
    /// mobile (the jetsam ceiling is the law there). Driven by the MEASURED weights, not a
    /// table that drifts from the manifest — a tier's budget is what it weighs.
    public static func limit(
        accommodatingActiveBytes activeBytes: Int,
        physicalMemoryBytes: UInt64,
        profile: DeviceProfile = .desktop,
        overrideLimitGB: Int? = nil
    ) -> Int {
        let floor = budget(forPhysicalMemory: physicalMemoryBytes, profile: profile, overrideLimitGB: overrideLimitGB)
            .memoryLimitBytes
        guard profile == .desktop, activeBytes > 0 else { return floor }
        // Rounded up to a 512 MB step: `activeMemory` wobbles by tens of MB across turns
        // (KV + intermediates in the snapshot) and the limit must not chase every wobble.
        let step = 512 * mebibyte
        let needed = (activeBytes / 2 * 3 + step - 1) / step * step
        let threeQuarters = Int(physicalMemoryBytes / 4 * 3)
        return max(floor, min(needed, threeQuarters))
    }

    /// Re-settle the process-global limit around the brain that is resident NOW: called
    /// after a model loads (raise for a big tier) and from `reclaim` (after a release,
    /// fall back to the floor). Idempotent; logs only when the limit actually moves.
    /// Serialised: the LLM provider and the embedder are separate classes that both
    /// `reclaim`, and the read → compare → write on the process-global limit must not
    /// interleave (two racing settles could pin a just-loaded big brain to the small
    /// tier's floor and bring the back-pressure straight back).
    public static func settle(label: String) {
        applyOnce()
        settleLock.lock()
        defer { settleLock.unlock() }
        #if os(iOS) || os(visionOS)
            let profile = DeviceProfile.mobile
        #else
            let profile = DeviceProfile.desktop
        #endif
        let override = UserDefaults.standard.integer(forKey: "mlxMemoryLimitGB")
        let active = MLX.Memory.snapshot().activeMemory
        let target = limit(
            accommodatingActiveBytes: active, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            profile: profile, overrideLimitGB: override > 0 ? override : nil
        )
        let current = MLX.Memory.memoryLimit
        guard target != current else { return }
        MLX.Memory.memoryLimit = target
        log.notice("\(label, privacy: .public): memoryLimit \(current / mebibyte)MB → \(target / mebibyte)MB for \(active / mebibyte)MB active weights")
    }

    private static let log = Logger(subsystem: "app.m1k3", category: "mlx-memory")
    private static let settleLock = NSLock()

    /// One-shot application of this machine's budget to the process-global MLX
    /// memory state. Thread-safe and idempotent (static-let once token); call
    /// it from every MLX entry point that could run first — the earliest wins.
    public static func applyOnce() {
        _ = applied
    }

    private static let applied: Void = {
        #if os(iOS) || os(visionOS)
            let profile = DeviceProfile.mobile
        #else
            let profile = DeviceProfile.desktop
        #endif
        let override = UserDefaults.standard.integer(forKey: "mlxMemoryLimitGB")
        let budget = Self.budget(
            forPhysicalMemory: ProcessInfo.processInfo.physicalMemory, profile: profile,
            overrideLimitGB: override > 0 ? override : nil
        )
        if override > 0 { log.notice("memory limit OVERRIDE via defaults mlxMemoryLimitGB=\(override)") }
        MLX.Memory.cacheLimit = budget.cacheLimitBytes
        MLX.Memory.memoryLimit = budget.memoryLimitBytes
        let cacheMB = budget.cacheLimitBytes / mebibyte
        let limitMB = budget.memoryLimitBytes / mebibyte
        log.notice("applied budget: cacheLimit=\(cacheMB)MB memoryLimit=\(limitMB)MB")
    }()

    /// Return all cached Metal buffers to the OS. Call at the end of each
    /// generation so an agent turn's N generations don't compound peaks.
    public static func reclaim(label: String) {
        MLX.Memory.clearCache()
        logSnapshot(label: label)
        // After a release the resident weights are gone: fall back to the floor. After an
        // ordinary generation the target is unchanged and this is a snapshot + compare.
        settle(label: label)
    }

    /// Log MLX memory (active/cache/peak) plus the process physical
    /// footprint — the same number Activity Monitor's Memory column reports.
    /// Stream with:
    /// `log stream --predicate 'subsystem == "app.m1k3" AND category == "mlx-memory"'`
    public static func logSnapshot(label: String) {
        log.notice("\(snapshotDescription(label: label), privacy: .public)")
    }

    /// The same snapshot as `logSnapshot`, as a string — for the headless
    /// self-test report, which writes to a file instead of the unified log.
    public static func snapshotDescription(label: String) -> String {
        let snapshot = MLX.Memory.snapshot()
        let activeMB = snapshot.activeMemory / mebibyte
        let cacheMB = snapshot.cacheMemory / mebibyte
        let peakMB = snapshot.peakMemory / mebibyte
        let footprintMB = (physicalFootprintBytes() ?? 0) / UInt64(mebibyte)
        return "\(label) MB: active=\(activeMB) cache=\(cacheMB) peak=\(peakMB) footprint=\(footprintMB)"
    }

    /// `phys_footprint` from task_vm_info — Activity Monitor's "Memory".
    private static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
