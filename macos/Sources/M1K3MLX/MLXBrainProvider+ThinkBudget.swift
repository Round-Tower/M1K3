//
//  MLXBrainProvider+ThinkBudget.swift
//  M1K3MLX
//
//  Budget forcing on the plain turn, Lil's by default and argv's `-thinkBudgetTokens N` (see ThinkBudget):
//  mlx-swift-lm's `ThinkingBudgetProcessor` counts reasoning tokens and, at the budget, forces the
//  transition and `</think>` through the normal sampling loop, so the KV cache, the stream and the
//  answer all carry on from the cut thought. Qwen3.5's protocol ships no declared transition
//  (`thinkTagsWithEnableThinking` names none on purpose), so the arm supplies its own: that is the
//  opt-in the library asks for, and the eval is the validation it asks for. The NoWait arm
//  (`-thinkWaitPenalty P`) adds `ThoughtWordPenalty` to the same components; either arm runs alone.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.7, Prior: none (new file).
//  Open: the tool session (MLXToolCalling) is not budgeted: Qwen3.5 may open `<tool_call>` from a thought.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the NoWait arm (`-thinkWaitPenalty P`, ThinkBudget.NoWait) rides
//  the same components: `ThoughtWordPenalty` pushes the openers down until the thought closes. Both arms are
//  optional and compose; empty components still mean the default path. Confidence 0.65, verify-by-launch owed
//  (the `nowait` notice naming the single-token spellings it found).
//  Review: Kev + claude-opus-5-5, 2026-10-19 — verified by launch on the eval builds: `thinking budget 1024 tokens`
//  with every Always turn closing its thought and answering (38/38 hard trials, 0 empty), and the `nowait` notice
//  naming 10 single-token spellings on Qwen3.5 (bare "hmm" isn't one). Comment only. Confidence 0.75.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — `ThinkBudgetForcing`: the provider tells the responder's cut the
//  budget it forces (template-scoped, whatever the build's thinking flag), so the cut stands back to a net on every
//  shell. NoWait pushes down the words read at init (`-thinkWaitWords`). Confidence 0.8.

import Foundation
import M1K3Inference
import MLX
import MLXLMCommon

extension MLXBrainProvider: ThinkBudgetForcing {
    /// The budget this brain forces when a generation thinks: read by the responder's cut, which may sit outside
    /// the turn's thinking decision, so it follows the template, not `effectiveThinking`.
    public var forcedThinkingTokens: Int? {
        ThinkBudget.tokens(
            for: thinkBudgetRequest,
            maxTokens: generateParameters.maxTokens ?? Self.defaultMaxTokens,
            preOpenedThinking: preOpensThinkTemplate
        )
    }

    /// This generation's thinking budget in tokens: nil when the arm is off or the turn isn't thinking.
    func thinkBudgetTokens(parameters: GenerateParameters) -> Int? {
        ThinkBudget.tokens(
            for: thinkBudgetRequest,
            maxTokens: parameters.maxTokens ?? Self.defaultMaxTokens,
            preOpenedThinking: thinkPrefixNeeded
        )
    }

    /// This generation's NoWait penalty: nil when the arm is off or the turn isn't thinking.
    func thinkWaitPenalty() -> Float? {
        ThinkBudget.NoWait.penalty(for: thinkWaitPenaltyRequest, preOpenedThinking: thinkPrefixNeeded)
    }

    /// Components for this generation's thinking arms: the forced close at `budget` tokens and the NoWait
    /// penalty, either or both. Empty components when both are nil; an arm the library or tokenizer refuses is
    /// logged and dropped, and the turn thinks without it rather than failing.
    func thinkingComponents(
        budget: Int?,
        waitPenalty: Float?,
        tokenizer: any MLXLMCommon.Tokenizer,
        label: String
    ) -> GenerationComponents {
        var components = GenerationComponents()
        if let budget, let transition = thinkBudgetRequest?.transition {
            do {
                let configuration = try ThinkingBudgetConfiguration(
                    maximumTokenCount: budget,
                    minimumAnswerTokenCount: ThinkBudget.answerReserve,
                    transitionOverride: ReasoningBudgetTransition(
                        beforeEndDelimiter: transition.beforeClose,
                        afterEndDelimiter: transition.afterClose
                    )
                )
                components = try components.applyingThinkingBudget(
                    configuration, reasoning: .thinkTagsWithEnableThinking, tokenizer: tokenizer
                ) { diagnostic in
                    mlxTTFTLog.notice(
                        "\(label, privacy: .public): thinking budget stood down — \(String(describing: diagnostic), privacy: .public)"
                    )
                }
                mlxTTFTLog.notice(
                    "\(label, privacy: .public): thinking budget \(budget) tokens, transition \(transition.rawValue, privacy: .public)"
                )
            } catch {
                mlxTTFTLog.error(
                    "\(label, privacy: .public): thinking budget refused (\(error.localizedDescription, privacy: .public)) — unbudgeted"
                )
            }
        }
        if let waitPenalty {
            components = appendingNoWait(to: components, penalty: waitPenalty, tokenizer: tokenizer, label: label)
        }
        return components
    }

    /// NoWait: penalise every opener spelling the tokenizer holds as ONE token (a split spelling's first piece
    /// starts other words too, so it is left alone), until the thought's `</think>` is sampled.
    private func appendingNoWait(
        to components: GenerationComponents,
        penalty: Float,
        tokenizer: any MLXLMCommon.Tokenizer,
        label: String
    ) -> GenerationComponents {
        var found: [String] = []
        var ids: [Int] = []
        for spelling in ThinkBudget.NoWait.spellings(of: thinkWaitWords) {
            let encoded = tokenizer.encode(text: spelling, addSpecialTokens: false)
            if encoded.count == 1, !ids.contains(encoded[0]) {
                found.append(spelling)
                ids.append(encoded[0])
            }
        }
        let close = tokenizer.encode(text: "</think>", addSpecialTokens: false)
        guard close.count == 1, !ids.isEmpty else {
            mlxTTFTLog.error(
                "\(label, privacy: .public): nowait refused (</think> is \(close.count) tokens, \(ids.count) openers) — off"
            )
            return components
        }
        let names = found.map { "\"\($0)\"" }.joined(separator: " ")
        mlxTTFTLog.notice(
            "\(label, privacy: .public): nowait penalty \(penalty) on \(ids.count) tokens: \(names, privacy: .public)"
        )
        let closeID = close[0], tokenIDs = ids
        return components.appendingLogitProcessor {
            ThoughtWordPenalty(tokenIDs: tokenIDs, penalty: penalty, closeID: closeID)
        }
    }
}

/// NoWait's logit processor: subtracts `penalty` from `tokenIDs` until the thought's `</think>` is sampled. It
/// reads each sampled token one step late (the budget processor's pipelining: `item` on the newest token would
/// idle the GPU), so the token after `</think>` is still penalised; that token is the answer's leading newline.
struct ThoughtWordPenalty: LogitProcessor {
    private let indices: MLXArray
    private let maxID: Int
    private let penalty: Float
    private let closeID: Int
    private var thinking = true
    private var pending: MLXArray?

    init(tokenIDs: [Int], penalty: Float, closeID: Int) {
        indices = MLXArray(tokenIDs.map(UInt32.init))[.newAxis, 0...]
        maxID = tokenIDs.max() ?? 0
        self.penalty = penalty
        self.closeID = closeID
    }

    mutating func prompt(_: MLXArray) {
        thinking = true
        pending = nil
    }

    func process(logits: MLXArray) -> MLXArray {
        // An id past the logits means the tokenizer and the weights disagree: leave the logits alone.
        guard thinking, maxID < logits.dim(-1) else { return logits }
        let pushed = takeAlong(logits, indices, axis: -1) - penalty
        return putAlong(logits, indices, values: pushed, axis: -1)
    }

    mutating func didSample(token: MLXArray) {
        guard thinking else { return }
        if let previous = pending, previous.item(Int.self) == closeID {
            thinking = false
            pending = nil
            return
        }
        pending = token
    }
}
