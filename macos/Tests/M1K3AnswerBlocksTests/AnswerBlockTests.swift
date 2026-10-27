//
//  AnswerBlockTests.swift
//  M1K3AnswerBlocksTests
//
//  The typed-block parser's contract (#717): a fence tag plus a small JSON body
//  becomes a block, and anything else becomes nil, which leaves the fence as the
//  raw markdown it was. Never a throw, never a partial block that hides content.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure parser, every
//  rule pinned here). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (code-quality review fold) — the 16 KB cap is pinned at its
//  boundary (the megabyte case was refused by the step cap, not the byte cap), and a nesting bomb under
//  the cap returns nil without a trap. Confidence 0.85.
//

@testable import M1K3AnswerBlocks
import Testing

struct AnswerBlockTests {
    // MARK: - Kinds

    @Test("the two fence tags are the kinds' raw values; any other tag is no kind")
    func kindsAreTheFenceTags() {
        #expect(AnswerBlockKind(rawValue: "m1k3-steps") == .steps)
        #expect(AnswerBlockKind(rawValue: "m1k3-choices") == .choices)
        #expect(AnswerBlockKind(rawValue: "m1k3-chart") == nil)
        #expect(AnswerBlockKind(rawValue: "json") == nil)
        #expect(AnswerBlockKind.allCases.count == 2)
    }

    // MARK: - Steps

    @Test("a steps body parses to its steps, each trimmed")
    func stepsParse() {
        let body = #"{"steps": ["  Loosen the nut ", "Lift the cover."]}"#
        #expect(AnswerBlock.parse(kind: .steps, body: body) == .steps(["Loosen the nut", "Lift the cover."]))
        #expect(AnswerBlock.parse(kind: .steps, body: body)?.kind == .steps)
    }

    @Test("blank steps are dropped; repeated steps are kept, because a sequence can repeat itself")
    func stepsKeepRepeats() {
        let body = #"{"steps": ["Stir", "  ", "Wait a minute", "stir"]}"#
        #expect(AnswerBlock.parse(kind: .steps, body: body) == .steps(["Stir", "Wait a minute", "stir"]))
    }

    @Test("unknown keys beside the steps are ignored")
    func stepsIgnoreUnknownKeys() {
        let body = #"{"title": "Fix it", "steps": ["One"], "extra": 3}"#
        #expect(AnswerBlock.parse(kind: .steps, body: body) == .steps(["One"]))
    }

    @Test("the wrong shape is nil: a number in the list, a missing key, an object, an empty list, not JSON")
    func stepsWrongShapeIsNil() {
        let bodies = [
            #"{"steps": ["One", 2, "Three"]}"#,
            #"{"items": ["One"]}"#,
            #"{"steps": {"1": "One"}}"#,
            #"{"steps": []}"#,
            #"{"steps": ["  ", ""]}"#,
            #"["One", "Two"]"#,
            #"{"steps": ["One",]"#,
            "",
            "steps: one, two",
        ]
        for body in bodies {
            #expect(AnswerBlock.parse(kind: .steps, body: body) == nil, "\(body)")
        }
    }

    @Test("past the caps a step list degrades whole (raw markdown) rather than silently losing a step")
    func stepsOverCapDegrade() {
        let twelve = (1 ... AnswerBlock.maxSteps).map { "\"Step \($0)\"" }.joined(separator: ",")
        #expect(AnswerBlock.parse(kind: .steps, body: "{\"steps\": [\(twelve)]}") != nil)
        let thirteen = (1 ... AnswerBlock.maxSteps + 1).map { "\"Step \($0)\"" }.joined(separator: ",")
        #expect(AnswerBlock.parse(kind: .steps, body: "{\"steps\": [\(thirteen)]}") == nil)

        let atCap = String(repeating: "a", count: AnswerBlock.maxStepLength)
        #expect(AnswerBlock.parse(kind: .steps, body: "{\"steps\": [\"\(atCap)\"]}") != nil)
        let overCap = atCap + "a"
        #expect(AnswerBlock.parse(kind: .steps, body: "{\"steps\": [\"One\", \"\(overCap)\"]}") == nil)
    }

    // MARK: - Choices

    @Test("a choices body parses to its prompt and options, trimmed")
    func choicesParse() {
        let body = #"{"prompt": " Which engine? ", "options": ["Lil", " Big ", "Mini"]}"#
        #expect(
            AnswerBlock.parse(kind: .choices, body: body)
                == .choices(prompt: "Which engine?", options: ["Lil", "Big", "Mini"])
        )
        #expect(AnswerBlock.parse(kind: .choices, body: body)?.kind == .choices)
    }

    @Test("options are deduped case-insensitively, blanks and overlong ones dropped, capped at six")
    func choicesTidy() {
        let long = String(repeating: "x", count: AnswerBlock.maxOptionLength + 1)
        let body = """
        {"prompt": "Pick", "options": ["Tea", "tea", " ", "\(long)", "Coffee", "A", "B", "C", "D", "E"]}
        """
        #expect(
            AnswerBlock.parse(kind: .choices, body: body)
                == .choices(prompt: "Pick", options: ["Tea", "Coffee", "A", "B", "C", "D"])
        )
    }

    @Test("a choices body with a blank, missing or overlong prompt, or no usable option, is nil")
    func choicesWrongShapeIsNil() {
        let longPrompt = String(repeating: "p", count: AnswerBlock.maxPromptLength + 1)
        let bodies = [
            #"{"prompt": "  ", "options": ["A"]}"#,
            #"{"options": ["A", "B"]}"#,
            #"{"prompt": 3, "options": ["A"]}"#,
            "{\"prompt\": \"\(longPrompt)\", \"options\": [\"A\"]}",
            #"{"prompt": "Pick", "options": []}"#,
            #"{"prompt": "Pick", "options": ["A", null]}"#,
            #"{"prompt": "Pick", "options": "A, B"}"#,
            #"{"prompt": "Pick"}"#,
        ]
        for body in bodies {
            #expect(AnswerBlock.parse(kind: .choices, body: body) == nil, "\(body)")
        }
    }

    @Test("a steps body read as choices (and the reverse) is nil — the tag decides the shape")
    func kindDecidesShape() {
        #expect(AnswerBlock.parse(kind: .choices, body: #"{"steps": ["One"]}"#) == nil)
        #expect(AnswerBlock.parse(kind: .steps, body: #"{"prompt": "P", "options": ["A"]}"#) == nil)
    }

    // MARK: - Size

    @Test("a megabyte body is refused without a throw or a trap")
    func hugeBodyIsNil() {
        let step = String(repeating: "word ", count: 50)
        let items = Array(repeating: "\"\(step)\"", count: 4200).joined(separator: ",")
        let body = "{\"steps\": [\(items)]}"
        #expect(body.utf8.count > 1_000_000)
        #expect(AnswerBlock.parse(kind: .steps, body: body) == nil)
    }

    @Test("the byte cap is exact: a body of 16,384 bytes parses, one more byte is refused")
    func byteCapBoundary() {
        // Trailing whitespace is legal JSON, so only the byte count changes.
        let base = #"{"steps": ["One"]}"#
        let atCap = base + String(repeating: " ", count: AnswerBlock.maxBodyBytes - base.utf8.count)
        #expect(atCap.utf8.count == AnswerBlock.maxBodyBytes)
        #expect(AnswerBlock.parse(kind: .steps, body: atCap) == .steps(["One"]))
        #expect(AnswerBlock.parse(kind: .steps, body: atCap + " ") == nil)
    }

    @Test("a nesting bomb under the byte cap is nil for every kind, without a throw or a trap")
    func nestingBombIsNil() {
        // A looping model (or a page steering one) can write this; the fuzz's few
        // edits per case never reach the depth. Before the depth guard, 16,000 `[`
        // overflowed the test thread's stack inside JSONSerialization (SIGBUS).
        let bombs = [
            String(repeating: "[", count: 16000),
            String(repeating: #"{"a":"#, count: 3000),
            #"{"steps": ["One"], "x": "#
                + String(repeating: "[", count: 8000) + String(repeating: "]", count: 8000) + "}",
        ]
        for bomb in bombs {
            #expect(bomb.utf8.count <= AnswerBlock.maxBodyBytes, "under the cap, so the depth guard is what refuses it")
            for kind in AnswerBlockKind.allCases {
                #expect(AnswerBlock.parse(kind: kind, body: bomb) == nil, "\(bomb.prefix(40))")
            }
        }
    }

    @Test("nesting within the depth limit still parses, and brackets inside a string never count as depth")
    func depthGuardCountsStructureOnly() {
        let nestedExtra = #"{"steps": ["One"], "meta": {"a": [1, {"b": [2]}]}}"#
        #expect(AnswerBlock.parse(kind: .steps, body: nestedExtra) == .steps(["One"]))
        let bracketsInText = String(repeating: "[{", count: AnswerBlock.maxDepth)
        let body = #"{"steps": [""# + bracketsInText + #" \"quoted\" odd"]}"#
        #expect(AnswerBlock.parse(kind: .steps, body: body) == .steps([bracketsInText + " \"quoted\" odd"]))
        let tooDeep = #"{"steps": ["One"], "x": "# + String(repeating: "[", count: AnswerBlock.maxDepth)
            + String(repeating: "]", count: AnswerBlock.maxDepth) + "}"
        #expect(AnswerBlock.parse(kind: .steps, body: tooDeep) == nil)
    }
}
