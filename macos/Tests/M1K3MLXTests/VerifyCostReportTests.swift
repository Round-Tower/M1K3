@testable import M1K3MLX
import Testing

/// The verify-cost probe's report (the timing itself is verify-by-launch: MLX runs only inside the app).
struct VerifyCostReportTests {
    @Test("each width reads as a multiple of one token, with the speed-up a perfect drafter could reach")
    func ratiosAndCeilings() {
        let report = MLXBrainProvider.verifyCostReport(
            model: "lil", prefixTokens: 1828, bestMilliseconds: [1: 10, 2: 18.6, 4: 36.1]
        )
        #expect(report.contains("1828-token prefix"))
        #expect(report.contains("T=1: 10.0 ms = 1.00x one token; a perfect drafter tops out at 1.00x"))
        // The 2026-09-26 record: two tokens at 1.86x caps a perfect drafter near 1.07x.
        #expect(report.contains("T=2: 18.6 ms = 1.86x one token; a perfect drafter tops out at 1.08x"))
        #expect(report.contains("T=4: 36.1 ms = 3.61x one token; a perfect drafter tops out at 1.11x"))
    }

    @Test("without a single-token timing there is nothing to compare against")
    func noBaseline() {
        #expect(MLXBrainProvider.verifyCostReport(model: "lil", prefixTokens: 1, bestMilliseconds: [2: 5])
            == "verify cost: no single-token timing")
    }
}
