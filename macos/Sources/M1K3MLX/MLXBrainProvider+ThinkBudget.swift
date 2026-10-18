//
//  MLXBrainProvider+ThinkBudget.swift
//  M1K3MLX
//
//  Budget forcing on the plain turn, the A/B arm behind `-thinkBudgetTokens N` (see ThinkBudget):
//  mlx-swift-lm's `ThinkingBudgetProcessor` counts reasoning tokens and, at the budget, forces the
//  transition and `</think>` through the normal sampling loop, so the KV cache, the stream and the
//  answer all carry on from the cut thought. Qwen3.5's protocol ships no declared transition
//  (`thinkTagsWithEnableThinking` names none on purpose), so the arm supplies its own: that is the
//  opt-in the library asks for, and the eval is the validation it asks for.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.7, Prior: none (new file).
//  Open: verify-by-launch owed (a `thinking budget` notice and a closed thought on an Always turn).
//  The tool session (MLXToolCalling) is not budgeted: Qwen3.5 may open `<tool_call>` from a thought.

import Foundation
import M1K3Inference
import MLXLMCommon

extension MLXBrainProvider {
    /// This generation's thinking budget in tokens: nil when the arm is off or the turn isn't thinking.
    func thinkBudgetTokens(parameters: GenerateParameters) -> Int? {
        ThinkBudget.tokens(
            for: thinkBudgetRequest,
            maxTokens: parameters.maxTokens ?? Self.defaultMaxTokens,
            preOpenedThinking: thinkPrefixNeeded
        )
    }

    /// Components that force the close at `budget` tokens; empty components when `budget` is nil, or
    /// when the library refuses the setup (logged, and the turn thinks unbudgeted rather than failing).
    func thinkBudgetComponents(
        _ budget: Int?,
        tokenizer: any MLXLMCommon.Tokenizer,
        label: String
    ) -> GenerationComponents {
        guard let budget, let transition = thinkBudgetRequest?.transition else { return GenerationComponents() }
        do {
            let configuration = try ThinkingBudgetConfiguration(
                maximumTokenCount: budget,
                minimumAnswerTokenCount: ThinkBudget.answerReserve,
                transitionOverride: ReasoningBudgetTransition(
                    beforeEndDelimiter: transition.beforeClose,
                    afterEndDelimiter: transition.afterClose
                )
            )
            let components = try GenerationComponents().applyingThinkingBudget(
                configuration, reasoning: .thinkTagsWithEnableThinking, tokenizer: tokenizer
            ) { diagnostic in
                mlxTTFTLog.notice(
                    "\(label, privacy: .public): thinking budget stood down — \(String(describing: diagnostic), privacy: .public)"
                )
            }
            mlxTTFTLog.notice(
                "\(label, privacy: .public): thinking budget \(budget) tokens, transition \(transition.rawValue, privacy: .public)"
            )
            return components
        } catch {
            mlxTTFTLog.error(
                "\(label, privacy: .public): thinking budget refused (\(error.localizedDescription, privacy: .public)) — unbudgeted"
            )
            return GenerationComponents()
        }
    }
}
