//
//  AnswerBlockFuzzTests.swift
//  M1K3AnswerBlocksTests
//
//  The issue's gate (#717): "a parser fuzz test: every malformed body falls back
//  without a crash". Seeded (SplitMix64, a fixed seed, no system randomness), so a
//  failure replays exactly; no wall-clock bound. Each case mutates a valid answer
//  (truncate, insert fence and JSON punctuation, delete, duplicate a line, swap
//  quotes) and checks the invariants the renderer and the speech lane rely on.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (2,000 seeded
//  mutations; invariants, not snapshots). Prior: none (new file).
//

import Foundation
@testable import M1K3AnswerBlocks
import Testing

/// SplitMix64: tiny, fast, and the same sequence on every run and platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

enum AnswerBlockFuzz {
    static let seed: UInt64 = 0x5EED
    static let iterations = 2000

    /// Valid answers to start from: every kind, prose around them, two blocks,
    /// indentation, a multi-line body, CRLF.
    static let seeds = [
        "Here's how:\n\n```m1k3-steps\n{\"steps\": [\"Loosen the nut.\", \"Lift the cover.\"]}\n```\n\nThat's it.",
        "Which one?\n```m1k3-choices\n{\"prompt\": \"Which engine?\", \"options\": [\"Lil\", \"Big\", \"Mini\"]}\n```",
        "```m1k3-steps\n{\"steps\": [\"One\"]}\n```\n\n```m1k3-choices\n{\"prompt\": \"Next?\", \"options\": [\"A\", \"B\"]}\n```\nDone.",
        "1. First:\n   ```m1k3-steps\n   {\n     \"steps\": [\n       \"Boil\",\n       \"Steep\"\n     ]\n   }\n   ```\n2. Then rest.",
        "Code first:\n```swift\nlet x = 1\n```\nThen:\r\n```m1k3-choices\r\n{\"prompt\": \"Tea?\", \"options\": [\"Yes\", \"No\"]}\r\n```\r\n",
    ]

    /// Fence and JSON punctuation, whitespace, CRLF, and a few letters. No
    /// backslash, so a parsed string can never contain a quote character.
    static let alphabet: [Character] = [
        "{", "}", "[", "]", "\"", ":", ",", "`", "`", "`", "~", "\n", "\r\n", " ", "\t", "a", "z", "1", "é",
    ]

    static func mutate(_ text: String, using rng: inout SplitMix64) -> String {
        var chars = Array(text)
        for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
            switch Int.random(in: 0 ..< 6, using: &rng) {
            case 0 where !chars.isEmpty: // truncate (a stream cut mid-token)
                chars = Array(chars.prefix(Int.random(in: 0 ..< chars.count, using: &rng)))
            case 1: // insert punctuation
                let at = Int.random(in: 0 ... chars.count, using: &rng)
                chars.insert(alphabet.randomElement(using: &rng)!, at: at)
            case 2 where !chars.isEmpty: // delete
                chars.remove(at: Int.random(in: 0 ..< chars.count, using: &rng))
            case 3: // duplicate a line
                var lines = String(chars).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let at = Int.random(in: 0 ..< lines.count, using: &rng)
                lines.insert(lines[at], at: at)
                chars = Array(lines.joined(separator: "\n"))
            case 4: // swap a double quote for a single one
                if let at = chars.indices.filter({ chars[$0] == "\"" }).randomElement(using: &rng) {
                    chars[at] = "'"
                }
            default: // drop a bare fence line in somewhere
                let at = Int.random(in: 0 ... chars.count, using: &rng)
                chars.insert(contentsOf: "\n```\n", at: at)
            }
        }
        return String(chars)
    }

    /// What every parsed block guarantees the renderer and the speech lane.
    static func isWellFormed(_ block: AnswerBlock) -> Bool {
        func tidy(_ item: String, cap: Int) -> Bool {
            !item.isEmpty && item.count <= cap && item == item.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch block {
        case let .steps(steps):
            return !steps.isEmpty && steps.count <= AnswerBlock.maxSteps
                && steps.allSatisfy { tidy($0, cap: AnswerBlock.maxStepLength) }
        case let .choices(prompt, options):
            return tidy(prompt, cap: AnswerBlock.maxPromptLength)
                && (1 ... AnswerBlock.maxOptions).contains(options.count)
                && options.allSatisfy { tidy($0, cap: AnswerBlock.maxOptionLength) }
                && Set(options.map { $0.lowercased() }).count == options.count
        }
    }

    /// The mutated answers, the same list on every run.
    static func cases() -> [String] {
        var rng = SplitMix64(seed: seed)
        return (0 ..< iterations).map { index in
            mutate(seeds[index % seeds.count], using: &rng)
        }
    }
}

struct AnswerBlockFuzzTests {
    @Test("the generator is seeded: the same cases on every run")
    func generatorIsDeterministic() {
        #expect(AnswerBlockFuzz.cases() == AnswerBlockFuzz.cases())
        var rng = SplitMix64(seed: AnswerBlockFuzz.seed)
        #expect(rng.next() == SplitMix64(seed: AnswerBlockFuzz.seed).copyNext())
    }

    @Test("2,000 mutated answers segment without a trap; markdown is verbatim, blocks are well formed")
    func segmentsHoldTheirInvariants() {
        var blocks = 0
        var pendings = 0
        var malformed = 0
        for text in AnswerBlockFuzz.cases() {
            let segments = AnswerBlockSegmenter.segments(in: text)
            for (index, segment) in segments.enumerated() {
                switch segment {
                case let .markdown(source):
                    #expect(text.contains(source), "\(text.debugDescription)")
                    #expect(source.contains { !$0.isWhitespace })
                case let .block(block):
                    blocks += 1
                    #expect(AnswerBlockFuzz.isWellFormed(block), "\(text.debugDescription)")
                case .pending:
                    pendings += 1
                    #expect(index == segments.count - 1, "pending must be last: \(text.debugDescription)")
                }
            }
            let regions = AnswerBlockSegmenter.typedRegions(in: text)
            malformed += regions.count { $0.isClosed && $0.block == nil }
            // A block segment exists exactly where a closed region parsed.
            #expect(regions.count { $0.block != nil } == segments.count { if case .block = $0 { true } else { false } })
        }
        // The mutations reach every outcome, or the suite proves nothing.
        #expect(blocks > 100)
        #expect(pendings > 100)
        #expect(malformed > 100)
    }

    @Test("the parser never traps on a mutated body, and anything it returns is well formed")
    func parserHoldsItsInvariants() {
        var parsed = 0
        for text in AnswerBlockFuzz.cases() {
            // The whole mutated answer as a body, and each fence part minus its
            // info-string line (the body a fence would hand the parser).
            var bodies = [text]
            bodies += text.split(separator: "```").map { String($0.drop { !$0.isNewline }) }
            for body in bodies {
                for kind in AnswerBlockKind.allCases {
                    if let block = AnswerBlock.parse(kind: kind, body: body) {
                        parsed += 1
                        #expect(block.kind == kind)
                        #expect(AnswerBlockFuzz.isWellFormed(block), "\(body.debugDescription)")
                    }
                }
            }
        }
        #expect(parsed > 100)
    }
}

private extension SplitMix64 {
    func copyNext() -> UInt64 {
        var copy = self
        return copy.next()
    }
}
