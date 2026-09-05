//
//  ChatEvalModelOverrideTests.swift
//  M1K3EvalTests
//
//  The A/B hook M1K3_SELFTEST_CHATEVAL_MLX_MODEL used to apply to EVERY MLX
//  tier in a run, so `_BRAINS=lil,big` + one override silently ran one model
//  twice under two column names — every past two-brain A/B is suspect. These
//  pin the policy: a bare id applies only when exactly one MLX brain is
//  selected; a per-tier form (`lil=…,big=…`) targets by name; anything
//  ambiguous is REFUSED loudly, never guessed.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: Unknown

@testable import M1K3Eval
import Testing

struct ChatEvalModelOverrideTests {
    @Test("no override → stock brain")
    func stockWhenUnset() {
        #expect(ChatEvalModelOverride.resolve(raw: nil, tier: "lil", mlxTiersSelected: ["lil"]) == .stock)
        #expect(ChatEvalModelOverride.resolve(raw: "  ", tier: "lil", mlxTiersSelected: ["lil"]) == .stock)
    }

    @Test("bare id applies when exactly one MLX brain is selected")
    func bareIDSingleBrain() {
        let r = ChatEvalModelOverride.resolve(
            raw: "mlx-community/Qwen3.8-27B-4bit", tier: "big", mlxTiersSelected: ["big"]
        )
        #expect(r == .override("mlx-community/Qwen3.8-27B-4bit"))
    }

    @Test("bare id with two MLX brains selected is REFUSED, not applied twice")
    func bareIDTwoBrainsRefused() {
        let r = ChatEvalModelOverride.resolve(
            raw: "mlx-community/Qwen3.8-27B-4bit", tier: "lil", mlxTiersSelected: ["lil", "big"]
        )
        guard case let .refused(reason) = r else {
            Issue.record("expected .refused, got \(r)")
            return
        }
        #expect(reason.contains("lil,big"))
        #expect(reason.contains("lil=") || reason.contains("per-tier"))
    }

    @Test("per-tier form targets by name and leaves the other tier stock")
    func perTierForm() {
        let raw = "lil=mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510, big=mlx-community/Qwen3.8-27B-4bit"
        #expect(ChatEvalModelOverride.resolve(raw: raw, tier: "lil", mlxTiersSelected: ["lil", "big"])
            == .override("mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"))
        #expect(ChatEvalModelOverride.resolve(raw: raw, tier: "big", mlxTiersSelected: ["lil", "big"])
            == .override("mlx-community/Qwen3.8-27B-4bit"))
        #expect(ChatEvalModelOverride.resolve(raw: "big=x/y", tier: "lil", mlxTiersSelected: ["lil", "big"]) == .stock)
    }

    @Test("a per-tier key naming a brain that is not selected is refused — a typo must not read as stock")
    func perTierUnknownKeyRefused() {
        let r = ChatEvalModelOverride.resolve(raw: "bg=x/y", tier: "big", mlxTiersSelected: ["big"])
        guard case .refused = r else {
            Issue.record("expected .refused, got \(r)")
            return
        }
    }

    @Test("the non-MLX tier never sees an override")
    func miniIgnored() {
        #expect(ChatEvalModelOverride.resolve(raw: "x/y", tier: "mini", mlxTiersSelected: ["lil"]) == .stock)
    }
}
