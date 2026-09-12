//
//  MLXGemmaProvider+PromptCachePersistence.swift
//  M1K3MLX
//
//  PROTOTYPE probe (SelfTest-only today): proves the upstream
//  savePromptCache/loadPromptCache round-trip on the persona KV prefix —
//  build cold, persist to disk, reload, then generate seeded from the
//  RELOADED cache. If this holds at ⌘R, wiring PersonaPrefixCache to disk
//  (cold-launch first-turn TTFT win) is a follow-up with the policy already
//  tested. Verify-by-launch like all MLX generation; the naming/invalidation
//  core is PromptCachePolicy (pure, tested).
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.7, Prior: Unknown
//

import Foundation
import M1K3Inference
import MLXLMCommon

public extension MLXGemmaProvider {
    /// Full disk round-trip on the persona prefix, returning a human-readable
    /// report for the self-test log. Never throws — failures are the finding.
    func promptCacheRoundTripProbe(directory: URL) async -> String {
        let clock = ContinuousClock()
        do {
            let container = try await ensureLoaded()

            // 1. Build the persona prefix cold (the cost this feature deletes
            //    from every cold launch). The throwing core, so a failure
            //    reports its real error instead of the app path's silent nil.
            let buildStart = clock.now
            guard let seed = try await buildPersonaPrefixSnapshot(
                container: container, specs: nil, toolNames: []
            ) else {
                return "✗ kv-persist: prefix built but snapshot missing (store anomaly)"
            }
            let buildMS = (clock.now - buildStart).milliseconds

            // 2. Persist — the policy filename carries the full fingerprint.
            let fingerprint = PromptCachePolicy.Fingerprint(
                modelID: modelIdentifier,
                prefixText: M1K3Persona.systemPrompt(exemplars: personaExemplars),
                toolNames: [],
                kvBits: generateParameters.kvBits,
                kvGroupSize: generateParameters.kvGroupSize,
                kernelTag: MLXEmbeddingService.kernelTag
            )
            let url = directory.appendingPathComponent(PromptCachePolicy.fileName(for: fingerprint))
            let saveStart = clock.now
            try savePromptCache(
                url: url,
                cache: seed.cache,
                // Persist the token ids, not just the count — a disk-reloaded
                // prefix needs them to drive cross-turn reuse (the count is the
                // derived display value).
                metadata: ["tokenIDs": seed.tokenIDs.map(String.init).joined(separator: ",")]
            )
            let saveMS = (clock.now - saveStart).milliseconds
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

            // 3. Reload from disk.
            let loadStart = clock.now
            let (loaded, metadata) = try loadPromptCache(url: url)
            let loadMS = (clock.now - loadStart).milliseconds
            let reloadedIDs = metadata["tokenIDs"]
                .map { $0.split(separator: ",").compactMap { Int($0) } } ?? seed.tokenIDs
            let tokenCount = reloadedIDs.count
            let cacheClass = loaded.first.map { String(describing: type(of: $0)) } ?? "empty"

            // 4. The proof: a generation seeded with the RELOADED cache must
            //    still produce a coherent answer (corrupt KV derails output).
            let genStart = clock.now
            let answer = try await seededAnswer(
                container: container,
                seed: PersonaPrefixSnapshot(cache: loaded, tokenIDs: reloadedIDs)
            )
            let genMS = (clock.now - genStart).milliseconds

            let verdict = answer.localizedCaseInsensitiveContains("ok") ? "✓" : "✗"
            return """
            \(verdict) kv-persist round-trip (\(cacheClass) ×\(loaded.count), \(tokenCount) tok):
              build=\(buildMS)ms  save=\(saveMS)ms (\(bytes / 1024)KB)  load=\(loadMS)ms  seededGen=\(genMS)ms
              answer from reloaded cache: \(answer.prefix(80))
            """
        } catch {
            return "✗ kv-persist: \(error)"
        }
    }
}

private extension MLXGemmaProvider {
    /// One short generation from a session seeded with the given prefix.
    func seededAnswer(container: ModelContainer, seed: PersonaPrefixSnapshot) async throws -> String {
        let session = MLXToolTurnSession(
            container: container,
            modelID: modelIdentifier,
            parameters: generateParameters,
            // Probe-only fallback (production paths guard-throw on nil):
            // specs is nil so the format never renders a call here — it only
            // keeps the probe runnable on a dialect-less family.
            format: resolvedToolCallFormat ?? .gemma,
            specs: nil,
            thinkingContext: thinkingAdditionalContext,
            prefixNeeded: thinkPrefixNeeded,
            seed: seed
        )
        let turn = try await session.send(
            [.user("Reply with exactly the word OK and nothing else.")]
        ) { _ in }
        await session.finish()
        guard case let .text(text) = turn else { return "(unexpected tool call)" }
        return ModelEvalReport.strippingThink(text)
    }
}

private extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
