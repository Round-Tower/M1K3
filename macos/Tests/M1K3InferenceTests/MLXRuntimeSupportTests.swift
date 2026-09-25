//
//  MLXRuntimeSupportTests.swift
//  M1K3InferenceTests
//
//  Where MLX can run at all. Two ways it can't: the Simulator (no Metal GPU —
//  touching MLX aborts), and Apple GPU family 5 (A12 / A12X / A12Z), whose
//  compiler cannot build MLX's kernels (MTLCompilerService: "unable to legalize
//  … bfloat" → mlx-swift's handler traps). Seen twice: Mini/LFM2 (#236) and
//  M1K3 Voice on an iPad 8th gen (2026-09-25).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-25, Confidence 0.85. Prior: none (new file).
//

import M1K3Inference
import Testing

struct MLXRuntimeSupportTests {
    @Test("a real device with an A13-or-later GPU runs MLX")
    func modernDevice() {
        let support = MLXRuntimeSupport.resolve(isSimulator: false, gpuSupportsApple6: true)
        #expect(support == .available)
        #expect(support.isAvailable)
        #expect(support.voiceNote == nil)
        #expect(support.brainFallbackNote(tierName: "Lil") == nil)
    }

    @Test("the Simulator never touches MLX, whatever the host GPU reports")
    func simulator() {
        let support = MLXRuntimeSupport.resolve(isSimulator: true, gpuSupportsApple6: true)
        #expect(support == .simulator)
        #expect(!support.isAvailable)
        #expect(support.voiceNote == "M1K3 Voice runs on a real device.")
        #expect(support.brainFallbackNote(tierName: "Lil")
            == "Lil runs on a real device — the Simulator has no GPU for MLX. Staying on Mini.")
    }

    @Test("GPU family 5 (A12) is refused — its compiler can't build MLX's kernels")
    func a12GPU() {
        let support = MLXRuntimeSupport.resolve(isSimulator: false, gpuSupportsApple6: false)
        #expect(support == .gpuTooOld)
        #expect(!support.isAvailable)
        #expect(support.voiceNote == "M1K3 Voice needs a newer chip than this device has. Built-in works here.")
        #expect(support.brainFallbackNote(tierName: "Lil")
            == "Lil needs a newer chip than this device has. Staying on Mini.")
    }
}
