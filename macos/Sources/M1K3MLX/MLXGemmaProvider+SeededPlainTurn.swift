//
//  MLXGemmaProvider+SeededPlainTurn.swift
//  M1K3MLX
//
//  The plain-chat turn (`generate` / `generateStreaming`) on a seeded persona
//  prefix — rendered as ONE `[system, user]` template pass and prefilled only
//  past the seed, the way MLXToolTurnSession has always done it.
//
//  Why not upstream `ChatSession(cache:)` any more: a raw cache carries no
//  transcript, so upstream renders each new turn ALONE (`[user]` through the
//  template — its own doc calls this "fragment-based continuation"). On a
//  template that opens with `bos_token` (LFM2, Llama) that puts a second
//  start-of-text right after the cached persona, and the model reads what
//  follows as a new document: pocket answered every leak fixture like a bare
//  base model (security 0/14, 1/7 reproduced) while the tool path — same
//  persona, same weights, whole-conversation render — held. Proven by byte
//  replay in mlx-lm: the extra token alone turns 18/35 into 1/7.
//  Qwen's template has no BOS, so Lil/Big never showed it (Big isn't seeded
//  at all — its persona overruns the sliding window). See SeededPlainTurnTests.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.85 (the slice is
//  pinned in SeededPlainTurnTests; the render + generate is verify-by-launch
//  through SelfTest security on pocket AND Lil — one seam for every seeded
//  MLX tier). Prior: Kev + claude-fable-5 (MLXGemmaProvider plain paths).
//

import Foundation
import MLX
import MLXLMCommon

extension MLXGemmaProvider {
    /// Run one plain turn on `seed`. `onChunk` receives generated text as it
    /// streams; the whole render's token count is what the info line reports
    /// (the seed is part of the context the model sees, not free).
    func runSeededPlainTurn(
        container: ModelContainer,
        seed: PersonaPrefixSnapshot,
        persona: String,
        prompt: String,
        label: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws {
        // `persona` is the KEY's own text — the caller derives the key once and
        // hands both the snapshot and its text over, so a profile or date line
        // landing between the two reads cannot make the render disagree with
        // the seed. Same `seedInputs` on both sides: the full render's prefix is
        // the seed's ids by construction, not by luck.
        let seedInputs = MLXToolMapping.seedInputs(
            persona: persona, specs: nil, format: resolvedToolCallFormat ?? .json
        )
        let parameters = generateParameters
        let thinkingContext = thinkingAdditionalContext
        let model = modelIdentifier
        let seedIDs = seed.tokenIDs
        // `@unchecked Sendable` box: the cache crosses into `perform` exactly the
        // way MLXToolTurnSession's does (evaluated by the prefill that built it).
        struct SeedBox: @unchecked Sendable {
            let cache: [KVCache]
        }
        let box = SeedBox(cache: seed.cache)

        try await container.perform { context in
            let prepared = try await context.processor.prepare(
                input: UserInput(
                    chat: [
                        Chat.Message(role: .system, content: seedInputs.system),
                        Chat.Message(role: .user, content: prompt),
                    ],
                    tools: seedInputs.specs,
                    additionalContext: thinkingContext
                )
            )
            let fullIDs = prepared.text.tokens.asArray(Int.self)
            let cache: [KVCache]
            let input: LMInput
            switch SeededPlainTurn.plan(seed: seedIDs, full: fullIDs) {
            case let .reuse(prefixTokens):
                cache = box.cache
                input = LMInput(tokens: MLXArray(Array(fullIDs[prefixTokens...])))
            case .fresh:
                // Correct, just unoptimised — and worth a line, because a seed
                // that stops being a prefix of its own render is the tojson /
                // persona-drift class of bug, not a normal turn. Decode either
                // side of the first divergence so the cause is readable in the
                // log (the tool path's seed-miss instrument, same idea).
                var at = 0
                while at < min(seedIDs.count, fullIDs.count), seedIDs[at] == fullIDs[at] {
                    at += 1
                }
                let window = { (ids: [Int]) -> String in
                    let lo = max(0, at - 4), hi = min(ids.count, at + 8)
                    return lo < hi ? context.tokenizer.decode(tokenIds: Array(ids[lo ..< hi])) : ""
                }
                mlxTTFTLog.notice(
                    "\(label, privacy: .public): persona seed (\(seedIDs.count)tok) is not a prefix of the \(fullIDs.count)tok render — full prefill; diverges at \(at): seed […\(window(seedIDs), privacy: .public)…] render […\(window(fullIDs), privacy: .public)…]"
                )
                cache = try context.model.newCache(parameters: parameters)
                input = prepared
            }
            let stream = try MLXLMCommon.generate(
                input: input, cache: cache, parameters: parameters, context: context
            )
            for await event in stream {
                switch event {
                case let .chunk(piece):
                    onChunk(piece)
                case let .info(info):
                    logGenerationInfo(info, label: label, model: model, totalContextTokens: fullIDs.count)
                default:
                    break
                }
            }
        }
    }
}
