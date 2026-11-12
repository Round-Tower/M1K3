//
//  LentAppleModelGuardrailTests.swift
//  M1K3InferenceTests
//
//  Pins the one line M1K3 puts ahead of a caller's instructions when it lends
//  an Apple model: always first, the caller's text whole after it, and worded
//  so a small model has no reply to recite.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85, Prior: none (new file).
//

import M1K3Inference
import Testing

struct LentAppleModelGuardrailTests {
    @Test("With no caller instructions the guardrail stands alone")
    func aloneWhenTheCallerSendsNone() {
        #expect(LentAppleModelGuardrail.instructions(callerSystem: nil) == LentAppleModelGuardrail.rule)
        #expect(LentAppleModelGuardrail.instructions(callerSystem: "  \n ") == LentAppleModelGuardrail.rule)
    }

    @Test("The guardrail comes first and the caller's instructions follow whole")
    func callerInstructionsFollowWhole() {
        let combined = LentAppleModelGuardrail.instructions(callerSystem: "You are a ship captain.\nBe brief.")
        #expect(combined.hasPrefix(LentAppleModelGuardrail.rule))
        #expect(combined.hasSuffix("You are a ship captain.\nBe brief."))
        #expect(combined.contains(LentAppleModelGuardrail.handover))
    }

    @Test("The rule names the requirements, lists none of the words that trip Apple's filter, and scripts no reply")
    func ruleIsPlainAndUnscripted() {
        let rule = LentAppleModelGuardrail.rule.lowercased()
        #expect(rule.contains("acceptable use requirements"))
        for word in ["unlawful", "harmful", "hateful", "deceptive"] {
            #expect(rule.contains(word), "\(word)")
        }
        // Measured 2026-11-12: a rule that listed these made Apple's safety filter refuse 3 of 10 ordinary asks.
        for trigger in ["sexual", "explicit", "violence", "self-harm", "children", "exploit", "weapon"] {
            #expect(!rule.contains(trigger), "\(trigger)")
        }
        // #799: Mini copied a spelled-out decline onto ordinary coding asks. No quoted reply, no "say".
        #expect(!rule.contains("\""))
        #expect(!rule.contains("say "))
        #expect(!rule.contains("reply with"))
        #expect(LentAppleModelGuardrail.rule.count < 400)
    }
}
