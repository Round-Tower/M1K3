//
//  ArithmeticEvaluatorTests.swift
//  M1K3EvalTests
//
//  The calculator probe's evaluator: plain arithmetic only, never a crash, never a function call.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.85, Prior: none (new file).

@testable import M1K3Eval
import Testing

struct ArithmeticEvaluatorTests {
    @Test("the four operations, precedence and brackets")
    func basics() {
        #expect(ArithmeticEvaluator.evaluate("2 + 3 * 4") == 14)
        #expect(ArithmeticEvaluator.evaluate("(2 + 3) * 4") == 20)
        #expect(ArithmeticEvaluator.evaluate("120 / 3") == 40)
        #expect(ArithmeticEvaluator.evaluate("10 - 4 - 3") == 3, "subtraction is left-associative")
        #expect(ArithmeticEvaluator.evaluate("-5 + 2") == -3)
        #expect(ArithmeticEvaluator.evaluate("2 ^ 3 ^ 2") == 512, "power is right-associative")
        #expect(ArithmeticEvaluator.evaluate("1.5 * 4") == 6)
    }

    @Test("the symbols people and models actually type")
    func symbols() {
        #expect(ArithmeticEvaluator.evaluate("6 × 7") == 42)
        #expect(ArithmeticEvaluator.evaluate("84 ÷ 2") == 42)
        #expect(ArithmeticEvaluator.evaluate("2**10") == 1024)
        #expect(ArithmeticEvaluator.evaluate("1,000 + 1") == 1001)
        #expect(ArithmeticEvaluator.evaluate("14 % 4") == 2)
        #expect(ArithmeticEvaluator.evaluate("3 − 1") == 2, "a typographic minus")
    }

    @Test("anything that isn't arithmetic is refused, never evaluated")
    func refusals() {
        for input in ["", "FUNCTION(1,'exit')", "2 +", "(1 + 2", "1 / 0", "abc", "2 3",
                      String(repeating: "(", count: 300) + "1" + String(repeating: ")", count: 300)]
        {
            #expect(ArithmeticEvaluator.evaluate(input) == nil, Comment(rawValue: input))
        }
    }

    @Test("the tool's answer: whole numbers plain, fractions trimmed, errors explained")
    func answers() {
        #expect(ArithmeticEvaluator.answer("60 * 2.5") == "60 * 2.5 = 150")
        #expect(ArithmeticEvaluator.answer("1 / 3") == "1 / 3 = 0.333333")
        #expect(ArithmeticEvaluator.answer("6 / 5 * 60") == "6 / 5 * 60 = 72")
        #expect(ArithmeticEvaluator.answer("two plus two").hasPrefix("Error:"))
    }
}
