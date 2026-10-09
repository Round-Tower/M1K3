//
//  SeededPrefillProbeTests.swift
//  M1K3MLXTests
//
//  The pure halves of the seeded-prefill probe: the verdict that compares a seeded
//  continuation's next-token logits with a full prefill's, the probe text, and the split.
//  The probe itself is MLX (metallib wall): verify-by-launch through
//  `M1K3_SELFTEST_SEEDPROBE`.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).
//

@testable import M1K3MLX
import Testing

struct SeededPrefillProbeTests {
    @Test("identical logits are consistent, with zero drift")
    func identicalIsConsistent() throws {
        let logits: [Float] = [0.1, 2.5, -1.0, 0.7]
        let verdict = try #require(SeededPrefillVerdict.judge(full: logits, seeded: logits))
        #expect(verdict.consistent)
        #expect(verdict.maxAbsDiff == 0)
        #expect(verdict.argmaxFull == 1)
        #expect(verdict.argmaxSeeded == 1)
    }

    @Test("small numeric drift within tolerance, same top token: consistent")
    func driftWithinTolerance() throws {
        let verdict = try #require(SeededPrefillVerdict.judge(
            full: [0.1, 2.5, -1.0], seeded: [0.2, 2.3, -0.9], tolerance: 0.5
        ))
        #expect(verdict.consistent)
        #expect(abs(verdict.maxAbsDiff - 0.2) < 1e-5)
    }

    @Test("a different top token is inconsistent even when the drift is small")
    func topTokenFlipIsInconsistent() throws {
        let verdict = try #require(SeededPrefillVerdict.judge(
            full: [1.00, 1.05], seeded: [1.06, 1.05], tolerance: 1
        ))
        #expect(verdict.argmaxFull == 1)
        #expect(verdict.argmaxSeeded == 0)
        #expect(!verdict.consistent)
    }

    @Test("same top token but drift past tolerance is inconsistent (positions shift every logit)")
    func largeDriftIsInconsistent() throws {
        let verdict = try #require(SeededPrefillVerdict.judge(
            full: [0, 9, 1], seeded: [3, 12, -2], tolerance: 1
        ))
        #expect(verdict.argmaxFull == verdict.argmaxSeeded)
        #expect(!verdict.consistent)
    }

    @Test("ties resolve to the first index, so a tie never reads as a flip")
    func tiesTakeFirstIndex() {
        #expect(SeededPrefillVerdict.argmax([3, 7, 7, 1]) == 1)
    }

    @Test("unscorable inputs are nil, never a silent pass", arguments: [
        ([Float](), [Float]()),
        ([Float(1), 2], [Float(1)]),
        ([Float(1), .nan], [Float(1), 2]),
        ([Float(1), 2], [Float(1), .infinity]),
    ])
    func unscorableIsNil(full: [Float], seeded: [Float]) {
        #expect(SeededPrefillVerdict.judge(full: full, seeded: seeded) == nil)
    }

    @Test("the report line names the verdict and the numbers behind it")
    func lineCarriesTheNumbers() throws {
        let verdict = try #require(SeededPrefillVerdict.judge(full: [0, 1], seeded: [0, 1]))
        #expect(verdict.line.contains("CONSISTENT"))
        #expect(verdict.line.contains("top 1/1"))
        let bad = try #require(SeededPrefillVerdict.judge(full: [0, 9], seeded: [9, 0]))
        #expect(bad.line.contains("DIVERGES"))
    }

    @Test("probe text is deterministic and every line is distinct (no repeated n-grams to coast on)")
    func probeTextIsDeterministic() {
        let text = SeededPrefillProbe.probeText(lines: 40)
        #expect(text == SeededPrefillProbe.probeText(lines: 40))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 40)
        #expect(Set(lines).count == 40)
    }

    @Test("split keeps the suffix at the tail and refuses a prompt too short to seed")
    func splitPoint() {
        #expect(SeededPrefillProbe.splitPoint(tokenCount: 100, suffix: 24) == 76)
        #expect(SeededPrefillProbe.splitPoint(tokenCount: 30, suffix: 24) == nil)
        #expect(SeededPrefillProbe.splitPoint(tokenCount: 100, suffix: 0) == nil)
    }
}
