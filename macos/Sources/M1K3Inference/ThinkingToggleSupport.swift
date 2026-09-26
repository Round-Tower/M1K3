//
//  ThinkingToggleSupport.swift
//  M1K3Inference
//
//  Which models can switch their thinking phase on and off, by NAME, and
//  whether Settings offers the Reasoning picker. The rule lived in
//  MLXBrainProvider (it decides whether `enable_thinking` is sent); it moved
//  here so the app can ask it without importing MLX, and MLX delegates to it.
//
//  The picker follows Lil (Kev, 2026-09-26: "hide the Reasoning Picker until we
//  do have a Lil model that supports it"). Today's Lil, Qwen3-4B-Instruct-2507,
//  never thinks; Big's gemma-4 toggle is pinned off; Mini and Pocket have no
//  think phase. So the picker was a dead control on every shipping brain.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.85 (the name rule is
//  MLXBrainProvider's, moved verbatim and still pinned by its tests).
//  Prior: MLXBrainProvider.templateSupportsThinkingToggle.
//

import Foundation

public enum ThinkingToggleSupport {
    /// Whether the model's chat template reads `enable_thinking`.
    ///
    /// "qwen3" matches Qwen3-4B/8B AND every Qwen3.5 spelling. The 2507 refresh
    /// is EXCLUDED: Qwen split it into fixed-mode variants (Instruct never
    /// thinks, Thinking always does) and dropped enable_thinking from both
    /// templates (verified 2026-07-16). Bonsai-27B's qwen3_5 template reads it
    /// (verified 2026-07-17); the 8B's carries no switch.
    public static func readsToggle(modelName: String) -> Bool {
        let name = modelName.lowercased()
        return (name.contains("qwen3") && !name.contains("2507"))
            || name.contains("ternary-bonsai-27b")
    }

    /// Settings shows the Reasoning picker only when Lil can honour it.
    public static func showsReasoningPicker(lilModelID: String?) -> Bool {
        lilModelID.map(readsToggle(modelName:)) ?? false
    }
}
