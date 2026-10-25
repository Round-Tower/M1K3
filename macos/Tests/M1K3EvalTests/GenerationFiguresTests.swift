//
//  GenerationFiguresTests.swift
//  M1K3EvalTests
//
//  The scorecard's per-trial generation figures (2026-10-25): what the sum means and when it is
//  nothing. The JSON shape rides in ChatEvalJSONTests; the fold that produces them in ChatCurveTests.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-25, Confidence 0.9 (pure arithmetic). Prior: none (new file).
//

@testable import M1K3Eval
import Testing

struct GenerationFiguresTests {
    private func figures(prefill: Int?, extend: Int?) -> GenerationFigures {
        GenerationFigures(
            prefillTokens: nil, prefillMS: prefill, extendMS: extend, decodeTokens: nil, tokensPerSecond: nil,
            generations: 1, firstChunkMS: nil
        )
    }

    @Test("the total prefill is the generates' own plus the checkpoint extend")
    func totalPrefill() {
        // In checkpoint mode the generate's prefill is a one-token call; the extend is the transcript.
        #expect(figures(prefill: 40, extend: 2100).totalPrefillMS == 2140)
        #expect(figures(prefill: 812, extend: nil).totalPrefillMS == 812, "a non-checkpoint send has no extend")
        #expect(figures(prefill: nil, extend: 2100).totalPrefillMS == 2100)
    }

    @Test("no figure on either side is nil, never zero")
    func nothingSeen() {
        #expect(figures(prefill: nil, extend: nil).totalPrefillMS == nil)
    }
}
