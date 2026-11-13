//
//  ErrorChainTests.swift
//  M1K3LogCoreTests
//
//  The log field that names an error's cause: domains and codes down the
//  underlying chain, and never a description or a userInfo value.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: none (new file).
//

import Foundation
import M1K3LogCore
import Testing

struct ErrorChainTests {
    private func error(_ domain: String, _ code: Int, _ info: [String: Any] = [:]) -> NSError {
        NSError(domain: domain, code: code, userInfo: info)
    }

    @Test("an error with no cause is its own domain and code")
    func leaf() {
        #expect(ErrorChain.summary(error("Cloud", 7)) == "Cloud(7)")
    }

    @Test("a single underlying error is followed down")
    func single() {
        let root = error("Network", -1009)
        let outer = error("LanguageModelError", -1, [NSUnderlyingErrorKey: error("Cloud", 1046, [NSUnderlyingErrorKey: root])])
        #expect(ErrorChain.summary(outer) == "LanguageModelError(-1) ← Cloud(1046) ← Network(-1009)")
    }

    @Test("multiple underlying errors are all named: the shape the Private Cloud failure had")
    func multiple() {
        let outer = error("FoundationModels.LanguageModelError", -1, [
            NSMultipleUnderlyingErrorsKey: [error("A", 1, [NSUnderlyingErrorKey: error("Root", 7)]), error("B", 2)],
        ])
        #expect(ErrorChain.summary(outer) == "FoundationModels.LanguageModelError(-1) ← [A(1) ← Root(7), B(2)]")
    }

    @Test("descriptions and userInfo values never reach the field")
    func noContent() {
        let outer = error("Cloud", 3, [
            NSLocalizedDescriptionKey: "the prompt was: my secret plan",
            NSFilePathErrorKey: "/Users/someone/private.txt",
            NSUnderlyingErrorKey: error("Inner", 4, [NSLocalizedFailureReasonErrorKey: "secret reason"]),
        ])
        let summary = ErrorChain.summary(outer)
        #expect(summary == "Cloud(3) ← Inner(4)")
        #expect(!summary.contains("secret"))
        #expect(!summary.contains("/Users"))
    }

    @Test("the walk is bounded in depth and in siblings")
    func bounded() {
        var deep = error("L9", 9)
        for level in (0 ..< 9).reversed() {
            deep = error("L\(level)", level, [NSUnderlyingErrorKey: deep])
        }
        #expect(ErrorChain.summary(deep) == "L0(0) ← L1(1) ← L2(2) ← L3(3)")
        let wide = error("Wide", 0, [NSMultipleUnderlyingErrorsKey: (1 ... 7).map { error("S", $0) }])
        #expect(ErrorChain.summary(wide) == "Wide(0) ← [S(1), S(2), S(3), S(4), +3 more]")
    }

    @Test("a plain Swift error still reads as a domain and a code")
    func swiftError() {
        struct Plain: Error {}
        let summary = ErrorChain.summary(Plain())
        #expect(summary.contains("Plain"))
        #expect(summary.hasSuffix("(1)"))
    }
}
