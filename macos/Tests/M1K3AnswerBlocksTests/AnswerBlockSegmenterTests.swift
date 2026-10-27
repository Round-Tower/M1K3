//
//  AnswerBlockSegmenterTests.swift
//  M1K3AnswerBlocksTests
//
//  The renderer's split of an answer into markdown, typed blocks and pending
//  (still-streaming) blocks (#717). The rules it must keep: a closed typed fence
//  that parses becomes a block; a malformed one stays the markdown it was (today's
//  code card, no error UI); an open one is a skeleton and its partial JSON never
//  shows; ordinary fences are never split, and a typed opener inside one is code.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure, pinned case by
//  case here and by the seeded fuzz suite). Prior: none (new file).
//

@testable import M1K3AnswerBlocks
import Testing

struct AnswerBlockSegmenterTests {
    private let stepsFence = "```m1k3-steps\n{\"steps\": [\"Loosen the nut.\", \"Lift the cover.\"]}\n```"
    private let steps = AnswerBlock.steps(["Loosen the nut.", "Lift the cover."])

    @Test("prose, a closed steps fence, prose → markdown, block, markdown, each markdown a verbatim slice")
    func proseBlockProse() {
        let text = "Here's how:\n\n\(stepsFence)\n\nThat's it."
        #expect(AnswerBlockSegmenter.segments(in: text) == [
            .markdown("Here's how:\n\n"),
            .block(steps),
            .markdown("\n\nThat's it."),
        ])
    }

    @Test("text with no typed fence is one markdown segment, byte for byte")
    func plainTextIsOneSegment() {
        let text = "Just **prose**, a list:\n- one\n- two\n"
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)])
    }

    @Test("empty or whitespace-only text has no segments")
    func emptyText() {
        #expect(AnswerBlockSegmenter.segments(in: "").isEmpty)
        #expect(AnswerBlockSegmenter.segments(in: " \n\n ").isEmpty)
    }

    @Test("an open typed fence at the end is pending, and none of its partial JSON is in a markdown segment")
    func openFenceIsPending() {
        let text = "Here's how:\n```m1k3-steps\n{\"steps\": [\"Loosen the"
        let segments = AnswerBlockSegmenter.segments(in: text)
        #expect(segments == [.markdown("Here's how:\n"), .pending(.steps)])
        for case let .markdown(source) in segments {
            #expect(!source.contains("{"))
            #expect(!source.contains("m1k3-steps"))
        }
    }

    @Test("every streamed prefix of an answer segments without showing partial JSON")
    func streamedPrefixes() {
        let text = "Try this:\n\(stepsFence)\nDone."
        var sawPending = false
        var sawBlock = false
        for end in text.indices {
            let prefix = String(text[..<end])
            for segment in AnswerBlockSegmenter.segments(in: prefix) {
                switch segment {
                case let .markdown(source): #expect(!source.contains("\"steps\""), "\(prefix)")
                case .pending: sawPending = true
                case .block: sawBlock = true
                }
            }
        }
        #expect(sawPending)
        #expect(sawBlock)
    }

    @Test("an opener line that has fully arrived is pending even before its first body byte")
    func bareOpenerIsPending() {
        #expect(AnswerBlockSegmenter.segments(in: "Pick one:\n```m1k3-choices") == [
            .markdown("Pick one:\n"),
            .pending(.choices),
        ])
    }

    @Test("a closed MALFORMED typed fence stays one markdown segment equal to the input")
    func malformedStaysMarkdown() {
        let text = "Steps:\n```m1k3-steps\n{\"steps\": [\"One\", 2]}\n```\nAfter."
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)])
    }

    @Test("an ordinary fenced code block is never split")
    func ordinaryFenceUntouched() {
        let text = "Code:\n```swift\nlet steps = [\"a\"]\n```\nDone."
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)])
    }

    @Test("a typed opener INSIDE an open ordinary fence is code, not a block")
    func typedOpenerInsideCodeIsCode() {
        let text = "Here is the format:\n````markdown\n\(stepsFence)\n````\nUse it."
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)])
        let tilde = "Here is the format:\n~~~\n\(stepsFence)\n~~~\nUse it."
        #expect(AnswerBlockSegmenter.segments(in: tilde) == [.markdown(tilde)])
    }

    @Test("CRLF line endings pair the typed fence")
    func crlfPairs() {
        let text = "Intro\r\n```m1k3-steps\r\n{\"steps\": [\"One\"]}\r\n```\r\nOutro"
        #expect(AnswerBlockSegmenter.segments(in: text) == [
            .markdown("Intro\r\n"),
            .block(.steps(["One"])),
            .markdown("\r\nOutro"),
        ])
    }

    @Test("a four-backtick opener closes only on four or more")
    func runLengthClose() {
        let text = "````m1k3-steps\n{\"steps\": [\"One\"]}\n```\n````"
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)]) // the ``` line is body: malformed
        let good = "````m1k3-steps\n{\"steps\": [\"One\"]}\n````"
        #expect(AnswerBlockSegmenter.segments(in: good) == [.block(.steps(["One"]))])
    }

    @Test("the info string tolerates case, indentation and trailing space, and nothing else")
    func infoStringTolerance() {
        let tolerated = "  ```M1K3-Steps  \n  {\"steps\": [\"One\"]}\n  ```"
        #expect(AnswerBlockSegmenter.segments(in: tolerated) == [.block(.steps(["One"]))])
        let other = "```m1k3-steps json\n{\"steps\": [\"One\"]}\n```"
        #expect(AnswerBlockSegmenter.segments(in: other) == [.markdown(other)])
    }

    @Test("two blocks back to back, with only a blank line between, are two blocks")
    func twoBlocks() {
        let choices = "```m1k3-choices\n{\"prompt\": \"Which?\", \"options\": [\"A\", \"B\"]}\n```"
        let text = "\(stepsFence)\n\n\(choices)\n"
        #expect(AnswerBlockSegmenter.segments(in: text) == [
            .block(steps),
            .block(.choices(prompt: "Which?", options: ["A", "B"])),
        ])
    }

    @Test("a JSON body spread over indented lines with blank lines still parses")
    func multilineBody() {
        let text = "```m1k3-choices\n{\n  \"prompt\": \"Which?\",\n\n  \"options\": [\n    \"A\",\n    \"B\"\n  ]\n}\n```"
        #expect(AnswerBlockSegmenter.segments(in: text) == [.block(.choices(prompt: "Which?", options: ["A", "B"]))])
    }

    @Test("a same-line ```span``` is prose, not an opener")
    func sameLineSpanIsProse() {
        let text = "```m1k3-steps``` is the tag.\n\(stepsFence)"
        #expect(AnswerBlockSegmenter.segments(in: text) == [
            .markdown("```m1k3-steps``` is the tag.\n"),
            .block(steps),
        ])
    }

    @Test("the scan reports every typed region it saw, closed or not, parsed or not")
    func regionsReported() {
        let text = "\(stepsFence)\n```m1k3-steps\nnot json\n```\n```m1k3-choices\n{"
        let regions = AnswerBlockSegmenter.typedRegions(in: text)
        #expect(regions.map(\.kind) == [.steps, .steps, .choices])
        #expect(regions.map(\.block) == [steps, nil, nil])
        #expect(regions.map(\.isClosed) == [true, true, false])
        #expect(regions.last?.range.upperBound == text.endIndex)
    }
}
