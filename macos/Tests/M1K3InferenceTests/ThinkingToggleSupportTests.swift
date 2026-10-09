import M1K3Inference
import Testing

/// Kev, 2026-09-26: hide the Reasoning picker until Lil runs a model that can
/// actually switch its thinking on and off. Lil was then Qwen3-4B-Instruct-2507,
/// which never thinks; since 2026-10-08 it is Qwen3.5-4B, which does.
struct ThinkingToggleSupportTests {
    @Test("the families whose templates read enable_thinking")
    func families() {
        #expect(ThinkingToggleSupport.readsToggle(modelName: "mlx-community/Qwen3-4B-4bit"))
        #expect(ThinkingToggleSupport.readsToggle(modelName: "mlx-community/Qwen3.5-9B-4bit"))
        #expect(ThinkingToggleSupport.readsToggle(modelName: "prism-ml/Ternary-Bonsai-27B-mlx"))
        #expect(!ThinkingToggleSupport.readsToggle(modelName: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"))
        #expect(!ThinkingToggleSupport.readsToggle(modelName: "mlx-community/gemma-4-12B-it-4bit"))
        #expect(!ThinkingToggleSupport.readsToggle(modelName: "mlx-community/LFM2.5-1.2B-Instruct-4bit"))
    }

    /// 2026-10-08: Lil is Qwen3.5-4B, which reads `enable_thinking` — the picker this
    /// test kept hidden for the 2507 comes back, as Kev's 2026-09-26 rule intended.
    @Test("the picker follows Lil's model: shown for Qwen3.5 Lil, hidden for the 2507")
    func pickerFollowsLil() {
        #expect(ThinkingToggleSupport.showsReasoningPicker(lilModelID: BrainTier.lil.mlxModelID))
        #expect(!ThinkingToggleSupport.showsReasoningPicker(lilModelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"))
        #expect(ThinkingToggleSupport.showsReasoningPicker(lilModelID: "mlx-community/Qwen3.5-4B-4bit"))
        #expect(!ThinkingToggleSupport.showsReasoningPicker(lilModelID: nil))
    }
}
