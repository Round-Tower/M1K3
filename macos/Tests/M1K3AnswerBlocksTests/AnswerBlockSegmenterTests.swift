//
//  AnswerBlockSegmenterTests.swift
//  M1K3AnswerBlocksTests
//
//  The renderer's split of an answer into markdown, typed blocks and pending
//  (still-streaming) blocks (#717). The rules it must keep: a closed typed fence
//  that parses becomes a block; a malformed one stays the markdown it was (today's
//  code card, no error UI); an open one is a skeleton while the turn streams and
//  its partial JSON never shows, and once the turn ends it is raw markdown too;
//  ordinary fences are never split, and a typed opener inside one is code.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure, pinned case by
//  case here and by the seeded fuzz suite). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (code-quality review fold) — pins for the branches no test
//  reached: a `~~~m1k3-steps` opener is code, a longer closer closes, tab indentation, a closed ordinary
//  fence hands the scan back (the old ordinary-fence case had no tag, so the scan never ran), and the
//  live case: a typed opener inside a still-open ordinary fence while streaming is never a skeleton.
//  Confidence 0.85.
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
        let segments = AnswerBlockSegmenter.segments(in: text, streaming: true)
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
            for segment in AnswerBlockSegmenter.segments(in: prefix, streaming: true) {
                switch segment {
                case let .markdown(source):
                    // Every prefix that stops before the key completes would pass a
                    // key check, so check the first byte of the body and the tag.
                    #expect(!source.contains("{"), "\(prefix)")
                    #expect(!source.contains("m1k3-steps"), "\(prefix)")
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
        #expect(AnswerBlockSegmenter.segments(in: "Pick one:\n```m1k3-choices", streaming: true) == [
            .markdown("Pick one:\n"),
            .pending(.choices),
        ])
    }

    @Test("once the turn has ended, a typed fence that never closed is the raw markdown it was, not a skeleton forever")
    func unclosedAfterStreamIsMarkdown() {
        let cut = "Here's how:\n```m1k3-steps\n{\"steps\": [\"Lo"
        #expect(AnswerBlockSegmenter.segments(in: cut) == [.markdown(cut)])
        let text = "\(stepsFence)\nThen:\n```m1k3-choices\n{"
        #expect(AnswerBlockSegmenter.segments(in: text, streaming: false) == [
            .block(steps),
            .markdown("\nThen:\n```m1k3-choices\n{"),
        ])
        #expect(AnswerBlockSegmenter.segments(in: text, streaming: true) == [
            .block(steps),
            .markdown("\nThen:\n"),
            .pending(.choices),
        ])
    }

    @Test("a closed MALFORMED typed fence stays one markdown segment equal to the input")
    func malformedStaysMarkdown() {
        let text = "Steps:\n```m1k3-steps\n{\"steps\": [\"One\", 2]}\n```\nAfter."
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)])
    }

    @Test("an ordinary fenced code block is never split, and a typed fence after it is still a block")
    func ordinaryFenceUntouched() {
        // The tag is in the code so the scan runs (text without "m1k3-" skips it).
        let code = "Code:\n```swift\nlet tag = \"m1k3-steps\"\n```\n"
        #expect(AnswerBlockSegmenter.segments(in: code + "Done.") == [.markdown(code + "Done.")])
        #expect(AnswerBlockSegmenter.segments(in: code + stepsFence) == [.markdown(code), .block(steps)])
    }

    @Test("while streaming, a typed opener inside a still-open ordinary fence is code: never a skeleton or a card")
    func typedOpenerInsideOpenCodeWhileStreaming() {
        let cut = "Format:\n````markdown\n```m1k3-steps\n{\"steps\": [\"Lo"
        #expect(AnswerBlockSegmenter.segments(in: cut, streaming: true) == [.markdown(cut)])
        // Every frame of a model showing the format inside a four-tick fence.
        let nested = "Format:\n````markdown\n\(stepsFence)\n````\nUse it."
        for end in nested.indices {
            let prefix = String(nested[..<end])
            let expected: [AnswerBlockSegment] = prefix.contains { !$0.isWhitespace } ? [.markdown(prefix)] : []
            let segments = AnswerBlockSegmenter.segments(in: prefix, streaming: true)
            #expect(segments == expected, "\(prefix.debugDescription)")
        }
    }

    @Test("a tilde opener with a typed tag is an ordinary fence, never a block")
    func tildeTypedOpenerIsCode() {
        let text = "~~~m1k3-steps\n{\"steps\": [\"One\"]}\n~~~"
        #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)])
        let open = "~~~m1k3-steps\n{"
        #expect(AnswerBlockSegmenter.segments(in: open, streaming: true) == [.markdown(open)])
    }

    @Test("a longer closing run closes a typed fence; a tilde line, a shorter run or trailing text does not")
    func closerRules() {
        let longer = "```m1k3-steps\n{\"steps\": [\"One\"]}\n````"
        #expect(AnswerBlockSegmenter.segments(in: longer) == [.block(.steps(["One"]))])
        for closer in ["~~~", "``", "``` and more"] {
            let text = "```m1k3-steps\n{\"steps\": [\"One\"]}\n\(closer)"
            #expect(AnswerBlockSegmenter.segments(in: text) == [.markdown(text)], "\(closer)")
        }
    }

    @Test("tab indentation opens and closes a typed fence like spaces do")
    func tabIndentation() {
        let text = "\t```m1k3-steps\n\t{\"steps\": [\"One\"]}\n\t```"
        #expect(AnswerBlockSegmenter.segments(in: text) == [.block(.steps(["One"]))])
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
