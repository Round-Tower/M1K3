import Foundation
@testable import M1K3Kokoro
import Testing

/// #838 slice 1: which fallback produced each word, so the share that reaches
/// letter-to-sound on a corpus (the hard-word rate) is measured, not guessed.
struct KokoroG2PSourceTests {
    private static let g2p: KokoroG2P = (try? KokoroG2P.bundled()) ?? KokoroG2P(dictionary: [:])

    @Test("every caption word carries the fallback that resolved it")
    func sourcesPerWord() {
        // "Abujas" is Abuja + plural (#837): the dictionary has neither as written.
        let result = Self.g2p.annotatedTokens("Hello Kev grandmaster Abujas 3rd iOS")
        #expect(result.sources == [.dictionary, .house, .compound, .inflection, .number, .cased])
        #expect(result.sources.count == result.words.count)
    }

    @Test("rules, spell-out, letter-to-sound and silence are told apart")
    func otherSources() {
        #expect(Self.g2p.annotatedTokens("Henry VIII").sources == [.dictionary, .roman])
        #expect(Self.g2p.annotatedTokens("MCP").sources == [.spellOut])
        #expect(Self.g2p.annotatedTokens("V2X7").sources == [.spellOut])
        #expect(Self.g2p.annotatedTokens("M1K3").sources == [.house])
        #expect(Self.g2p.annotatedTokens("pages 4-7").sources == [.dictionary, .number, .number, .number])
        // A pronounceable word nowhere in the dictionary is guessed by letter-to-sound.
        #expect(Self.g2p.annotatedTokens("Snorvelquist").sources == [.letterToSound])
    }

    @Test("an empty dictionary leaves every word silent, and silent is counted")
    func silentWords() {
        let empty = KokoroG2P(dictionary: [:]).annotatedTokens("zzzz")
        #expect(empty.sources == [.silent])
    }

    @Test("source counts add up to the word count")
    func counts() {
        let result = Self.g2p.annotatedTokens("Hello Kev, hello 3rd")
        let counts = result.sourceCounts
        #expect(counts[.dictionary] == 2)
        #expect(counts[.house] == 1)
        #expect(counts[.number] == 1)
        #expect(counts.values.reduce(0, +) == result.words.count)
    }
}
