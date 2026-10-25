//
//  GenerationFigures.swift
//  M1K3Eval
//
//  What one trial's generations cost, folded from the app's own `ttft` and `reuse` log lines
//  (ChatCurveLogParser): prefill tokens and ms, the checkpoint extend the ttft line cannot see,
//  decode tokens, throughput, how many generations the turn ran, and when the first chunk reached
//  the stream. Until 2026-10-25 a scorecard carried wall-clock latency and think time only, so a
//  Debug-vs-Release gap, a prefill regression and a slow decode all read as the same number.
//
//  nil beats zero throughout: a path that logs no figure (Mini, PCC) has none.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-25, Confidence 0.85 (pure; pinned in ChatEvalJSONTests
//  and ChatCurveTests; the stage's log read is verify-by-launch). Prior: none (new file).
//

import Foundation

public struct GenerationFigures: Sendable, Equatable, Codable {
    /// Tokens the generates themselves prefilled (the `prompt=` figure, summed): past any cache seed,
    /// and ONE token per send in checkpoint mode — see `extendMS` for the rest.
    public let prefillTokens: Int?
    /// The generates' own prefill time (`prefill=`, summed).
    public let prefillMS: Int?
    /// Checkpoint-mode sends prefill the transcript past the seed in `prefillExactly`, outside the
    /// generate the ttft line times. The reuse line carries that time (`extend=`); summed here.
    public let extendMS: Int?
    public let decodeTokens: Int?
    /// Total decode tokens over total decode time across the turn's generations (not a mean of
    /// the per-line figures: a 2-token send must not pull a 200-token one).
    public let tokensPerSecond: Double?
    public let generations: Int
    /// Turn start → the first chunk on the stream (thinking included), as the eval's clock saw it.
    public let firstChunkMS: Int?

    public init(
        prefillTokens: Int?, prefillMS: Int?, extendMS: Int?, decodeTokens: Int?, tokensPerSecond: Double?,
        generations: Int, firstChunkMS: Int?
    ) {
        self.prefillTokens = prefillTokens
        self.prefillMS = prefillMS
        self.extendMS = extendMS
        self.decodeTokens = decodeTokens
        self.tokensPerSecond = tokensPerSecond
        self.generations = generations
        self.firstChunkMS = firstChunkMS
    }

    /// The prefill the trial really paid: the generates' own plus any checkpoint extend; nil when neither was seen.
    public var totalPrefillMS: Int? {
        switch (prefillMS, extendMS) {
        case (nil, nil): nil
        case let (prefill, extend): (prefill ?? 0) + (extend ?? 0)
        }
    }
}
