import M1K3Inference
import Testing

/// Kev, 2026-09-26: hide the Reasoning picker until Lil runs a model that can
/// actually switch its thinking on and off. Today's Lil (Qwen3-4B-Instruct-2507)
/// never thinks, so the picker was a dead control.
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

    @Test("the picker follows Lil's model: hidden for today's Lil")
    func pickerFollowsLil() {
        #expect(!ThinkingToggleSupport.showsReasoningPicker(lilModelID: BrainTier.lil.mlxModelID))
        #expect(ThinkingToggleSupport.showsReasoningPicker(lilModelID: "mlx-community/Qwen3.5-4B-4bit"))
        #expect(!ThinkingToggleSupport.showsReasoningPicker(lilModelID: nil))
    }
}
