import Foundation

/// Strip chain-of-thought blocks from model output.
///
/// Handles matched pairs, Qwen3's lone `</think>` close (everything before it is
/// scratchpad), gemma-4's `<|channel>thought … <channel|>`, multiple blocks in
/// one response, and plain text passthrough. Shared by M1K3Calls (call
/// summaries) and M1K3Eval (scoring).
///
/// ★ It knew only `<think>` until 2026-08-12, and the deep summariser is the
/// resident MLX brain — which has been gemma-4 since 2026-07-15 and speaks the
/// CHANNEL dialect. So a call recorded on 2 Jul stored this as its Summary:
///
///     <|channel>thought Thinking Process: **Analyze the Request:** The user
///     wants me to analyze a short transcript snippet…
///
/// …and it stayed in the corpus, retrievable, injectable as grounding, for six
/// weeks. Two markers existed in this codebase and only one of them was here;
/// `ReasoningSplit` in M1K3Chat knew both. That is why the token table now lives
/// in ONE place (M1K3Inference, which M1K3Chat already depends on) and this type
/// is a thin alias over it — a second copy of a marker list is precisely how the
/// first one was missed.
public enum ThinkStripper {
    public static func strip(_ text: String) -> String {
        ReasoningSplit.split(text).answer
    }
}
