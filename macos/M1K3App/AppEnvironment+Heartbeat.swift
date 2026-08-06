//
//  AppEnvironment+Heartbeat.swift
//  M1K3
//
//  The heartbeat engine: a coarse check loop that, every ~2h (pure
//  HeartbeatSchedulePolicy decision), gathers the Tier-A context the app
//  already holds — device snapshot, memories learned since the last pulse,
//  conversations touched, visiting-agent calls (only when the Agent Log
//  toggle is already on), a fun fact from the corpus — composes the
//  deterministic digest (the #102 guard: facts come from code, never from
//  the model), and asks the RESIDENT MLX brain to retell it as a short
//  narrative of the day (Kev's call: the best model the thermals allow —
//  never Mini/AFM). NarrativeGuard vets the retelling; on any failure the
//  digest IS the pulse.
//
//  Concurrency stance: the render goes through the ONE shared swappableMLX
//  instance, so a concurrent MCP ask serializes on the model container
//  rather than starting a second decode loop; chat/voice/delegation busy
//  states skip the pulse outright (policy gate), and modelLoad.isActive
//  covers downloads/warms. Store reads/writes run off the main actor
//  (the ConstellationWindow rule: no main-thread IO).
//
//  Privacy stance: pulses never enter the chat transcript (so
//  MemoryDistillation can never mint permanent facts from them), the store
//  is capped + backup-excluded + diagnostics-excluded, and the log carries
//  reasons and counts only — never pulse content.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.8 (engine logic
//  compiles + policy/composer/guard/store are unit-pinned; the live loop,
//  the render quality on Big/Lil, and the battery gate's feel are named
//  verify-owed — ⌘R with the toggle on, and gemma is prompt-fragile so the
//  narrative wants an A/B look before the toggle defaults on).
//  Prior: none (new file).
//

import AppKit
import Foundation
import M1K3AgentTools
import M1K3Heartbeat
import M1K3LogCore

extension AppEnvironment {
    private static let heartbeatLog = M1K3Log.logger(.heartbeat)
    /// Below this battery percentage (uncharged), the pulse skips the MLX
    /// render and ships the digest — a 12B narrative isn't worth the drain.
    private static let heartbeatRenderBatteryFloor = 50

    var heartbeatEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.heartbeatEnabledKey)
    }

    func setHeartbeatEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.heartbeatEnabledKey)
        Self.heartbeatLog.notice("heartbeat \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    /// Start the coarse check loop. Ten-minute ticks: cheap (a policy read),
    /// and the first tick lands ~10 min after launch so a pulse never
    /// competes with startup warm-up. A no-op while the toggle is off.
    func startHeartbeatLoop() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { break }
                await self?.heartbeatTickIfDue()
            }
        }
    }

    func heartbeatTickIfDue() async {
        guard heartbeatEnabled, let pulseStore = heartbeatStore, !heartbeatPulseInFlight else { return }
        let now = Date()
        let lastPulse = await Task.detached(priority: .utility) { try? pulseStore.latestDate() }.value

        let busy = chat.isResponding || voiceLoop != nil || deepDelegationTaskLabel != nil
            || modelLoad.isActive
        let decision = HeartbeatSchedulePolicy().decide(
            now: now,
            hour: Calendar.current.component(.hour, from: now),
            lastPulse: lastPulse,
            isBusy: busy,
            backgroundAllowed: Self.backgroundWorkAllowed()
        )
        guard case .fire = decision else {
            if case let .skip(reason) = decision, reason != .tooSoon {
                Self.heartbeatLog.notice("pulse skipped: \(reason.rawValue, privacy: .public)")
            }
            return
        }

        heartbeatPulseInFlight = true
        defer { heartbeatPulseInFlight = false }

        let startOfDay = Calendar.current.startOfDay(for: now)
        let since = lastPulse ?? startOfDay

        // Cheap main-actor reads first.
        let chatTitles = chat.conversationSummaries()
            .filter { $0.updatedAt >= since }
            .compactMap(\.title)
        let brainStatus = HeartbeatContext.BrainStatus(
            residentTierName: selectedBrain.displayName,
            downloadingModelName: nil // busy gate: a pulse never fires mid-download
        )

        // Heavy store reads off the main actor (no main-thread IO).
        let memoryStore = memoryStore
        let conversationLog = conversationLog
        let knowledgeStore = store
        let mcpLogOn = UserDefaults.standard.bool(forKey: Self.conversationLogEnabledKey)
        let gathered = await Task.detached(priority: .utility) {
            () -> (
                device: HeartbeatContext.Device,
                memory: HeartbeatContext.MemoryActivity?,
                mcp: HeartbeatContext.MCPActivity?,
                fact: HeartbeatContext.FunFact?,
                earlierToday: [String],
                pulsesToday: Int
            ) in
            let system = LiveSystemStatusProvider()
            let battery = system.batterySnapshot()
            let disk = try? system.diskSnapshot()
            let thermal: ThermalBand = switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .serious
            }
            let device = HeartbeatContext.Device(
                batteryPercent: battery?.percentage,
                isCharging: battery?.isCharging,
                diskFreeGB: disk.map { Double($0.availableBytes) / 1_000_000_000 },
                diskTotalGB: disk.map { Double($0.totalBytes) / 1_000_000_000 },
                uptimeHours: system.uptime() / 3600,
                thermal: thermal,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )

            let newMemories = (try? memoryStore?.memoriesCreated(since: since)) ?? []
            let memory: HeartbeatContext.MemoryActivity? = newMemories.isEmpty
                ? nil
                : .init(
                    newFactTitles: newMemories.map { $0.title ?? HeartbeatComposer.excerpt($0.text, maxLength: 60) },
                    supersededCount: 0 // needs a superseded_at column — logged follow-up
                )

            var mcp: HeartbeatContext.MCPActivity?
            if mcpLogOn, let activity = try? conversationLog?.activity(since: since), activity.callCount > 0 {
                mcp = .init(callCount: activity.callCount, topTools: activity.toolNames)
            }

            var fact: HeartbeatContext.FunFact?
            let today = (try? pulseStore.since(startOfDay)) ?? []
            if let items = try? knowledgeStore.allItems(limit: 200), !items.isEmpty {
                let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: now) ?? 0
                let pick = items[(dayOfYear + today.count) % items.count]
                if let chunk = try? knowledgeStore.chunks(forItem: pick.id).first {
                    fact = .init(text: HeartbeatComposer.excerpt(chunk.content), sourceTitle: pick.title)
                }
            }

            return (device, memory, mcp, fact, today.map(\.displayText), today.count)
        }.value

        let context = HeartbeatContext(
            date: now,
            device: gathered.device,
            memory: gathered.memory,
            chat: chatTitles.isEmpty ? nil : .init(touchedConversationTitles: chatTitles),
            mcp: gathered.mcp,
            brain: brainStatus,
            funFact: gathered.fact,
            earlierPulsesToday: gathered.earlierToday
        )

        guard HeartbeatEmptyRule.shouldPulse(
            hasActivity: context.hasActivity,
            isFirstPulseToday: gathered.pulsesToday == 0
        ) else {
            Self.heartbeatLog.notice("pulse withheld: quiet window, not the day's first")
            return
        }

        let digest = HeartbeatComposer.digest(from: context)
        let (narrative, renderedBy) = await renderHeartbeatNarrative(
            digest: digest,
            earlierToday: gathered.earlierToday,
            device: gathered.device
        )

        await Task.detached(priority: .utility) {
            pulseStore.record(digest: digest, narrative: narrative, renderedBy: renderedBy, at: now)
        }.value
        heartbeatRevision += 1
        Self.heartbeatLog.notice(
            "pulse recorded by \(renderedBy, privacy: .public) (activity: \(context.hasActivity, privacy: .public))"
        )
        await maybeNotifyHeartbeatPulse(text: narrative ?? digest, appActive: NSApp.isActive)
    }

    /// Kev's model rule: the most capable teller the machine can afford right
    /// now — the resident MLX brain (Big or Lil) when it's loaded, cool, and
    /// not on a thin battery; otherwise the deterministic digest stands.
    /// Mini/AFM is deliberately NOT in this chain.
    private func renderHeartbeatNarrative(
        digest: String,
        earlierToday: [String],
        device: HeartbeatContext.Device
    ) async -> (narrative: String?, renderedBy: String) {
        guard selectedBrain.mlxModelID != nil, modelLoad == .ready else {
            return (nil, "digest")
        }
        if let battery = device.batteryPercent, device.isCharging != true,
           battery < Self.heartbeatRenderBatteryFloor
        {
            Self.heartbeatLog.notice("render skipped: battery floor")
            return (nil, "digest")
        }
        let prompt = HeartbeatPrompt.render(digest: digest, earlierToday: earlierToday)
        guard let raw = try? await swappableMLX.generate(prompt: prompt) else {
            Self.heartbeatLog.notice("render failed: generate error — digest ships")
            return (nil, "digest")
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NarrativeGuard.validate(narrative: cleaned, digest: digest) else {
            Self.heartbeatLog.notice("render rejected by NarrativeGuard — digest ships")
            return (nil, "digest")
        }
        return (cleaned, selectedBrain.displayName)
    }
}
